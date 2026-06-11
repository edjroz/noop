import Foundation
import WhoopStore

/// Outbound mirror: `WhoopStoreObserver` impl that publishes every local upsert to the
/// in-process DefraDB and queues into the SQLite outbox when DefraDB rejects the mutation.
///
/// Loop prevention: the inbound apply path (`DefraSubscriber.apply`) passes `skipObserver: true`
/// when calling `store.upsert*`, so this observer is never notified for rows that arrived over
/// the network. The earlier `@TaskLocal`-based mechanism (see git history for `SyncContext`)
/// was unreliable across Swift actor boundaries and `Task { }` initializers; the explicit
/// parameter can't leak.
public actor DefraSyncer: WhoopStoreObserver {
    private let client: DefraClient
    private let store: WhoopStore
    /// Identifier this node stamps onto every outbound mutation (`lastWriterPeer` field). The
    /// settings UI shows this alongside the multiaddr so the user can tell which Mac wrote what.
    public let nodeLabel: String

    public init(client: DefraClient, store: WhoopStore, nodeLabel: String) {
        self.client = client
        self.store = store
        self.nodeLabel = nodeLabel
    }

    // MARK: - WhoopStoreObserver

    public func didUpsert(collection: String, deviceId: String, payloadsJSON: [String]) async {
        // Inbound apply suppression now lives upstream in WhoopStore: DefraSubscriber.apply
        // passes `skipObserver: true` so this method is only reached for genuinely-local writes.
        // Earlier versions guarded here on `SyncContext.applyingFromDefra` (@TaskLocal), which
        // proved unreliable across actor boundaries and `Task { }` initializers.
        for json in payloadsJSON {
            await publishOrQueue(collection: collection, payloadJSON: json)
        }
    }

    // MARK: - Publish path

    /// Try the in-process DefraDB; on any failure, enqueue to the outbox and return. Failures
    /// must not throw back into the writer — see WhoopStore's `notifyObserver`.
    private func publishOrQueue(collection: String, payloadJSON: String) async {
        guard let payload = decodePayload(payloadJSON),
              let key = DefraDocKey.key(for: collection, payload: payload),
              let type = DefraTypeName.graphqlType(for: collection)
        else { return }
        do {
            try await publish(type: type, naturalKey: key, payload: payload)
        } catch {
            // Outbox is keyed (collection, naturalKey) so re-enqueues coalesce.
            try? await store.enqueueOutbox(collection: collection, naturalKey: key, payloadJSON: payloadJSON)
        }
    }

    /// Single-round-trip upsert via DefraDB's `upsert_<Type>` mutation introduced in v1.0.0-rc1.
    /// Atomic: defradb decides "create vs update" server-side using the `filter`. We always pass
    /// the same row for both `add` and `update` so the result is identical either way.
    private func publish(type: String, naturalKey: String, payload: [String: Any]) async throws {
        var stamped = payload
        stamped["naturalKey"] = naturalKey
        stamped["lastWriterPeer"] = nodeLabel
        stamped["lastWriterTs"] = Int(Date().timeIntervalSince1970)
        let payloadGQL = Self.graphqlLiteral(stamped)
        let keyGQL = Self.graphqlLiteral(naturalKey)
        let m = """
        mutation {
          upsert_\(type)(
            filter: {naturalKey: {_eq: \(keyGQL)}},
            add: \(payloadGQL),
            update: \(payloadGQL)
          ) { _docID }
        }
        """
        _ = try await client.graphql(m)
    }

    // MARK: - Outbox drain

    /// Pull pending rows, publish, ack on success. Best-effort — silent no-op if the host is
    /// still down. Caller (SyncController) decides when to call this (host-healthy transition,
    /// periodic 30s timer, manual "Retry sync" button).
    public func drainOutbox(batchSize: Int = 100) async {
        let rows = (try? await store.outboxFetchBatch(limit: batchSize)) ?? []
        for row in rows {
            guard let type = DefraTypeName.graphqlType(for: row.collection),
                  let payload = decodePayload(row.payloadJSON)
            else {
                // Malformed — drop it so we don't keep retrying garbage.
                try? await store.outboxAck(id: row.id)
                continue
            }
            do {
                try await publish(type: type, naturalKey: row.naturalKey, payload: payload)
                try? await store.outboxAck(id: row.id)
            } catch {
                try? await store.outboxBumpAttempts(id: row.id)
            }
        }
    }

    // MARK: - Initial backfill

    /// Initial full-table mirror on first sync-enable. Walks each table page by page and publishes
    /// through the regular path. Idempotent on the DefraDB side (naturalKey upsert), so re-running
    /// is safe — UserDefaults guards against doing it more than once per node anyway.
    public func backfillCollection(_ collection: String,
                                   page: (Int) async throws -> [String]?) async throws {
        var offset = 0
        let pageSize = 500
        while true {
            guard let jsons = try await page(offset), !jsons.isEmpty else { return }
            for json in jsons {
                await publishOrQueue(collection: collection, payloadJSON: json)
            }
            if jsons.count < pageSize { return }
            offset += jsons.count
        }
    }

    // MARK: - JSON / GraphQL plumbing

    private func decodePayload(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Serialize a value as a GraphQL literal. GraphQL object syntax overlaps with JSON
    /// (scalars + arrays) but **object keys are unquoted** (`{key: value}`, not `{"key": value}`).
    /// We can't reuse JSONSerialization directly because of that one difference.
    private static func graphqlLiteral(_ value: Any) -> String {
        switch value {
        case _ as NSNull:
            return "null"
        case let s as String:
            return "\"\(escape(s))\""
        case let n as NSNumber:
            // NSNumber covers Int, Double, Float, Bool. Need to distinguish Bool because
            // its objCType is "c" while numbers are "i", "q", "d", etc.
            if CFNumberGetType(n) == .charType || CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            return n.stringValue
        case let arr as [Any]:
            return "[\(arr.map(graphqlLiteral).joined(separator: ", "))]"
        case let dict as [String: Any]:
            let pairs = dict.keys.sorted().map { k -> String in
                "\(k): \(graphqlLiteral(dict[k]!))"
            }
            return "{\(pairs.joined(separator: ", "))}"
        case let opt as Any?:
            if let v = opt { return graphqlLiteral(v) }
            return "null"
        default:
            return "null"
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }
}
