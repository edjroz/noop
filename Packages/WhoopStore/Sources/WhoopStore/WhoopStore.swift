import Foundation
import GRDB
import WhoopProtocol

/// OpenWhoop persistence library — decoded streams are durable; raw frames are a
/// transient, compressed, prunable outbox. Built on GRDB/SQLite.
public enum WhoopStoreInfo {
    /// Bumped whenever the migrator gains a new migration. Upstream is at 11 (v10 stepSample +
    /// v11 daily-steps/calorie cols). The DefraSync fork adds v12 (defra_outbox).
    public static let schemaVersion = 12
}

/// Observer hook invoked after a successful upsert into one of the synced metric-cache tables.
/// Fires from a child Task so a slow/failing observer cannot backpressure the writer.
/// The mirror layer (DefraSync) implements this to publish rows out to the in-process DefraDB.
///
/// **Loop prevention for inbound-apply paths**: the upsert methods take a `skipObserver: Bool`
/// flag (default `false`). The DefraDB inbound apply (`DefraSubscriber.apply`) passes
/// `skipObserver: true` so rows that came in over the network do NOT re-fire this observer
/// and bounce back out. The previous mechanism — a `@TaskLocal` flag checked inside the
/// observer — proved unreliable across actor boundaries + `Task { }` initializers.
///
/// Payload shape: one JSON object string per row, containing the natural-key columns plus every
/// column the upsert wrote. Using JSON strings rather than `[String: Any]` keeps the protocol
/// Sendable-clean.
public protocol WhoopStoreObserver: Sendable {
    func didUpsert(collection: String, deviceId: String, payloadsJSON: [String]) async
}

/// WhoopStore is an `actor`: its public API is `async`, and all GRDB work runs on the
/// actor's serial executor rather than the caller's (the main actor). DatabaseQueue calls
/// are synchronous-blocking; the actor moves them off the main thread (it does not make them
/// non-blocking). That is the intended off-main win — DatabaseQueue kept, not DatabasePool.
public actor WhoopStore {
    let dbQueue: DatabaseQueue
    private var observer: WhoopStoreObserver?

    /// Wire an observer that gets called after each successful upsert into a synced collection.
    /// Inbound-apply suppression is opt-in per-call via the `skipObserver: Bool` parameter on
    /// each `upsert*` method, not a property of the observer itself.
    public func setObserver(_ obs: WhoopStoreObserver?) { self.observer = obs }

    /// Fire the observer (no-op if unset). Called from the upsert sites after `syncWrite` returns,
    /// gated by each call's `skipObserver` flag. The observer dispatch goes through a child
    /// `Task { ... }` so its work runs on its own executor — the writer's await returns
    /// immediately and isn't blocked by a slow observer.
    func notifyObserver(collection: String, deviceId: String, payloadsJSON: [String]) {
        guard !payloadsJSON.isEmpty, let obs = observer else { return }
        Task { await obs.didUpsert(collection: collection, deviceId: deviceId, payloadsJSON: payloadsJSON) }
    }

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try WhoopStore.makeMigrator().migrate(dbQueue)
    }

    /// Open (creating if needed) a database at `path` and run migrations.
    /// Enables WAL journal mode and a 5-second busy timeout so two handles to the same
    /// file (BLEManager + MetricsRepository) don't deadlock on write contention.
    public init(path: String) async throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            // Bulk-write/read tuning. NORMAL is the durable, recommended pairing with WAL (only an
            // OS crash/power loss can lose the last transaction — acceptable here). Bigger page cache
            // + mmap + in-memory temp tables speed the multi-thousand-row import/backfill writes.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA cache_size = -16000")     // ~16 MB page cache
            try db.execute(sql: "PRAGMA mmap_size = 268435456")   // 256 MB memory-mapped I/O
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
        }
        config.busyMode = .timeout(5)
        try self.init(dbQueue: try DatabaseQueue(path: path, configuration: config))
    }

    /// An in-memory store (migrations applied). For tests.
    public static func inMemory() async throws -> WhoopStore {
        try WhoopStore(dbQueue: try DatabaseQueue())
    }

    // MARK: - Synchronous GRDB helpers
    // GRDB 6 marks its sync read/write overloads @_disfavoredOverload so that in an async
    // context Swift would otherwise pick the async overloads. These thin wrappers are
    // regular (non-async) functions, so overload resolution always selects the synchronous
    // GRDB API — which then blocks on the actor's serial executor (off main thread).

    @inline(__always)
    func syncRead<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }

    @inline(__always)
    func syncWrite<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }

    // MARK: - Maintenance

    /// Fully checkpoint the WAL into the main database file and truncate the -wal file.
    /// Used before a file-level backup so the single `whoop.sqlite` carries all committed data
    /// (the -wal/-shm siblings can then be ignored). Runs outside a transaction — `wal_checkpoint`
    /// must. Best-effort: throws on a hard SQLite error so callers can fall back to a plain copy.
    public func checkpointWAL() async throws {
        try checkpointWALImpl()
    }

    /// Non-async so GRDB's synchronous `writeWithoutTransaction` overload is chosen (mirrors the
    /// syncRead/syncWrite pattern). Runs on the actor's executor, off the main thread.
    private func checkpointWALImpl() throws {
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    // MARK: - Introspection (used by tests)

    public func tableNames() async throws -> Set<String> {
        try syncRead { db in
            try Set(String.fetchAll(db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
    }

    public func primaryKeyColumns(_ table: String) async throws -> [String] {
        try syncRead { db in
            try db.primaryKey(table).columns
        }
    }

    public func columnNamesForTest(table: String) async throws -> [String] {
        try syncRead { db in
            try db.columns(in: table).map(\.name)
        }
    }

    public func indexNamesForTest(table: String) async throws -> Set<String> {
        try syncRead { db in
            try Set(db.indexes(on: table).map(\.name))
        }
    }
}
