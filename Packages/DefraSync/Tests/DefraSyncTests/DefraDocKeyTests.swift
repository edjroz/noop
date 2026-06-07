import XCTest
@testable import DefraSync

final class DefraDocKeyTests: XCTestCase {

    func test_sleepSession_deterministic() {
        XCTAssertEqual(DefraDocKey.sleepSession(deviceId: "mock-A", startTs: 1_700_000_000),
                       "mock-A|1700000000")
    }

    func test_dailyMetric_deterministic() {
        XCTAssertEqual(DefraDocKey.dailyMetric(deviceId: "mock-A", day: "2026-06-07"),
                       "mock-A|2026-06-07")
    }

    func test_journal_naturalKey_includes_question() {
        XCTAssertEqual(DefraDocKey.journal(deviceId: "x", day: "2026-06-07", question: "Hydrated?"),
                       "x|2026-06-07|Hydrated?")
    }

    func test_workout_naturalKey_includes_sport() {
        XCTAssertEqual(DefraDocKey.workout(deviceId: "x", startTs: 1_700_000_000, sport: "Running"),
                       "x|1700000000|Running")
    }

    func test_appleDaily_deterministic() {
        XCTAssertEqual(DefraDocKey.appleDaily(deviceId: "apple-health", day: "2026-06-07"),
                       "apple-health|2026-06-07")
    }

    func test_key_recovery_from_payload_each_collection() {
        let cases: [(String, [String: Any], String)] = [
            ("sleepSession", ["deviceId": "x", "startTs": 100], "x|100"),
            ("dailyMetric", ["deviceId": "x", "day": "2026-06-07"], "x|2026-06-07"),
            ("journal", ["deviceId": "x", "day": "2026-06-07", "question": "Q"], "x|2026-06-07|Q"),
            ("workout", ["deviceId": "x", "startTs": 200, "sport": "S"], "x|200|S"),
            ("appleDaily", ["deviceId": "x", "day": "2026-06-07"], "x|2026-06-07"),
        ]
        for (coll, payload, expected) in cases {
            XCTAssertEqual(DefraDocKey.key(for: coll, payload: payload), expected,
                           "collection \(coll) failed")
        }
    }

    func test_key_returns_nil_on_missing_columns() {
        XCTAssertNil(DefraDocKey.key(for: "sleepSession", payload: ["startTs": 100]))
        XCTAssertNil(DefraDocKey.key(for: "journal", payload: ["deviceId": "x", "day": "2026-06-07"]))
        XCTAssertNil(DefraDocKey.key(for: "unknown", payload: ["deviceId": "x"]))
    }

    func test_typeName_mapping_round_trip() {
        for collection in DefraTypeName.allCollections {
            XCTAssertNotNil(DefraTypeName.graphqlType(for: collection),
                            "no graphql type for \(collection)")
        }
        XCTAssertNil(DefraTypeName.graphqlType(for: "hrSample"))
    }
}
