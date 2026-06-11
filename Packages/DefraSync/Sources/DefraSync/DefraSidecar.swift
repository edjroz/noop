import Foundation

/// Brings up the embedded DefraDB inside the host process.
///
/// Phase 3 of the embed work removed the child-process path entirely. The historical name
/// "sidecar" stays because `SyncController` and the Sync settings view treat this as the
/// runtime lifecycle for an embedded DefraDB instance regardless of whether the implementation
/// is in-process (current) or child-process (previous). Renaming the type cascades through too
/// many callers for a Phase 3 commit; we can rename after the experiment stabilizes.
///
/// Lifecycle:
/// 1. `start()` first probes the in-process HTTP server via `DefraClient.health()` — useful
///    when SwiftUI previews instantiate the controller twice in dev tooling. If the server is
///    already up, no-op.
/// 2. Otherwise, call `DefraEmbedRuntime.start(...)` which spins up the Go-side `node.Node`,
///    binds HTTP on `httpPort`, libp2p on `p2pPort`. Returns when the listener is bound.
/// 3. `stop()` invokes `DefraEmbedRuntime.stop()`.
public enum SidecarError: Error {
    case launchFailed(String)
}

@MainActor
public final class DefraSidecar {
    public let dataDir: URL
    public let httpPort: Int
    public let p2pPort: Int
    private let client: DefraClient

    public init(dataDir: URL,
                httpPort: Int = 9181,
                p2pPort: Int = 9171) {
        self.dataDir = dataDir
        self.httpPort = httpPort
        self.p2pPort = p2pPort
        self.client = DefraClient(baseURL: URL(string: "http://127.0.0.1:\(httpPort)")!)
    }

    public enum Status: Equatable {
        case stopped
        /// Kept (instead of bare `running`) for source-compat with existing `case .running(ownsProcess:)`
        /// callers in `SyncSettingsView`. Always reports `true` — the embedded instance is "ours".
        case running(ownsProcess: Bool)
        case starting
    }

    public private(set) var status: Status = .stopped

    /// Start the embedded DefraDB. Idempotent: if another part of the app already brought it up
    /// (HTTP probe succeeds), no-op success.
    @discardableResult
    public func start() async throws -> Status {
        if await client.health() {
            status = .running(ownsProcess: true)
            return status
        }
        status = .starting
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        do {
            try DefraEmbedRuntime.start(
                rootdir: dataDir.path,
                httpListen: "127.0.0.1:\(httpPort)",
                p2pListen: "/ip4/0.0.0.0/tcp/\(p2pPort)",
                devMode: true
            )
        } catch {
            status = .stopped
            throw SidecarError.launchFailed("\(error)")
        }
        status = .running(ownsProcess: true)
        return status
    }

    /// Stop the embedded instance. Best-effort; errors are swallowed because Stop is on the
    /// shutdown path where we have nothing useful to do with them.
    public func stop() {
        try? DefraEmbedRuntime.stop()
        status = .stopped
    }
}
