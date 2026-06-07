import Foundation

/// Thin HTTP + WebSocket client for the DefraDB sidecar. Talks REST for schema bootstrap and
/// p2p management, GraphQL-over-HTTP for queries/mutations, and graphql-ws over WebSocket for
/// subscriptions. URLSession-based — no third-party deps.
///
/// All methods are `actor`-safe (the actor is the client itself). Errors surface as `DefraError`
/// so callers (the syncer + subscriber) can branch on "sidecar unreachable" vs "schema rejected"
/// without parsing strings.
public enum DefraError: Error, Equatable {
    case sidecarUnreachable                 // connection refused / network drop
    case http(status: Int, body: String)    // sidecar returned a non-2xx
    case graphqlError(String)               // GraphQL "errors": [...] in the response
    case decoding(String)                   // response didn't match the expected shape
    case schemaRejected(String)             // schema bootstrap returned an alpha-specific error
}

public actor DefraClient {
    public let baseURL: URL                 // e.g. http://127.0.0.1:9181
    private let session: URLSession

    public init(baseURL: URL = URL(string: "http://127.0.0.1:9181")!) {
        self.baseURL = baseURL
        // Short timeouts: the sidecar is localhost — if it doesn't respond in 5s, treat it as down.
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Health & schema

    /// GET /api/v0/health → returns `true` on 200.
    public func health() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/v0/health"))
        req.httpMethod = "GET"
        do {
            let (_, resp) = try await session.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// POST /api/v0/schema with the SDL string. DefraDB returns 200 on success, 4xx on
    /// "schema already exists at this hash" (alpha treats this as an error, not idempotent) —
    /// we map both to success since we cache the hash in UserDefaults already.
    public func loadSchema(_ sdl: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/v0/schema"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(sdl.utf8)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw DefraError.sidecarUnreachable }
        if (200..<300).contains(http.statusCode) { return }
        // 400 from DefraDB alpha when types already exist — surface as success.
        let body = String(data: data, encoding: .utf8) ?? ""
        if body.lowercased().contains("already exists") { return }
        throw DefraError.schemaRejected(body)
    }

    // MARK: - GraphQL query / mutation

    /// POST /api/v0/graphql. Decodes the top-level `{ data, errors }` envelope; returns
    /// the `data` field as-is so callers can pull out the shape they expect.
    @discardableResult
    public func graphql(_ query: String, variables: [String: Any] = [:]) async throws -> Any? {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/v0/graphql"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = variables.isEmpty
            ? ["query": query]
            : ["query": query, "variables": variables]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw DefraError.sidecarUnreachable
        }
        guard let http = resp as? HTTPURLResponse else { throw DefraError.sidecarUnreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw DefraError.http(status: http.statusCode,
                                  body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DefraError.decoding("non-object response")
        }
        if let errs = json["errors"] as? [[String: Any]], !errs.isEmpty {
            let messages = errs.compactMap { $0["message"] as? String }
            throw DefraError.graphqlError(messages.joined(separator: "; "))
        }
        return json["data"]
    }

    // MARK: - P2P management

    /// GET /api/v0/p2p/info — returns this node's full libp2p multiaddr (used in Settings to
    /// show "this node's peer address" for the user to paste on the other Mac).
    public func selfMultiaddr() async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/v0/p2p/info"))
        req.httpMethod = "GET"
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DefraError.sidecarUnreachable
        }
        // DefraDB alpha returns either {"PeerInfo": {"Addrs": ["/ip4/..."], "ID": "12D3..."}}
        // or a flat string. Be lenient.
        if let s = String(data: data, encoding: .utf8), s.hasPrefix("\"") {
            return s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DefraError.decoding("p2p/info non-object")
        }
        if let info = json["PeerInfo"] as? [String: Any],
           let addrs = info["Addrs"] as? [String],
           let id = info["ID"] as? String,
           let first = addrs.first {
            return "\(first)/p2p/\(id)"
        }
        if let addr = json["multiaddr"] as? String { return addr }
        throw DefraError.decoding("p2p/info shape unknown")
    }

    /// POST /api/v0/p2p/replicators with the peer's multiaddr.
    public func addPeer(_ multiaddr: String, schemas: [String]) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/v0/p2p/replicators"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["addr": multiaddr, "schemas": schemas]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw DefraError.sidecarUnreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw DefraError.http(status: http.statusCode,
                                  body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// GET /api/v0/p2p/replicators → list of currently-configured replicators (peers).
    public func listPeers() async throws -> [String] {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/v0/p2p/replicators"))
        req.httpMethod = "GET"
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DefraError.sidecarUnreachable
        }
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { rep in
            // Tolerate two response shapes the alpha has shipped over time.
            if let info = rep["Info"] as? [String: Any], let id = info["ID"] as? String { return id }
            return rep["addr"] as? String
        }
    }
}
