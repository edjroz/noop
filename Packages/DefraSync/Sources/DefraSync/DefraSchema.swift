import Foundation
import CryptoKit

/// GraphQL SDL for the 5 synced collections + idempotent bootstrap into a running DefraDB sidecar.
///
/// Each type has a `naturalKey` field that is the deterministic primary identifier across nodes —
/// see `DefraDocKey` for the format. Marking it `@index(unique: true)` lets us upsert by querying
/// `_docID` first and then issuing a `create` or `update`, instead of relying on DefraDB's
/// content-addressed `_docID` semantics (which would diverge across nodes for the same logical row).
///
/// `lastWriterPeer` / `lastWriterTs` are denormalized provenance fields the mirror sets on every
/// write. They power "last sync time per collection" in Settings and the high-water-mark catch-up
/// query on subscriber reconnect.
public enum DefraSchema {

    public static let sdl: String = """
    type SleepSession {
      naturalKey: String @index(unique: true)
      deviceId: String @index
      startTs: Int @index
      endTs: Int
      efficiency: Float
      restingHr: Int
      avgHrv: Float
      stagesJSON: String
      lastWriterPeer: String
      lastWriterTs: Int
    }

    type DailyMetric {
      naturalKey: String @index(unique: true)
      deviceId: String @index
      day: String @index
      totalSleepMin: Float
      efficiency: Float
      deepMin: Float
      remMin: Float
      lightMin: Float
      disturbances: Int
      restingHr: Int
      avgHrv: Float
      recovery: Float
      strain: Float
      exerciseCount: Int
      spo2Pct: Float
      skinTempDevC: Float
      respRateBpm: Float
      steps: Int
      activeKcalEst: Float
      lastWriterPeer: String
      lastWriterTs: Int
    }

    type Journal {
      naturalKey: String @index(unique: true)
      deviceId: String @index
      day: String @index
      question: String
      answeredYes: Boolean
      notes: String
      lastWriterPeer: String
      lastWriterTs: Int
    }

    type Workout {
      naturalKey: String @index(unique: true)
      deviceId: String @index
      startTs: Int @index
      endTs: Int
      sport: String
      source: String
      durationS: Float
      energyKcal: Float
      avgHr: Int
      maxHr: Int
      strain: Float
      distanceM: Float
      zonesJSON: String
      notes: String
      lastWriterPeer: String
      lastWriterTs: Int
    }

    type AppleDaily {
      naturalKey: String @index(unique: true)
      deviceId: String @index
      day: String @index
      steps: Int
      activeKcal: Float
      basalKcal: Float
      vo2max: Float
      avgHr: Int
      maxHr: Int
      walkingHr: Int
      weightKg: Float
      lastWriterPeer: String
      lastWriterTs: Int
    }
    """

    /// Stable SHA-256 hex of the SDL — used as the `UserDefaults["defra.schema.hash"]` cache key
    /// so bootstrap is a no-op when the schema hasn't changed since the last successful load.
    public static var sha256Hex: String {
        let data = Data(sdl.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Load `sdl` into a running DefraDB sidecar.
    ///
    /// v1.0.0-rc1 dropped the `POST /api/v0/schema` HTTP endpoint, so we shell out to the same
    /// binary that's running the sidecar: `defradb client collection add --url <url> -`, piping
    /// the SDL on stdin. If the schema is already loaded, defradb prints "already exists" to
    /// stderr and exits non-zero — we treat that as success so re-runs are safe.
    public static func bootstrap(binaryURL: URL,
                                 httpPort: Int = 9181,
                                 sdl: String = sdl) async throws {
        do {
            _ = try await DefraCLI.run(
                binaryURL: binaryURL,
                args: ["client", "collection", "add", "--url", "127.0.0.1:\(httpPort)", "-"],
                stdin: sdl
            )
        } catch let error where DefraCLI.isTolerable(error, anyOf: [
            "already exists", "already added", "schema is already"
        ]) {
            return
        }
    }
}
