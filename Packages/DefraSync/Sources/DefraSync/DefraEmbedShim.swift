// `DefraEmbed` is the *module name* declared inside the xcframework's own
// `Modules/module.modulemap` (`framework module DefraEmbed { umbrella header ... }`).
// `DefraEmbedFFI` is the SwiftPM .binaryTarget name (used for path resolution); the Swift
// `import` follows the framework's module name, which is independent of that.
import DefraEmbed
import Foundation

/// Swift-idiomatic façade over the `Defra*` C ABI exposed by `DefraEmbed.xcframework`.
///
/// The framework runs DefraDB as in-process Go code; this file hides the manual memory
/// management (`DefraFreeString` after every returned `*char`), the JSON encoding we use to
/// pass `[String]` across the C boundary, and the nil-on-success error convention.
///
/// Stage A of Phase 3: the shim exists, but no caller uses it yet. Stage B switches
/// `DefraHost` / `DefraSchema` / `DefraP2P` over.
public enum DefraEmbedRuntime {

    public enum Error: Swift.Error, Equatable {
        case failure(String)
    }

    // MARK: - Lifecycle

    /// Bring up the in-process DefraDB at `rootdir`, binding HTTP at `httpListen` and libp2p at
    /// `p2pListen`. `devMode = true` matches the legacy CLI's `--development --no-keyring` posture.
    public static func start(rootdir: String,
                             httpListen: String,
                             p2pListen: String,
                             devMode: Bool) throws {
        try rootdir.withCString { r in
            try httpListen.withCString { h in
                try p2pListen.withCString { p in
                    try throwIfErrorPtr(
                        DefraStartNode(
                            UnsafeMutablePointer(mutating: r),
                            UnsafeMutablePointer(mutating: h),
                            UnsafeMutablePointer(mutating: p),
                            devMode ? 1 : 0
                        )
                    )
                }
            }
        }
    }

    /// Tear it down. No-op if nothing is running.
    public static func stop() throws {
        try throwIfErrorPtr(DefraStopNode())
    }

    /// `http://127.0.0.1:9181` (or whatever was passed to `start`). `nil` when not running.
    public static func apiBaseURL() -> String? {
        guard let cstr = DefraAPIBaseURL() else { return nil }
        defer { DefraFreeString(cstr) }
        return String(cString: cstr)
    }

    // MARK: - Schema + p2p (one-call each)

    public static func loadCollections(_ sdl: String) throws {
        try sdl.withCString { s in
            try throwIfErrorPtr(DefraLoadCollections(UnsafeMutablePointer(mutating: s)))
        }
    }

    public static func p2pSubscribe(_ collectionNames: [String]) throws {
        try withJSON(collectionNames) { json in
            try throwIfErrorPtr(DefraP2PSubscribe(UnsafeMutablePointer(mutating: json)))
        }
    }

    public static func p2pConnect(_ multiaddr: String) throws {
        try multiaddr.withCString { m in
            try throwIfErrorPtr(DefraP2PConnect(UnsafeMutablePointer(mutating: m)))
        }
    }

    public static func p2pReplicateTo(_ multiaddr: String, collectionNames: [String]) throws {
        try multiaddr.withCString { m in
            try withJSON(collectionNames) { json in
                try throwIfErrorPtr(
                    DefraP2PReplicateTo(
                        UnsafeMutablePointer(mutating: m),
                        UnsafeMutablePointer(mutating: json)
                    )
                )
            }
        }
    }

    // MARK: - Diagnostic reads

    public static func selfMultiaddrs() throws -> [String] {
        try outParamJSONStrings(DefraSelfMultiaddrsJSON)
    }

    public static func activePeers() throws -> [String] {
        try outParamJSONStrings(DefraActivePeersJSON)
    }

    // MARK: - C ABI plumbing

    /// The Go side returns nil on success and a C-allocated message on error; we own freeing it.
    @inline(__always)
    private static func throwIfErrorPtr(_ cstr: UnsafeMutablePointer<CChar>?) throws {
        guard let cstr else { return }
        defer { DefraFreeString(cstr) }
        throw Error.failure(String(cString: cstr))
    }

    /// `Defra*JSON(result:errOut:)` signatures take two out-pointers and split success/error
    /// across them. Wrap that into a Swift `[String]` (or throw).
    private static func outParamJSONStrings(
        _ call: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Void
    ) throws -> [String] {
        var result: UnsafeMutablePointer<CChar>? = nil
        var errOut: UnsafeMutablePointer<CChar>? = nil
        call(&result, &errOut)
        defer {
            if let result { DefraFreeString(result) }
            if let errOut { DefraFreeString(errOut) }
        }
        if let errOut {
            throw Error.failure(String(cString: errOut))
        }
        guard let result else { return [] }
        let json = String(cString: result)
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    /// `[String]` ↔ JSON the Go side decodes. Reusable so caller's `withCString` chain stays flat.
    private static func withJSON<T>(_ items: [String], _ body: (UnsafePointer<CChar>) throws -> T) throws -> T {
        let data = (try? JSONEncoder().encode(items)) ?? Data("[]".utf8)
        let json = String(data: data, encoding: .utf8) ?? "[]"
        return try json.withCString(body)
    }
}
