import Foundation
import Combine
import DefraSync
import WhoopStore

/// `@MainActor` orchestrator owned by `AppModel`. Brings up the sidecar, wires `DefraSyncer` as
/// the `WhoopStoreObserver`, starts the polling subscriber, and exposes published state for the
/// "Sync (Experimental)" settings panel.
///
/// Sync is opt-in: `start()` is a no-op when `UserDefaults["sync.enabled"]` is false. Toggling
/// the setting on calls `start()`; toggling off calls `stop()`.
@MainActor
public final class SyncController: ObservableObject {

    // MARK: - Published state for the Settings panel

    public enum Phase: Equatable {
        case disabled
        case sidecarStarting
        case sidecarFailed(String)
        case running
    }

    @Published public private(set) var phase: Phase = .disabled
    @Published public private(set) var myMultiaddr: String?
    @Published public private(set) var peers: [String] = []
    @Published public private(set) var outboxPending: Int = 0
    @Published public private(set) var outboxDead: Int = 0
    @Published public private(set) var lastAppliedAt: Date?
    @Published public private(set) var lastMirrorAt: Date?

    // MARK: - Dependencies

    private let store: WhoopStore
    private let repoRefresh: @MainActor () async -> Void
    private let sidecar: DefraSidecar
    private let client: DefraClient
    private var syncer: DefraSyncer?
    private var subscriber: DefraSubscriber?
    private var drainTask: Task<Void, Never>?
    private var refreshDebounce: Task<Void, Never>?

    /// `nodeLabel` is stamped onto every outbound mutation as `lastWriterPeer` so the user can
    /// tell which Mac originated a row. Defaults to `Host.current().localizedName` ("Eduardo's MacBook").
    public init(store: WhoopStore,
                repoRefresh: @escaping @MainActor () async -> Void,
                dataDir: URL,
                binaryURL: URL,
                nodeLabel: String = Host.current().localizedName ?? "unknown-mac") {
        self.store = store
        self.repoRefresh = repoRefresh
        self.sidecar = DefraSidecar(binaryURL: binaryURL, dataDir: dataDir)
        self.client = DefraClient()
        self.syncer = nil
        self.subscriber = nil
        _ = nodeLabel    // wire below when syncer is created
        self._nodeLabel = nodeLabel
    }

    private let _nodeLabel: String

    // MARK: - Public lifecycle

    /// Bring up the sidecar, load schema, attach the observer, start the subscriber. Idempotent.
    public func start() async {
        guard UserDefaults.standard.bool(forKey: "sync.enabled") else { phase = .disabled; return }
        guard phase != .running, phase != .sidecarStarting else { return }
        phase = .sidecarStarting
        do {
            _ = try await sidecar.start()
        } catch {
            phase = .sidecarFailed("\(error)")
            return
        }

        // Bootstrap schema (no-op if hash already cached). v1.0.0-rc1 dropped the HTTP schema
        // endpoint; DefraSchema.bootstrap shells out to `defradb client collection add -`.
        let cachedHash = UserDefaults.standard.string(forKey: "defra.schema.hash")
        if cachedHash != DefraSchema.sha256Hex {
            do {
                try await DefraSchema.bootstrap(binaryURL: sidecar.binaryURL)
                UserDefaults.standard.set(DefraSchema.sha256Hex, forKey: "defra.schema.hash")
            } catch {
                phase = .sidecarFailed("schema: \(error)")
                return
            }
        }

        // Refresh peer state.
        myMultiaddr = try? await client.selfMultiaddr()
        peers = (try? await client.listPeers()) ?? []

        // Wire observer + subscriber.
        let syncer = DefraSyncer(client: client, store: store, nodeLabel: _nodeLabel)
        self.syncer = syncer
        await store.setObserver(syncer)

        let weakSelf = self
        let subscriber = DefraSubscriber(client: client, store: store, onApplied: { [weak weakSelf] in
            await weakSelf?.onInboundApplied()
        })
        self.subscriber = subscriber
        await subscriber.start()

        // Periodic drain so a queued-while-offline batch gets out without waiting for the next write.
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncer?.drainOutbox()
                await self?.refreshCounts()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }

