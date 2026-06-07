import Foundation
import WhoopStore

/// Synthetic data source for the DefraDB sync experiment. We don't have real WHOOP exports yet,
/// so we generate plausible rows that exercise the same upsert paths a real import would. Writes
/// flow through the WhoopStoreObserver → DefraSyncer, identical to the production path.
///
/// `nodeFlavor` distinguishes data originating on the desktop vs the laptop: it's used as a
/// suffix in the deviceId (`mock-A` vs `mock-B`) so after sync you can visually verify "the
/// other Mac's rows showed up" rather than guessing at convergence.
public enum MockSeeder {

    public struct Settings {
        public let deviceId: String
        public let nDays: Int
        public init(deviceId: String, nDays: Int = 60) {
            self.deviceId = deviceId; self.nDays = nDays
        }
    }

    /// Generate `nDays` of synthetic rows ending today and upsert them. Deterministic per
    /// (deviceId, day) — re-running is idempotent, the natural-key upserts overwrite in place.
    public static func seed(into store: WhoopStore, settings: Settings) async {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var days: [DailyMetric] = []
        var sleeps: [CachedSleepSession] = []
        var journal: [JournalEntry] = []
        var workouts: [WorkoutRow] = []
        var apple: [AppleDaily] = []

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"

        for back in (0..<settings.nDays).reversed() {
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let dayStr = df.string(from: day)
            var r = seededRand(deviceId: settings.deviceId, day: dayStr)
            // Stable plausible numbers from the per-row hash.
            let recovery = 30.0 + r.double(in: 0...60)
            let strain = 8.0 + r.double(in: 0...10)
            let rhr = 50 + r.int(in: 0...15)
            let hrv = 40.0 + r.double(in: 0...40)
            let totalSleepMin = 360.0 + r.double(in: 0...120)
            let efficiency = 75.0 + r.double(in: 0...20)
            let deep = totalSleepMin * 0.15
            let rem = totalSleepMin * 0.22
            let light = totalSleepMin - deep - rem

            days.append(DailyMetric(
                day: dayStr, totalSleepMin: totalSleepMin, efficiency: efficiency,
                deepMin: deep, remMin: rem, lightMin: light,
                disturbances: r.int(in: 0...5), restingHr: rhr, avgHrv: hrv,
                recovery: recovery, strain: strain, exerciseCount: r.int(in: 0...2),
                spo2Pct: 94.0 + r.double(in: 0...4),
                skinTempDevC: r.double(in: -1.0...1.0),
                respRateBpm: 14.0 + r.double(in: 0...4)))

            let sleepEnd = cal.date(bySettingHour: 7, minute: 0, second: 0, of: day) ?? day
            let sleepStart = cal.date(byAdding: .minute, value: -Int(totalSleepMin), to: sleepEnd) ?? day
            sleeps.append(CachedSleepSession(
                startTs: Int(sleepStart.timeIntervalSince1970),
                endTs: Int(sleepEnd.timeIntervalSince1970),
                efficiency: efficiency, restingHr: rhr, avgHrv: hrv,
                stagesJSON: nil))

            for q in ["Hydrated?", "Caffeine after noon?"] {
                journal.append(JournalEntry(day: dayStr, question: q,
                                            answeredYes: r.bool(),
                                            notes: nil))
            }

            apple.append(AppleDaily(day: dayStr,
                steps: 4000 + r.int(in: 0...8000),
                activeKcal: 200.0 + r.double(in: 0...600),
                basalKcal: 1500.0 + r.double(in: 0...400),
                vo2max: 38.0 + r.double(in: 0...10),
                avgHr: 70 + r.int(in: 0...10),
                maxHr: 130 + r.int(in: 0...30),
                walkingHr: 80 + r.int(in: 0...20),
                weightKg: 75.0 + r.double(in: -2.0...2.0)))

            // Two workouts per week.
            if back % 4 == 0 {
                let startHour = 17 + r.int(in: 0...2)
                let start = cal.date(bySettingHour: startHour, minute: 0, second: 0, of: day) ?? day
                let dur = 30 + r.int(in: 0...60)
                let end = cal.date(byAdding: .minute, value: dur, to: start) ?? start
                let sports = ["Running", "Cycling", "Strength", "Yoga"]
                workouts.append(WorkoutRow(
                    startTs: Int(start.timeIntervalSince1970),
                    endTs: Int(end.timeIntervalSince1970),
                    sport: sports[r.int(in: 0..<sports.count)],
                    source: "mock",
                    durationS: Double(dur * 60),
                    energyKcal: 250.0 + r.double(in: 0...400),
                    avgHr: 130 + r.int(in: 0...20),
                    maxHr: 160 + r.int(in: 0...30),
                    strain: 10.0 + r.double(in: 0...8),
                    distanceM: 3000.0 + r.double(in: 0...8000),
                    zonesJSON: nil, notes: nil))
            }
        }

        _ = try? await store.upsertDailyMetrics(days, deviceId: settings.deviceId)
        _ = try? await store.upsertSleepSessions(sleeps, deviceId: settings.deviceId)
        _ = try? await store.upsertJournal(journal, deviceId: settings.deviceId)
        _ = try? await store.upsertWorkouts(workouts, deviceId: settings.deviceId)
        _ = try? await store.upsertAppleDaily(apple, deviceId: settings.deviceId)
    }

    /// Append synthetic rows for today only. Used by the "Add 1 day" button in Settings to
    /// live-watch propagation to the other Mac.
    public static func addOneDay(into store: WhoopStore, deviceId: String) async {
        await seed(into: store, settings: Settings(deviceId: deviceId, nDays: 1))
    }

    /// Default deviceId for the seeder, derived from the machine name so desktop and laptop pick
    /// different IDs by default.
    public static func defaultDeviceId() -> String {
        let host = Host.current().localizedName ?? ""
        // Stable, sortable, and a different machine produces a different id.
        let suffix = host.unicodeScalars.reduce(into: 0 as UInt32) { $0 = $0 &* 31 &+ $1.value }
        return "mock-\(String(suffix, radix: 16))"
    }
}

// MARK: - Deterministic seeded PRNG keyed by (deviceId, day)

/// SplitMix64 keyed by a stable hash of (deviceId, day). Two seed runs on the same machine
/// produce identical rows; two machines with different mock deviceIds produce different rows.
private struct seededRand {
    private var state: UInt64

    init(deviceId: String, day: String) {
        var h: UInt64 = 1469598103934665603    // FNV offset basis
        for c in (deviceId + "|" + day).utf8 {
            h ^= UInt64(c)
            h = h &* 1099511628211             // FNV prime
        }
        self.state = h
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        let u = Double(next() >> 11) / Double(1 << 53)    // [0, 1)
        return range.lowerBound + u * (range.upperBound - range.lowerBound)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    mutating func int(in range: Range<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound)
        return range.lowerBound + Int(next() % span)
    }

    mutating func bool() -> Bool { (next() & 1) == 1 }
}
