package defradbembed

import (
	"fmt"

	"github.com/sourcenetwork/defradb/client/options"
)

// P2PSubscribe is the in-process equivalent of
// `defradb client p2p collection add <Names...>` (CLI body in
// cli/p2p_collection_add.go::MakeP2PCollectionAddCommand). Subscribes this node
// to the pubsub topic for each named collection so live writes on a peer fan
// out to us.
func P2PSubscribe(collectionNames []string) error {
	if len(collectionNames) == 0 {
		return nil
	}
	client, ctx, err := snapshot()
	if err != nil {
		return err
	}
	if err := client.AddP2PCollections(ctx, collectionNames); err != nil {
		if isAlreadyExists(err) {
			return nil
		}
		return fmt.Errorf("defradbembed: AddP2PCollections: %w", err)
	}
	return nil
}

// P2PConnect is the in-process equivalent of `defradb client p2p connect <addr>`
// (CLI body in cli/p2p_connect.go::MakeP2PConnectCommand). Establishes the
// libp2p connection; pubsub messages can flow once both sides are subscribed.
func P2PConnect(multiaddr string) error {
	client, ctx, err := snapshot()
	if err != nil {
		return err
	}
	if err := client.Connect(ctx, []string{multiaddr}); err != nil {
		if isAlreadyExists(err) {
			return nil
		}
		return fmt.Errorf("defradbembed: Connect: %w", err)
	}
	return nil
}

// P2PReplicateTo is the in-process equivalent of
// `defradb client p2p replicator add -c <Name>... <multiaddr>` (CLI body in
// cli/p2p_replicator_add.go::MakeP2PReplicatorAddCommand). Registers a
// forward-push replicator — proven empirically in the macOS smoke run to be
// what actually backfills existing rows; pubsub alone only carries live writes.
func P2PReplicateTo(multiaddr string, collectionNames []string) error {
	if multiaddr == "" {
		return fmt.Errorf("defradbembed: P2PReplicateTo: empty multiaddr")
	}
	client, ctx, err := snapshot()
	if err != nil {
		return err
	}
	opt := options.AddReplicator().SetCollectionNames(collectionNames)
	if err := client.AddReplicator(ctx, []string{multiaddr}, opt); err != nil {
		if isAlreadyExists(err) {
			return nil
		}
		return fmt.Errorf("defradbembed: AddReplicator: %w", err)
	}
	return nil
}

// SelfMultiaddrs is the in-process equivalent of GET /api/v0/p2p/info — useful
// for the Phase 3 Swift layer to surface "this Mac's multiaddr" in the Sync
// settings panel without having to round-trip through HTTP.
func SelfMultiaddrs() ([]string, error) {
	client, ctx, err := snapshot()
	if err != nil {
		return nil, err
	}
	return client.PeerInfo(ctx)
}

// ActivePeers is the in-process equivalent of GET /api/v0/p2p/active-peers.
func ActivePeers() ([]string, error) {
	client, ctx, err := snapshot()
	if err != nil {
		return nil, err
	}
	return client.ActivePeers(ctx)
}