        // First-run backfill.
        if !UserDefaults.standard.bool(forKey: "defra.backfill.done") {
            await runBackfill()
            UserDefaults.standard.set(true, forKey: "defra.backfill.done")
        }
        phase = .running
    }

    public func stop() async {
        drainTask?.cancel(); drainTask = nil
        await subscriber?.stop()
        await store.setObserver(nil)
        syncer = nil
        subscriber = nil
        sidecar.stop()
        phase = .disabled
    }

    // MARK: - User actions surfaced in Settings

    public func addPeer(_ multiaddr: String) async throws {
        try await client.addPeer(multiaddr, schemas: DefraTypeName.allCollections.map {
            DefraTypeName.graphqlType(for: $0) ?? $0
        })
        peers = (try? await client.listPeers()) ?? peers
    }

    public func refreshSnapshot() async {
        myMultiaddr = try? await client.selfMultiaddr()
        peers = (try? await client.listPeers()) ?? peers
        await refreshCounts()
    }

    public func retryNow() async {
        // If the sidecar never came up (Failed) or never started, re-run the bring-up sequence —
        // start() is idempotent for the .running case and re-tries everything for .sidecarFailed.
        if case .sidecarFailed = phase {
            await start()
            return
        }
        await syncer?.drainOutbox()
        await subscriber?.pokeNow()
        await refreshCounts()
    }

    /// "Reset Defra data dir" danger button. Stops the sidecar, deletes the data dir, clears
    /// schema/backfill caches. The next `start()` re-bootstraps everything.
    public func resetDataDir() async throws {
        await stop()
        try FileManager.default.removeItem(at: sidecar.dataDir)
        UserDefaults.standard.removeObject(forKey: "defra.schema.hash")
        UserDefaults.standard.removeObject(forKey: "defra.backfill.done")
    }

    // MARK: - Internal

    private func onInboundApplied() async {
        lastAppliedAt = Date()
        // Debounce the UI refresh to once per second — a large catch-up batch shouldn't trigger
        // N refreshes.
        refreshDebounce?.cancel()
        refreshDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.repoRefresh()
        }
    }

    private func refreshCounts() async {
        let counts = (try? await store.outboxCounts()) ?? (pending: 0, dead: 0)
        outboxPending = counts.pending
        outboxDead = counts.dead
    }

    /// Walk each synced table once and republish through the syncer. The DefraDB side dedupes on
    /// `naturalKey` so re-running is harmless. We use a wide date window to capture everything.
    private func runBackfill() async {
        // Use a 30-year window so we don't accidentally skip historical imports.
        let now = Date()
        let fromTs = Int(now.timeIntervalSince1970) - 30 * 365 * 86_400
        let toTs = Int(now.timeIntervalSince1970) + 86_400
        let fromDay = "1990-01-01"
        let toDay = "2099-01-01"

        // We don't know the full set of deviceIds in the store at this layer — but the observer
        // payload only needs each row's existing `deviceId` column, and the syncer reads it from
        // the payload itself. We re-emit by re-upserting through the same path. Cheapest version:
        // iterate every common deviceId we know about. For the experiment, hardcode the four the
        // app uses today.
        for dev in ["my-whoop", "apple-health", "mock-A", "mock-B"] {
            let sessions = (try? await store.sleepSessions(deviceId: dev, from: fromTs, to: toTs, limit: 100_000)) ?? []
            try? await store.upsertSleepSessions(sessions, deviceId: dev)
            let days = (try? await store.dailyMetrics(deviceId: dev, from: fromDay, to: toDay)) ?? []
            try? await store.upsertDailyMetrics(days, deviceId: dev)
            let journal = (try? await store.journalEntries(deviceId: dev, from: fromDay, to: toDay)) ?? []
            try? await store.upsertJournal(journal, deviceId: dev)
            let workouts = (try? await store.workouts(deviceId: dev, from: fromTs, to: toTs, limit: 100_000)) ?? []
            try? await store.upsertWorkouts(workouts, deviceId: dev)
            let apple = (try? await store.appleDaily(deviceId: dev, from: fromDay, to: toDay)) ?? []
            try? await store.upsertAppleDaily(apple, deviceId: dev)
        }
        lastMirrorAt = Date()
    }
}

// MARK: - File-system helpers

public enum SyncPaths {
    /// `<AppSupport>/OpenWhoop/defra/` — sibling of whoop.sqlite. Created on demand.
    public static func defraDataDir() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
            .appendingPathComponent("defra", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Look up the vendored defradb binary. Order:
    /// 1. `UserDefaults["defra.binary.path"]` — explicit override (set via the "Pick binary…"
    ///    button in Sync settings, or `defaults write com.noopapp.noop defra.binary.path <path>`).
    /// 2. Bundled inside the app (added via Xcode "Copy Bundle Resources" phase).
    /// 3. `Tools/defradb/defradb-darwin-<arch>` relative to a recorded project root
    ///    (`UserDefaults["defra.project.root"]`, persisted the first time the override is set).
    /// 4. `/opt/homebrew/bin/defradb` and `/usr/local/bin/defradb` (Homebrew installs).
    /// Returns the first candidate that exists on disk. If none exist, returns the last fallback
    /// so the resulting "binary not found" error surfaces a real path for debugging.
    public static func defraBinaryURL() -> URL {
        let arch = currentArch()
        let fm = FileManager.default

        if let override = UserDefaults.standard.string(forKey: "defra.binary.path"),
           fm.fileExists(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        if let bundled = Bundle.main.url(forResource: "defradb-darwin-\(arch)", withExtension: nil) {
            return bundled
        }
        if let projectRoot = UserDefaults.standard.string(forKey: "defra.project.root") {
            let toolPath = URL(fileURLWithPath: projectRoot)
                .appendingPathComponent("Tools/defradb/defradb-darwin-\(arch)")
            if fm.fileExists(atPath: toolPath.path) { return toolPath }
        }
        let brewARM = URL(fileURLWithPath: "/opt/homebrew/bin/defradb")
        if fm.fileExists(atPath: brewARM.path) { return brewARM }
        let brewIntel = URL(fileURLWithPath: "/usr/local/bin/defradb")
        if fm.fileExists(atPath: brewIntel.path) { return brewIntel }
        return brewARM
    }

    private static func currentArch() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }
}
