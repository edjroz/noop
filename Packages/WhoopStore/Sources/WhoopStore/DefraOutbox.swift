import Foundation
import GRDB

/// One pending mutation queued for the DefraDB sidecar. Lives in `defra_outbox` (v10).
public struct DefraOutboxRow: Equatable {
    public let id: Int64
    public let collection: String
    public let naturalKey: String
    public let payloadJSON: String
    public let enqueuedAt: Int
    public let attempts: Int
}

extension WhoopStore {

    /// Enqueue (or replace) a pending mutation. Coalesces on `(collection, naturalKey)` so a row
    /// upserted repeatedly while offline produces one outbox entry, not N.
    public func enqueueOutbox(collection: String, naturalKey: String, payloadJSON: String) async throws {
        let now = Int(Date().timeIntervalSince1970)
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO defra_outbox (collection, naturalKey, payloadJSON, enqueuedAt, attempts)
                VALUES (?, ?, ?, ?, 0)
                ON CONFLICT(collection, naturalKey) DO UPDATE SET
                    payloadJSON = excluded.payloadJSON,
                    enqueuedAt = excluded.enqueuedAt
                """, arguments: [collection, naturalKey, payloadJSON, now])
        }
    }

    /// Fetch the next `limit` pending mutations, oldest first.
    public func outboxFetchBatch(limit: Int = 100) async throws -> [DefraOutboxRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT id, collection, naturalKey, payloadJSON, enqueuedAt, attempts FROM defra_outbox
                WHERE attempts < 10
                ORDER BY enqueuedAt ASC, id ASC LIMIT ?
                """, arguments: [limit])
                .map { DefraOutboxRow(id: $0["id"], collection: $0["collection"],
                                     naturalKey: $0["naturalKey"], payloadJSON: $0["payloadJSON"],
                                     enqueuedAt: $0["enqueuedAt"], attempts: $0["attempts"]) }
        }
    }

    /// Mark a successful drain — remove the row.
    public func outboxAck(id: Int64) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM defra_outbox WHERE id = ?", arguments: [id])
        }
    }

    /// Bump the attempts counter on a failed drain. The fetch query filters `attempts < 10`, so
    /// once a row hits the cap it stops getting drained — surface it in the UI as "stuck".
    public func outboxBumpAttempts(id: Int64) async throws {
        try syncWrite { db in
            try db.execute(sql: "UPDATE defra_outbox SET attempts = attempts + 1 WHERE id = ?",
                           arguments: [id])
        }
    }

    /// Diagnostic counts for the settings UI.
    public func outboxCounts() async throws -> (pending: Int, dead: Int) {
        try syncRead { db in
            let pending = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM defra_outbox WHERE attempts < 10") ?? 0
            let dead = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM defra_outbox WHERE attempts >= 10") ?? 0
            return (pending, dead)
        }
    }
}
