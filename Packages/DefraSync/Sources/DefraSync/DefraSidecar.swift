import Foundation

/// Manages the local `defradb` process. The binary lives at `binaryURL` — typically vendored at
/// `Tools/defradb/defradb-darwin-<arch>` and copied into the app bundle by an Xcode build phase,
/// or installed by the user via Homebrew. The data dir is a sibling of the SQLite store
/// (`~/Library/Application Support/OpenWhoop/defra/`).
///
/// Lifecycle:
/// 1. `start()` first health-checks `http://127.0.0.1:9181/api/v0/health`. If the sidecar is
///    already running (e.g. under launchd), `start()` is a no-op success and `ownsProcess`
///    stays false.
/// 2. Otherwise, spawn `defradb start ...` via `Process()`. Capture stdout/stderr to a log file
///    in the data dir for debugging.
/// 3. `stop()` only kills the process we own; launchd-managed sidecars survive app quit.
///
/// **Sandbox caveat:** `Process()` requires Strand's app sandbox to be off. When sandboxed,
/// `start()` will fail with `SidecarError.sandboxBlocked`; surface that in the UI and prompt the
/// user to install the LaunchAgent (`installLaunchAgent()` writes the plist).
public enum SidecarError: Error {
    case binaryNotFound(URL)
    case sandboxBlocked
    case launchFailed(String)
}

@MainActor
public final class DefraSidecar {
    public let binaryURL: URL
    public let dataDir: URL
    public let httpPort: Int
    public let p2pPort: Int
    public private(set) var ownsProcess = false
    private var process: Process?
    private let client: DefraClient

    public init(binaryURL: URL,
                dataDir: URL,
                httpPort: Int = 9181,
                p2pPort: Int = 9171) {
        self.binaryURL = binaryURL
        self.dataDir = dataDir
        self.httpPort = httpPort
        self.p2pPort = p2pPort
        self.client = DefraClient(baseURL: URL(string: "http://127.0.0.1:\(httpPort)")!)
    }

    public enum Status: Equatable {
        case stopped
        case running(ownsProcess: Bool)
        case starting
    }

    public private(set) var status: Status = .stopped

    /// Start the sidecar (or reuse an already-running one). Polls health until ready or a 10s
    /// deadline expires. Returns the resolved status.
    @discardableResult
    public func start() async throws -> Status {
        if await client.health() {
            status = .running(ownsProcess: false)
            return status
        }
        status = .starting
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            status = .stopped
            throw SidecarError.binaryNotFound(binaryURL)
        }

        let p = Process()
        p.executableURL = binaryURL
        // v1.0.0-rc1 verified flag list. `--enable-mdns` does NOT exist (we tried it, sidecar
        // errored "unknown flag"). `--no-keyring` is REQUIRED on first run or the sidecar
        // refuses to start with a keyring secret error. Trade-off: --no-keyring means the
        // libp2p identity is ephemeral per launch, so the peer multiaddr the other Mac saved
        // becomes stale on restart — user re-adds it.
        p.arguments = [
            "start",
            "--rootdir", dataDir.path,
            "--url", "127.0.0.1:\(httpPort)",
            "--p2paddr", "/ip4/0.0.0.0/tcp/\(p2pPort)",
            "--development",
            "--no-keyring",
        ]

        let logURL = dataDir.appendingPathComponent("defradb.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        p.standardOutput = handle
        p.standardError = handle

        do {
            try p.run()
        } catch {
            status = .stopped
            // POSIXError 1 (EPERM) is what App Sandbox returns when Process is blocked.
            if (error as NSError).domain == NSPOSIXErrorDomain {
                throw SidecarError.sandboxBlocked
            }
            throw SidecarError.launchFailed("\(error)")
        }
        self.process = p
        ownsProcess = true

        // Poll health for up to 10s.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if await client.health() {
                status = .running(ownsProcess: true)
                return status
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        // Health never came up — leave the process running so the user can inspect the log.
        status = .running(ownsProcess: true)
        return status
    }

    /// Terminate the process we spawned. No-op if the sidecar is launchd-managed.
    public func stop() {
        guard ownsProcess, let p = process, p.isRunning else { return }
        p.terminate()
        process = nil
        ownsProcess = false
        status = .stopped
    }

    /// Generate a per-user LaunchAgent plist that runs the vendored binary on login. The user
    /// loads it with `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.noopapp.defradb.plist`.
    /// Returns the path the plist was written to.
    @discardableResult
    public func installLaunchAgent() throws -> URL {
        let agentDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        let plistURL = agentDir.appendingPathComponent("com.noopapp.defradb.plist")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.noopapp.defradb</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryURL.path)</string>
                <string>start</string>
                <string>--rootdir</string><string>\(dataDir.path)</string>
                <string>--url</string><string>127.0.0.1:\(httpPort)</string>
                <string>--p2paddr</string><string>/ip4/0.0.0.0/tcp/\(p2pPort)</string>
                <string>--development</string>
                <string>--no-keyring</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>StandardOutPath</key><string>\(dataDir.appendingPathComponent("defradb.out").path)</string>
            <key>StandardErrorPath</key><string>\(dataDir.appendingPathComponent("defradb.err").path)</string>
        </dict>
        </plist>
        """
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        return plistURL
    }
}
