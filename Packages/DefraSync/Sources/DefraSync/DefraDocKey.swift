import Foundation

/// Deterministic natural-key builders for each synced collection. Two nodes producing the same
/// logical row land on the same `naturalKey`, which we use as the @unique index on the DefraDB
/// side to dedupe and target updates. Strings only — no JSON, no escaping required as long as no
/// component contains a literal `|`. The SQLite natural-key columns (deviceId, day, question, …)
/// are all caller-controlled identifiers that don't contain `|` in practice; if that ever changes,
/// percent-escape the components here.
public enum DefraDocKey {

    public static func sleepSession(deviceId: String, startTs: Int) -> String {
        "\(deviceId)|\(startTs)"
    }

    public static func dailyMetric(deviceId: String, day: String) -> String {
        "\(deviceId)|\(day)"
    }

    public static func journal(deviceId: String, day: String, question: String) -> String {
        "\(deviceId)|\(day)|\(question)"
    }

    public static func workout(deviceId: String, startTs: Int, sport: String) -> String {
        "\(deviceId)|\(startTs)|\(sport)"
    }

    public static func appleDaily(deviceId: String, day: String) -> String {
        "\(deviceId)|\(day)"
    }

    /// Reverse: extract `(collection, naturalKey)` from a payload dictionary. The mirror code
    /// receives `[String: Any]` after JSON-decoding the observer payload; this is the shared way
    /// to derive the natural key without each call site knowing the per-collection layout.
    public static func key(for collection: String, payload: [String: Any]) -> String? {
        switch collection {
        case "sleepSession":
            guard let dev = payload["deviceId"] as? String,
                  let ts = payload["startTs"] as? Int else { return nil }
            return sleepSession(deviceId: dev, startTs: ts)
        case "dailyMetric":
            guard let dev = payload["deviceId"] as? String,
                  let day = payload["day"] as? String else { return nil }
            return dailyMetric(deviceId: dev, day: day)
        case "journal":
            guard let dev = payload["deviceId"] as? String,
                  let day = payload["day"] as? String,
                  let q = payload["question"] as? String else { return nil }
            return journal(deviceId: dev, day: day, question: q)
        case "workout":
            guard let dev = payload["deviceId"] as? String,
                  let ts = payload["startTs"] as? Int,
                  let sport = payload["sport"] as? String else { return nil }
            return workout(deviceId: dev, startTs: ts, sport: sport)
        case "appleDaily":
            guard let dev = payload["deviceId"] as? String,
                  let day = payload["day"] as? String else { return nil }
            return appleDaily(deviceId: dev, day: day)
        default:
            return nil
        }
    }
}

/// Maps a SQLite collection name (the observer's `collection:` parameter) to the DefraDB GraphQL
/// type name (`SleepSession`, `DailyMetric`, …). The SDL in `DefraSchema` uses these names.
public enum DefraTypeName {
    public static let sleepSession = "SleepSession"
    public static let dailyMetric = "DailyMetric"
    public static let journal = "Journal"
    public static let workout = "Workout"
    public static let appleDaily = "AppleDaily"

    public static func graphqlType(for collection: String) -> String? {
        switch collection {
        case "sleepSession": return sleepSession
        case "dailyMetric": return dailyMetric
        case "journal": return journal
        case "workout": return workout
        case "appleDaily": return appleDaily
        default: return nil
        }
    }

    public static let allCollections: [String] = [
        "sleepSession", "dailyMetric", "journal", "workout", "appleDaily",
    ]
}
