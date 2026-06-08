import Foundation

/// CLI-wrapped P2P operations. We go through `defradb client p2p …` rather than the HTTP
/// endpoints because (a) the rc1 HTTP body shapes for these calls are not yet stable and (b)
/// we already have a `DefraCLI` helper for the same pattern (`DefraSchema.bootstrap`).
///
/// All ops are idempotent — `p2p collection add` for a collection that's already subscribed
/// no-ops, `p2p connect` to an already-connected peer no-ops. We treat "already" stderr
/// phrases as success.
public enum DefraP2P {

    /// Subscribe this node to the pubsub topic for each named collection. After this returns,
    /// any write to one of these collections — on this node or any peer connected at the
    /// libp2p layer — fans out via gossip and lands on every subscribed node.
    public static func subscribeCollections(binaryURL: URL,
                                            httpPort: Int = 9181,
                                            names: [String]) async throws {
        guard !names.isEmpty else { return }
        // CLI accepts comma-separated names as a single arg.
        let joined = names.joined(separator: ",")
        do {
            _ = try await DefraCLI.run(
                binaryURL: binaryURL,
                args: ["client", "p2p", "collection", "add", "--url", "127.0.0.1:\(httpPort)", joined]
            )
        } catch let error where DefraCLI.isTolerable(error, anyOf: ["already", "exists"]) {
            return
        }
    }

    /// Dial a peer over libp2p so pubsub messages can flow in both directions. The peer
    /// must already be advertising its multiaddr; both sides must be subscribed to the same
    /// collection topics (see `subscribeCollections`).
    public static func connect(binaryURL: URL,
                               httpPort: Int = 9181,
                               multiaddr: String) async throws {
        do {
            _ = try await DefraCLI.run(
                binaryURL: binaryURL,
                args: ["client", "p2p", "connect", "--url", "127.0.0.1:\(httpPort)", multiaddr]
            )
        } catch let error where DefraCLI.isTolerable(error, anyOf: ["already connected"]) {
            return
        }
    }
}
