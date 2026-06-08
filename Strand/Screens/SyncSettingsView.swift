import SwiftUI
import DefraSync
import StrandDesign
import WhoopStore

/// "Sync (Experimental)" panel. Lives under the Settings screen.
///
/// Surfaces: enable toggle, sidecar status, this node's multiaddr (for the user to paste on the
/// other Mac), the peer list, outbox depth, per-machine mock-data buttons, and a few danger
/// affordances (Install LaunchAgent, Reset Defra data dir). Every action that talks to the sidecar
/// goes through `AppModel.sync` (the `SyncController`).
struct SyncSettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("sync.enabled") private var syncEnabled = false
    @State private var peerInput = ""
    @State private var statusMessage: String?
    @State private var working = false
    @State private var snapshotTimer: Timer?

    var body: some View {
        ScreenScaffold(
            title: "Sync (Experimental)",
            subtitle: "Mirror your derived metrics across two Macs over DefraDB (alpha). Localhost sidecar — your data still stays out of the cloud."
        ) {
            toggleCard
            if syncEnabled {
                statusCard
                nodeCard
                peersCard
                mockCard
                dangerCard
            }
            cautionCard
        }
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    // MARK: - Toggle

    private var toggleCard: some View {
        SyncSection(icon: "arrow.triangle.2.circlepath", title: "Enable") {
            Toggle("Enable cross-Mac sync via DefraDB", isOn: $syncEnabled)
                .onChange(of: syncEnabled) { on in
                    Task {
                        if on { await model.bootstrapSyncIfEnabled() }
                        else { await model.teardownSync() }
                    }
                }
            Text("This brings up a local DefraDB sidecar process and mirrors your sleep, daily, journal, workout, and Apple-Health summaries into it. Peer-to-peer sync replicates them to your other Mac.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    // MARK: - Sidecar status

    @ViewBuilder
    private var statusCard: some View {
        SyncSection(icon: "server.rack", title: "Sidecar") {
            phasePill
            if case .sidecarFailed(let msg) = model.sync?.phase ?? .disabled {
                Text(msg)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusCritical)
                    .textSelection(.enabled)
            }
            if let url = try? SyncPaths.defraDataDir() {
                HStack {
                    Text(url.path)
                        .font(StrandFont.mono(11))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.bordered)
                }
            }
            HStack {
                Button("Pick binary…") { pickBinary() }
                    .buttonStyle(.bordered)
                Button("Install LaunchAgent") { installLaunchAgent() }
                    .buttonStyle(.bordered)
                Button("Retry sync") { Task { await model.sync?.retryNow() } }
                    .buttonStyle(.bordered)
            }
            if let path = UserDefaults.standard.string(forKey: "defra.binary.path") {
                Text("Binary: \(path)")
                    .font(StrandFont.mono(11))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// Show an NSOpenPanel scoped to executables. Stores the picked path in UserDefaults so the
    /// next sidecar start finds it. Use this once after first run — the override is sticky.
    private func pickBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Pick defradb binary"
        panel.title = "Select the defradb executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "defra.binary.path")
        statusMessage = "Binary set to \(url.path). Toggle sync off/on, or hit Retry sync."
    }

    private var phasePill: some View {
        let phase = model.sync?.phase ?? .disabled
        let (label, tone): (String, StrandTone) = {
            switch phase {
            case .disabled: return ("Disabled", .neutral)
            case .sidecarStarting: return ("Starting…", .warning)
            case .sidecarFailed: return ("Failed", .critical)
            case .running: return ("Running", .positive)
            }
        }()
        return StatePill(label, tone: tone, pulsing: phase == .sidecarStarting)
    }

    // MARK: - This node

    private var nodeCard: some View {
        SyncSection(icon: "person.crop.square", title: "This Mac") {
            if let addr = model.sync?.myMultiaddr {
                Text(addr)
                    .font(StrandFont.mono(11))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .textSelection(.enabled)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(addr, forType: .string)
                }
                .buttonStyle(.bordered)
            } else {
                Text("Waiting for sidecar to report its address…")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Text("Paste this address into the \"Connect to peer\" field on your other Mac. Only one side needs to dial — pubsub is symmetric once libp2p connects.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    // MARK: - Connect to peer

    private var peersCard: some View {
        SyncSection(icon: "rectangle.connected.to.line.below", title: "Connect to peer") {
            HStack {
                TextField("Paste peer multiaddr", text: $peerInput)
                    .textFieldStyle(.roundedBorder)
                Button("Connect") { addPeer() }
                    .buttonStyle(.borderedProminent)
                    .tint(StrandPalette.accent)
                    .disabled(peerInput.isEmpty || working)
            }
            let active = model.sync?.peers ?? []
            HStack {
                Image(systemName: active.isEmpty ? "circle" : "circle.fill")
                    .foregroundStyle(active.isEmpty ? StrandPalette.statusWarning : StrandPalette.statusPositive)
                    .font(.system(size: 8))
                Text("Active peers: \(active.count)")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            ForEach(active, id: \.self) { peer in
                Text(peer)
                    .font(StrandFont.mono(11))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .textSelection(.enabled)
            }
            Text("If the count stays at 0 after connecting, allow defradb through System Settings → Network → Firewall on the dialed Mac, or briefly turn the firewall off to test.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            statsRow
        }
    }

    private var statsRow: some View {
        HStack(spacing: 16) {
            label("Outbox", value: "\(model.sync?.outboxPending ?? 0)")
            label("Stuck", value: "\(model.sync?.outboxDead ?? 0)")
            if let t = model.sync?.lastAppliedAt {
                label("Last inbound", value: relTime(t))
            }
            if let t = model.sync?.lastMirrorAt {
                label("Last mirror", value: relTime(t))
            }
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textSecondary)
    }

    private func label(_ name: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).foregroundStyle(StrandPalette.textTertiary)
            Text(value).foregroundStyle(StrandPalette.textPrimary)
                .font(StrandFont.bodyNumber)
        }
    }

    // MARK: - Mock data

    private var mockCard: some View {
        SyncSection(icon: "flask", title: "Mock data") {
            Text("No real WHOOP yet? Seed plausible rows under the dashboard's deviceId so Today / Trends / Sleep populate immediately, and any other Mac you've connected receives them.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            HStack {
                Button("Seed 60 days") {
                    Task { await runSeeder(days: 60) }
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .disabled(working)

                Button("Add 1 day") {
                    Task { await runSeeder(days: 1) }
                }
                .buttonStyle(.bordered)
                .disabled(working)
            }
            Text("Mock deviceId: \(MockSeeder.defaultDeviceId()) (each Mac stamps lastWriterPeer in DefraDB so you can still tell who wrote what)")
                .font(StrandFont.mono(11))
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: - Danger zone

    private var dangerCard: some View {
        SyncSection(icon: "exclamationmark.triangle", title: "Reset") {
            Text("Wipes the DefraDB data dir and forces a fresh schema bootstrap + backfill on next start. Your SQLite store is untouched.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            Button("Reset Defra data dir") { resetDataDir() }
                .buttonStyle(.bordered)
                .tint(StrandPalette.statusCritical)
                .disabled(working)
        }
    }

    private var cautionCard: some View {
        SyncSection(icon: "info.circle", title: "Heads-up") {
            Text("Journal notes use last-edit-wins. If you edit the same note on both Macs while offline, one edit will be overwritten when they reconnect.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            Text("DefraDB alpha runs with an ephemeral libp2p identity, so this Mac's peer multiaddr changes every time the sidecar restarts. Re-add the peer on the other Mac after a restart.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            if let msg = statusMessage {
                Text(msg)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.accent)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Actions

    private func addPeer() {
        let multiaddr = peerInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !multiaddr.isEmpty else { return }
        working = true
        Task {
            do {
                try await model.sync?.addPeer(multiaddr)
                statusMessage = "Added peer."
                peerInput = ""
            } catch {
                statusMessage = "Couldn't add peer: \(error)"
            }
            working = false
        }
    }

    private func installLaunchAgent() {
        working = true
        Task {
            // The SyncController doesn't expose a sidecar handle directly, so we re-derive paths.
            let dir = (try? SyncPaths.defraDataDir()) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let bin = SyncPaths.defraBinaryURL()
            let sidecar = DefraSidecar(binaryURL: bin, dataDir: dir)
            do {
                let url = try sidecar.installLaunchAgent()
                statusMessage = "LaunchAgent written to \(url.path). Load with: launchctl bootstrap gui/$UID \(url.path)"
            } catch {
                statusMessage = "Couldn't install LaunchAgent: \(error)"
            }
            working = false
        }
    }

    private func runSeeder(days: Int) async {
        working = true
        statusMessage = "Seeding…"
        let deviceId = MockSeeder.defaultDeviceId()
        if let store = await model.repo.storeHandle() {
            await MockSeeder.seed(into: store, settings: .init(deviceId: deviceId, nDays: days))
            await model.repo.refresh()
            statusMessage = "Seeded \(days) day\(days == 1 ? "" : "s") under \(deviceId)."
        } else {
            statusMessage = "Couldn't open the store."
        }
        working = false
    }

    private func resetDataDir() {
        working = true
        Task {
            do {
                try await model.sync?.resetDataDir()
                statusMessage = "Defra data dir reset. Toggle sync off and on to bootstrap again."
            } catch {
                statusMessage = "Reset failed: \(error)"
            }
            working = false
        }
    }

    // MARK: - Polling

    private func startPolling() {
        // 5-second snapshot refresh while the panel is visible.
        snapshotTimer?.invalidate()
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { await model.sync?.refreshSnapshot() }
        }
    }

    private func stopPolling() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
    }

    private func relTime(_ t: Date) -> String {
        let s = Int(Date().timeIntervalSince(t))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }
}

// MARK: - Section card (mirrors SettingsView's SettingsSection)

private struct SyncSection<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: icon).foregroundStyle(StrandPalette.accent)
                    Text(title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                content()
            }
        }
    }
}
