import XCTest
@testable import DefraSync
import WhoopStore

/// Validates that the `WhoopStoreObserver` hook fires on each `upsert*` by default, and that
/// passing `skipObserver: true` (the inbound-apply path used by `DefraSubscriber`) suppresses
/// the notification — the load-bearing loop-prevention behavior. Uses an in-memory store and
/// a recording observer — no DefraDB needed.
final class ObserverHookTests: XCTestCase {

    actor Recorder: WhoopStoreObserver {
        var calls: [(collection: String, deviceId: String, count: Int)] = []

        func didUpsert(collection: String, deviceId: String, payloadsJSON: [String]) async {
            calls.append((collection, deviceId, payloadsJSON.count))
        }
    }

    func test_observer_called_for_each_upsert_collection() async throws {
        let store = try await WhoopStore.inMemory()
        let rec = Recorder()
        await store.setObserver(rec)

        try await store.upsertSleepSessions([
            CachedSleepSession(startTs: 1, endTs: 2, efficiency: nil,
                                restingHr: nil, avgHrv: nil, stagesJSON: nil)
        ], deviceId: "x")
        try await store.upsertDailyMetrics([
            DailyMetric(day: "2026-06-07", totalSleepMin: nil, efficiency: nil,
                        deepMin: nil, remMin: nil, lightMin: nil,
                        disturbances: nil, restingHr: nil, avgHrv: nil,
                        recovery: nil, strain: nil, exerciseCount: nil)
        ], deviceId: "x")
        try await store.upsertJournal([
            JournalEntry(day: "2026-06-07", question: "Q", answeredYes: true, notes: nil)
        ], deviceId: "x")
        try await store.upsertWorkouts([
            WorkoutRow(startTs: 1, endTs: 2, sport: "S", source: "src",
                       durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil,
                       strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)
        ], deviceId: "x")
        try await store.upsertAppleDaily([
            AppleDaily(day: "2026-06-07", steps: 1, activeKcal: nil, basalKcal: nil,
                       vo2max: nil, avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: nil)
        ], deviceId: "x")

        // The observer fires from a child Task — give it a beat to land.
        try await Task.sleep(nanoseconds: 200_000_000)
        let calls = await rec.calls
        let collections = Set(calls.map(\.collection))
        XCTAssertEqual(collections,
                       ["sleepSession", "dailyMetric", "journal", "workout", "appleDaily"])
        XCTAssertTrue(calls.allSatisfy { $0.count >= 1 })
    }

    func test_skipObserver_suppresses_notification() async throws {
        let store = try await WhoopStore.inMemory()
        let rec = Recorder()
        await store.setObserver(rec)

        // Mirror DefraSubscriber.apply: every inbound-apply call passes skipObserver: true.
        try await store.upsertSleepSessions([
            CachedSleepSession(startTs: 1, endTs: 2, efficiency: nil,
                                restingHr: nil, avgHrv: nil, stagesJSON: nil)
        ], deviceId: "x", skipObserver: true)
        try await store.upsertDailyMetrics([
            DailyMetric(day: "2026-06-07", totalSleepMin: nil, efficiency: nil,
                        deepMin: nil, remMin: nil, lightMin: nil,
                        disturbances: nil, restingHr: nil, avgHrv: nil,
                        recovery: nil, strain: nil, exerciseCount: nil)
        ], deviceId: "x", skipObserver: true)
        try await store.upsertJournal([
            JournalEntry(day: "2026-06-07", question: "Q", answeredYes: true, notes: nil)
        ], deviceId: "x", skipObserver: true)
        try await store.upsertWorkouts([
            WorkoutRow(startTs: 1, endTs: 2, sport: "S", source: "src",
                       durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil,
                       strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)
        ], deviceId: "x", skipObserver: true)
        try await store.upsertAppleDaily([
            AppleDaily(day: "2026-06-07", steps: 1, activeKcal: nil, basalKcal: nil,
                       vo2max: nil, avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: nil)
        ], deviceId: "x", skipObserver: true)

        try await Task.sleep(nanoseconds: 200_000_000)
        let calls = await rec.calls
        XCTAssertTrue(calls.isEmpty,
                      "skipObserver: true must NOT fire the observer (loop prevention)")
    }
}
