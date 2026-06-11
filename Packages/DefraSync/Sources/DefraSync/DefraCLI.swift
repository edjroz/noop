import Foundation

// MARK: - Deprecated (Phase 3): kept as fallback during embedded-DefraDB stabilization.
//
// No longer called by `DefraSchema` / `DefraP2P` — those now route through
// `DefraEmbedRuntime` (in-process Go via DefraEmbed.xcframework). Left in tree so we
// can `git revert` quickly if the embedded path needs a known-good escape hatch during
// rollout. Slated for deletion after a handful of green end-to-end runs on the embedded
// runtime; reach for it before then if you need to drop back to the sidecar-style flow
// without unwinding the embed work.

/// Shared helper for invoking `defradb client …` against a running sidecar binary.
///
/// Several pieces of the integration historically went through the CLI rather than HTTP
/// because v1.0.0-rc1 doesn't expose the corresponding endpoints, or because the HTTP wire
/// shapes are still moving while the CLI surface is stable:
///   - `defradb client collection add`  (schema bootstrap; HTTP endpoint 404s)
///   - `defradb client p2p collection add`
///   - `defradb client p2p connect`
///
/// All calls block until the subprocess exits and stream stderr back so callers can
/// distinguish "already configured" from a real error.
public enum DefraCLI {

    public enum Error: Swift.Error, Equatable {
        case launchFailed(String)
        case nonZeroExit(code: Int32, stderr: String)
    }

    /// Run `defradb <args>` with the given stdin (or none). Returns stdout on success;
    /// throws `Error.nonZeroExit` with the captured stderr otherwise. Callers that want
    /// to treat specific stderr messages as success (e.g. "already exists") should
    /// catch and inspect.
    @discardableResult
    public static func run(binaryURL: URL,
                           args: [String],
                           stdin: String? = nil) async throws -> String {
        let p = Process()
        p.executableURL = binaryURL
        p.arguments = args

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe

        do {
            try p.run()
        } catch {
            throw Error.launchFailed("\(error)")
        }

        if let s = stdin {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(s.utf8))
        }
        try? stdinPipe.fileHandleForWriting.close()

        // Drain stderr off-thread so a large message doesn't deadlock on a full pipe buffer.
        let stderrTask = Task.detached { stderrPipe.fileHandleForReading.readDataToEndOfFile() }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = await stderrTask.value

        p.waitUntilExit()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        if p.terminationStatus == 0 {
            return stdout
        }
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        throw Error.nonZeroExit(code: p.terminationStatus, stderr: stderr)
    }

    /// Convenience: was this error a "non-zero exit whose stderr contains a tolerable phrase"?
    /// Used by callers (schema bootstrap, pubsub subscribe) to treat "already configured" as
    /// idempotent success.
    public static func isTolerable(_ error: Swift.Error, anyOf phrases: [String]) -> Bool {
        guard case Error.nonZeroExit(_, let stderr) = error else { return false }
        let lower = stderr.lowercased()
        return phrases.contains { lower.contains($0.lowercased()) }
    }
}
