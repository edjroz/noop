import Foundation

/// Cross-cutting state for the sync mirror. The `applyingFromDefra` @TaskLocal is set to `true`
/// while the inbound subscriber is calling `WhoopStore.upsert*` so the outbound mirror's
/// `WhoopStoreObserver.didUpsert` callback can detect "this write originated from the network"
/// and skip re-publishing it back to DefraDB. The flag propagates across `async` boundaries with
/// the task it's bound to, so the call chain
///     subscriber → store.upsert* → notifyObserver → Task.detached → syncer.didUpsert
/// preserves it as long as the syncer reads the value *before* the detached task starts a new
/// task tree. `DefraSyncer.didUpsert` is responsible for the read.
public enum SyncContext {
    @TaskLocal public static var applyingFromDefra: Bool = false
}
