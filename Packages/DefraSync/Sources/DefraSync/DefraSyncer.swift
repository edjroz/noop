import Foundation
import WhoopStore

/// Outbound mirror: `WhoopStoreObserver` impl that publishes every local upsert to DefraDB and
/// queues into the SQLite outbox when the sidecar is unreachable.
///
/// Loop prevention: the inbound apply path (`DefraSubscriber`) wraps its `store.upsert*` calls
/// in `SyncContext.$applyingFromDefra.withValue(true) { ... }`. WhoopStore uses `Task { ... }`
/// (not `Task.detached`) to invoke us, so the task-local propagates here. We short-circuit
/// without publishing or enqueuing — that row already came from the network.
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
        // Inbound apply suppression — see SyncContext docs.
        if SyncContext.applyingFromDefra { return }
        for json in payloadsJSON {
            await publishOrQueue(collection: collection, payloadJSON: json)
        }
    }

    // MARK: - Publish path

    /// Try the sidecar; on any failure, enqueue to the outbox and return. Failures must not
    /// throw back into the writer — see WhoopStore's `notifyObserver`.
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

    /// One round-trip: query existing _docID by naturalKey → create or update. The query+mutation
    /// could be batched, but at 5–30 rows/day per collection it's a non-issue.
    private func publish(type: String, naturalKey: String, payload: [String: Any]) async throws {
        let existing = try await lookupDocID(type: type, naturalKey: naturalKey)
        var stamped = payload
        stamped["naturalKey"] = naturalKey
        stamped["lastWriterPeer"] = nodeLabel
        stamped["lastWriterTs"] = Int(Date().timeIntervalSince1970)

        if let docID = existing {
            try await mutate(update: type, docID: docID, payload: stamped)
        } else {
            try await mutate(create: type, payload: stamped)
        }
    }

    private func lookupDocID(type: String, naturalKey: String) async throws -> String? {
        let q = "query($k: String) { \(type)(filter: {naturalKey: {_eq: $k}}) { _docID } }"
        guard let data = try await client.graphql(q, variables: ["k": naturalKey]) as? [String: Any],
              let arr = data[type] as? [[String: Any]],
              let first = arr.first
        else { return nil }
        return first["_docID"] as? String
    }

    private func mutate(create type: String, payload: [String: Any]) async throws {
        let payloadStr = jsonString(payload) ?? "{}"
        // DefraDB mutation: create_<Type>(input: {...}).
        let m = "mutation { create_\(type)(input: \(toGraphQLObject(payloadStr))) { _docID } }"
        _ = try await client.graphql(m)
    }

    private func mutate(update type: String, docID: String, payload: [String: Any]) async throws {
        let payloadStr = jsonString(payload) ?? "{}"
        let m = "mutation { update_\(type)(docID: \"\(docID)\", input: \(toGraphQLObject(payloadStr))) { _docID } }"
        _ = try await client.graphql(m)
    }

    // MARK: - Outbox drain

    /// Pull pending rows, publish, ack on success. Best-effort — silent no-op if the sidecar is
    /// still down. Caller (SyncController) decides when to call this (sidecar-healthy transition,
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

    private func jsonString(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// DefraDB's `input` argument accepts a JSON-shaped GraphQL object literal. We already have
    /// a JSON string — pass it through verbatim (it parses as a GraphQL value because DefraDB's
    /// scalar literals match JSON's syntax).
    private func toGraphQLObject(_ jsonString: String) -> String { jsonString }
}
