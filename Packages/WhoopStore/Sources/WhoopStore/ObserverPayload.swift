import Foundation

/// JSON serialization for observer payloads. Each row becomes a single JSON object string the
/// observer can deserialize without needing GRDB or the row structs. Keys mirror the SQLite
/// column names exactly so the inbound apply path on the other side can reconstruct rows.
enum ObserverPayload {
    /// Encode a single row (a `[String: Any]` of JSON-compatible scalars) as a JSON object string.
    /// Returns `nil` if encoding fails — the caller skips the row rather than throwing into the writer.
    static func encode(_ row: [String: Any?]) -> String? {
        var clean: [String: Any] = [:]
        for (k, v) in row {
            switch v {
            case let value?:
                clean[k] = value
            case nil:
                clean[k] = NSNull()
            }
        }
        guard JSONSerialization.isValidJSONObject(clean),
              let data = try? JSONSerialization.data(withJSONObject: clean,
                                                      options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Convenience: encode an array of rows, dropping any that fail to serialize.
    static func encodeAll(_ rows: [[String: Any?]]) -> [String] {
        rows.compactMap(encode)
    }
}
