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
                nodeLabel: String = Host.current().localizedName ?? "unknown-mac") {
        self.store = store
        self.repoRefresh = repoRefresh
        self.sidecar = DefraSidecar(dataDir: dataDir)
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

        // Bootstrap schema (no-op if hash already cached). Phase 3: routes through
        // DefraEmbedRuntime.loadCollections; the Go side tolerates "already exists" so a
        // forced replay on a hash bust is safe.
        let cachedHash = UserDefaults.standard.string(forKey: "defra.schema.hash")
        if cachedHash != DefraSchema.sha256Hex {
            do {
                try DefraSchema.bootstrap()
                UserDefaults.standard.set(DefraSchema.sha256Hex, forKey: "defra.schema.hash")
            } catch {
                phase = .sidecarFailed("schema: \(error)")
                return
            }
        }

        // Subscribe this node to every collection's pubsub topic. Once both Macs are subscribed
        // and one dials the other via `p2p connect`, writes fan out symmetrically. Idempotent.
        do {
            try DefraP2P.subscribeCollections(
                names: DefraTypeName.allCollections.compactMap(DefraTypeName.graphqlType(for:))
            )
        } catch {
            phase = .sidecarFailed("p2p collection add: \(error)")
            return
        }

        // Refresh peer state.
        myMultiaddr = try? await client.selfMultiaddr()
        peers = (try? await client.activePeers()) ?? []

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

    /// Wire up two-way sync with the given peer.
    ///
    /// In v1.0.0-rc1, `p2p connect` establishes the libp2p link and pubsub routes future writes,
    /// but it doesn't backfill existing state — proven empirically by running `replicator add`
    /// from the CLI and watching ~60 docs flow across an otherwise-idle connection. So we also
    /// register a forward-push replicator: defradb pushes every doc the local node holds (and
    /// every subsequent write) to the peer. For symmetric sync, both Macs add each other.
    public func addPeer(_ multiaddr: String) async throws {
        let collectionNames = DefraTypeName.allCollections.compactMap(DefraTypeName.graphqlType(for:))
        try DefraP2P.replicate(collectionNames: collectionNames, multiaddr: multiaddr)
        peers = (try? await client.activePeers()) ?? peers
    }

    public func refreshSnapshot() async {
        myMultiaddr = try? await client.selfMultiaddr()
        peers = (try? await client.activePeers()) ?? peers
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

    // Phase 3 removed `defraBinaryURL()`. The embedded runtime no longer spawns a child
    // process — `DefraEmbedRuntime.start(...)` runs DefraDB inside this process via the
    // DefraEmbed.xcframework Go bindings. The data directory is still managed locally; see
    // `defraDataDir()` above.
}
