import XCTest
@testable import DefraSync
import WhoopStore

/// The outbox lives on WhoopStore (v10 migration). These tests run against `WhoopStore.inMemory()`
/// to verify enqueue → coalesce → drain → attempts-cap semantics without spinning up DefraDB.
final class OutboxTests: XCTestCase {

    func test_enqueue_coalesces_on_collection_and_naturalKey() async throws {
        let store = try await WhoopStore.inMemory()

        // Two upserts of the same logical row should collapse to one outbox entry.
        try await store.enqueueOutbox(collection: "dailyMetric",
                                       naturalKey: "mock-A|2026-06-07",
                                       payloadJSON: #"{"recovery":50}"#)
        try await store.enqueueOutbox(collection: "dailyMetric",
                                       naturalKey: "mock-A|2026-06-07",
                                       payloadJSON: #"{"recovery":75}"#)

        let pending = try await store.outboxFetchBatch(limit: 100)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].payloadJSON, #"{"recovery":75}"#,
                       "second enqueue should overwrite the first payload")
    }

    func test_enqueue_then_ack_clears() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.enqueueOutbox(collection: "journal",
                                       naturalKey: "x|2026-06-07|Q",
                                       payloadJSON: "{}")
        let pending = try await store.outboxFetchBatch(limit: 10)
        XCTAssertEqual(pending.count, 1)
        try await store.outboxAck(id: pending[0].id)
        let after = try await store.outboxFetchBatch(limit: 10)
        XCTAssertTrue(after.isEmpty)
    }

    func test_bump_attempts_eventually_excludes_from_drain() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.enqueueOutbox(collection: "journal",
                                       naturalKey: "x|2026-06-07|Q",
                                       payloadJSON: "{}")
        var pending = try await store.outboxFetchBatch(limit: 10)
        XCTAssertEqual(pending.count, 1)
        let id = pending[0].id
        for _ in 0..<10 { try await store.outboxBumpAttempts(id: id) }
        pending = try await store.outboxFetchBatch(limit: 10)
        XCTAssertTrue(pending.isEmpty, "rows at the cap should be excluded from drain")
        let counts = try await store.outboxCounts()
        XCTAssertEqual(counts.pending, 0)
        XCTAssertEqual(counts.dead, 1)
    }

    func test_fetch_orders_oldest_first() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.enqueueOutbox(collection: "journal", naturalKey: "k1", payloadJSON: "{}")
        try await Task.sleep(nanoseconds: 1_100_000_000)    // 1.1s so enqueuedAt differs by 1
        try await store.enqueueOutbox(collection: "journal", naturalKey: "k2", payloadJSON: "{}")
        let pending = try await store.outboxFetchBatch(limit: 10)
        XCTAssertEqual(pending.map(\.naturalKey), ["k1", "k2"])
    }
}
