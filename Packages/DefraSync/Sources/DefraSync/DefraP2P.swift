import Foundation

/// P2P operations against the embedded DefraDB.
///
/// Phase 3 replaced the per-call `defradb client p2p …` subprocess shells with direct
/// `DefraEmbedRuntime` calls into the in-process Go runtime. Idempotence (treating "already
/// exists" / "already connected" as success) is handled on the Go side, so the Swift surface
/// here is a one-call wrapper per operation.
///
/// The functions stayed `static` and kept their signatures down to `names:` / `multiaddr:` so
/// `SyncController` continues to read the same way — the `binaryURL` / `httpPort` parameters
/// went away because the runtime singleton owns both.
public enum DefraP2P {

    /// Subscribe this node to the pubsub topic for each named collection.
    public static func subscribeCollections(names: [String]) throws {
        guard !names.isEmpty else { return }
        try DefraEmbedRuntime.p2pSubscribe(names)
    }

    /// Dial a peer over libp2p. Pubsub-only — does NOT backfill existing data; use `replicate`
    /// to forward-push the local state across.
    public static func connect(multiaddr: String) throws {
        try DefraEmbedRuntime.p2pConnect(multiaddr)
    }

    /// Register a forward-push replicator for the given peer. This is how DefraDB v1.0.0-rc1
    /// actually synchronizes existing collection state across nodes — pubsub only carries
    /// future writes, while `replicator add` makes the local node push every doc it holds (and
    /// every subsequent write) to the peer. For symmetric two-Mac sync, BOTH Macs call this
    /// with the OTHER's multiaddr; the dial is initiated by whichever side runs the call.
    public static func replicate(collectionNames: [String], multiaddr: String) throws {
        guard !collectionNames.isEmpty else { return }
        try DefraEmbedRuntime.p2pReplicateTo(multiaddr, collectionNames: collectionNames)
    }
}
