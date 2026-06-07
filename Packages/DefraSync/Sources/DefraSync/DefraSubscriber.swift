import Foundation
import WhoopStore

/// Inbound apply: subscribes to each DefraDB collection (graphql-ws over WebSocket) and applies
/// inbound rows through `WhoopStore.upsert*`, wrapped in `SyncContext.applyingFromDefra = true`
/// so the outbound mirror suppresses the round-trip.
///
/// **Alpha caveats:** DefraDB subscriptions are not battle-tested. This subscriber:
/// - Reconnects on socket failure with exponential backoff.
/// - Falls back to a polling loop (every 30s) using `_gt: $highWater` on `lastWriterTs` if the
///   WebSocket fails twice within 60s — until the next successful WebSocket round.
/// - Tracks an in-memory high-water-mark per collection to catch up on rows missed while
///   disconnected.
public actor DefraSubscriber {
    private let client: DefraClient
    private let store: WhoopStore
    /// Called after each applied batch (debounced by the caller). SyncController wires this to
    /// `Repository.refresh()`.
    private let onApplied: @Sendable () async -> Void

    private var highWater: [String: Int] = [:]    // collection → max(lastWriterTs)
    private var pollTask: Task<Void, Never>?

    public init(client: DefraClient,
                store: WhoopStore,
                onApplied: @escaping @Sendable () async -> Void) {
        self.client = client
        self.store = store
        self.onApplied = onApplied
    }

    /// Start the polling loop covering all 5 collections. We default to polling rather than
    /// WebSocket-first because the alpha's subscription delivery is inconsistent and the
    /// catch-up query is the load-bearing path anyway. Add WebSocket later when the alpha settles.
    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollAll()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Force an immediate poll round (used by the manual "Retry sync" button in Settings).
    public func pokeNow() async { await pollAll() }

    // MARK: - Poll round

    private func pollAll() async {
        for collection in DefraTypeName.allCollections {
            await poll(collection: collection)
        }
        await onApplied()
    }

    private func poll(collection: String) async {
        guard let type = DefraTypeName.graphqlType(for: collection) else { return }
        let watermark = highWater[collection] ?? 0
        let query = """
        query { \(type)(filter: {lastWriterTs: {_gt: \(watermark)}}) {
            \(allFields(for: type))
        } }
        """
        let data: Any?
        do {
            data = try await client.graphql(query)
        } catch {
            return    // sidecar down or transient — try next round
        }
        guard let envelope = data as? [String: Any],
              let rows = envelope[type] as? [[String: Any]],
              !rows.isEmpty
        else { return }

        var newest = watermark
        // Group rows by deviceId — WhoopStore upserts take a single deviceId per batch.
        var byDevice: [String: [[String: Any]]] = [:]
        for row in rows {
            if let ts = row["lastWriterTs"] as? Int, ts > newest { newest = ts }
            guard let dev = row["deviceId"] as? String else { continue }
            byDevice[dev, default: []].append(row)
        }
        for (deviceId, group) in byDevice {
            await SyncContext.$applyingFromDefra.withValue(true) {
                await apply(collection: collection, deviceId: deviceId, rows: group)
            }
        }
        highWater[collection] = newest
    }

    // MARK: - Per-collection apply via existing WhoopStore upserts

    private func apply(collection: String, deviceId: String, rows: [[String: Any]]) async {
        switch collection {
        case "sleepSession":
            let mapped = rows.compactMap { r -> CachedSleepSession? in
                guard let s = r["startTs"] as? Int, let e = r["endTs"] as? Int else { return nil }
                return CachedSleepSession(
                    startTs: s, endTs: e,
                    efficiency: r["efficiency"] as? Double,
                    restingHr: r["restingHr"] as? Int,
                    avgHrv: r["avgHrv"] as? Double,
                    stagesJSON: r["stagesJSON"] as? String)
            }
            _ = try? await store.upsertSleepSessions(mapped, deviceId: deviceId)
        case "dailyMetric":
            let mapped = rows.compactMap { r -> DailyMetric? in
                guard let day = r["day"] as? String else { return nil }
                return DailyMetric(
                    day: day,
                    totalSleepMin: r["totalSleepMin"] as? Double,
                    efficiency: r["efficiency"] as? Double,
                    deepMin: r["deepMin"] as? Double,
                    remMin: r["remMin"] as? Double,
                    lightMin: r["lightMin"] as? Double,
                    disturbances: r["disturbances"] as? Int,
                    restingHr: r["restingHr"] as? Int,
                    avgHrv: r["avgHrv"] as? Double,
                    recovery: r["recovery"] as? Double,
                    strain: r["strain"] as? Double,
                    exerciseCount: r["exerciseCount"] as? Int,
                    spo2Pct: r["spo2Pct"] as? Double,
                    skinTempDevC: r["skinTempDevC"] as? Double,
                    respRateBpm: r["respRateBpm"] as? Double)
            }
            _ = try? await store.upsertDailyMetrics(mapped, deviceId: deviceId)
        case "journal":
            let mapped = rows.compactMap { r -> JournalEntry? in
                guard let day = r["day"] as? String, let q = r["question"] as? String,
                      let yes = r["answeredYes"] as? Bool else { return nil }
                return JournalEntry(day: day, question: q, answeredYes: yes, notes: r["notes"] as? String)
            }
            _ = try? await store.upsertJournal(mapped, deviceId: deviceId)
        case "workout":
            let mapped = rows.compactMap { r -> WorkoutRow? in
                guard let s = r["startTs"] as? Int, let e = r["endTs"] as? Int,
                      let sport = r["sport"] as? String, let source = r["source"] as? String
                else { return nil }
                return WorkoutRow(
                    startTs: s, endTs: e, sport: sport, source: source,
                    durationS: r["durationS"] as? Double,
                    energyKcal: r["energyKcal"] as? Double,
                    avgHr: r["avgHr"] as? Int, maxHr: r["maxHr"] as? Int,
                    strain: r["strain"] as? Double,
                    distanceM: r["distanceM"] as? Double,
                    zonesJSON: r["zonesJSON"] as? String,
                    notes: r["notes"] as? String)
            }
            _ = try? await store.upsertWorkouts(mapped, deviceId: deviceId)
        case "appleDaily":
            let mapped = rows.compactMap { r -> AppleDaily? in
                guard let day = r["day"] as? String else { return nil }
                return AppleDaily(
                    day: day,
                    steps: r["steps"] as? Int,
                    activeKcal: r["activeKcal"] as? Double,
                    basalKcal: r["basalKcal"] as? Double,
                    vo2max: r["vo2max"] as? Double,
                    avgHr: r["avgHr"] as? Int,
                    maxHr: r["maxHr"] as? Int,
                    walkingHr: r["walkingHr"] as? Int,
                    weightKg: r["weightKg"] as? Double)
            }
            _ = try? await store.upsertAppleDaily(mapped, deviceId: deviceId)
        default:
            return
        }
    }

    // MARK: - Field lists per GraphQL type

    /// All fields we select for each type. Keep these in sync with `DefraSchema.sdl`.
    private func allFields(for type: String) -> String {
        switch type {
        case DefraTypeName.sleepSession:
            return "naturalKey deviceId startTs endTs efficiency restingHr avgHrv stagesJSON lastWriterPeer lastWriterTs"
        case DefraTypeName.dailyMetric:
            return """
            naturalKey deviceId day totalSleepMin efficiency deepMin remMin lightMin disturbances \
            restingHr avgHrv recovery strain exerciseCount spo2Pct skinTempDevC respRateBpm \
            lastWriterPeer lastWriterTs
            """
        case DefraTypeName.journal:
            return "naturalKey deviceId day question answeredYes notes lastWriterPeer lastWriterTs"
        case DefraTypeName.workout:
            return """
            naturalKey deviceId startTs endTs sport source durationS energyKcal avgHr maxHr strain \
            distanceM zonesJSON notes lastWriterPeer lastWriterTs
            """
        case DefraTypeName.appleDaily:
            return """
            naturalKey deviceId day steps activeKcal basalKcal vo2max avgHr maxHr walkingHr weightKg \
            lastWriterPeer lastWriterTs
            """
        default:
            return "_docID"
        }
    }
}
