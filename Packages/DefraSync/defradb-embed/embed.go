// Package defradbembed runs a DefraDB node in-process inside the Strand app
// instead of spawning the `defradb` CLI as a child Process.
//
// Why in-process: iOS forbids fork()/exec() so a child-process sidecar can never
// run there; even on macOS the cross-process boundary costs orphan-process risk
// plus a 165 MB vendored binary. DefraDB's node package is built for embedding
// (Shinzo's shinzo-app-sdk and nasdf/defradb-mongodb-cdc both rely on it) and
// the maintainers wired APIError() for exactly the "embedded host wants to know
// when the HTTP server dies" case (issue #4735).
//
// API surface is gomobile-bindable — primitives only, no interface{} crossing
// the FFI boundary, no generics in the exported signatures (we assemble the
// options.Enumerable builder internally). Phase 2 wraps this package as an
// xcframework; Phase 3 swaps Strand's DefraSidecar.start() / DefraCLI.run()
// callers over.
//
// One process-global *node.Node behind a mutex. Multi-instance is out of scope.
package defradbembed

import (
	"context"
	"fmt"
	"sync"
	"time"

	defraerrors "github.com/sourcenetwork/defradb/errors"
	defrahttp "github.com/sourcenetwork/defradb/http"

	"github.com/sourcenetwork/defradb/client/options"
	"github.com/sourcenetwork/defradb/node"
)

var (
	mu       sync.Mutex
	current  *node.Node
	cancel   context.CancelFunc
	apiURL   string
	httpAPI  *defrahttp.Client
)

// StartNode brings up an in-process DefraDB at rootdir, listening on httpListen
// for the HTTP/GraphQL API and on p2pListen for libp2p. devMode mirrors the
// --development flag we currently pass to the sidecar; it allows PurgeAndRestart
// and auto-generates an ephemeral node identity instead of requiring a keyring.
//
// Returns when the HTTP server is accepting connections. Calling twice without
// StopNode in between returns an error.
//
// Matches the option assembly in cli/start.go::MakeStartCommand.RunE, minus
// the cobra/viper plumbing and the keyring path (we mirror --no-keyring + dev
// mode for parity with the current sidecar invocation).
func StartNode(rootdir, httpListen, p2pListen string, devMode bool) error {
	mu.Lock()
	defer mu.Unlock()
	if current != nil {
		return fmt.Errorf("defradbembed: already running (call StopNode first)")
	}

	opts := options.Node().
		SetEnableDevelopment(devMode).
		SetDisableP2P(false)
	opts.Store().
		SetPath(rootdir).
		SetBadgerInMemory(false)
	opts.P2P().
		SetListenAddresses(p2pListen).
		SetEnablePubSub(true)
	opts.HTTP().
		SetAddress(httpListen)

	ctx, cancelCtx := context.WithCancel(context.Background())
	n, err := node.New(ctx, opts)
	if err != nil {
		cancelCtx()
		return fmt.Errorf("defradbembed: node.New: %w", err)
	}
	if err := n.Start(ctx); err != nil {
		cancelCtx()
		return fmt.Errorf("defradbembed: node.Start: %w", err)
	}

	// node.Start internally calls HealthCheck before returning (see node/node_api.go
	// startAPI), so by the time we reach here the listener is bound and the API
	// is accepting connections — no polling loop needed.
	url := n.APIURL
	client, err := defrahttp.NewClient(url)
	if err != nil {
		_ = n.Close(ctx)
		cancelCtx()
		return fmt.Errorf("defradbembed: http.NewClient(%q): %w", url, err)
	}

	current = n
	cancel = cancelCtx
	apiURL = url
	httpAPI = client

	// APIError() fires once if the in-process HTTP server dies. We start a
	// drain goroutine; the callback registered via RegisterAPIErrorCallback
	// (if any) gets the message. See apierror.go.
	startAPIErrorDrain(n)

	return nil
}

// StopNode tears down the in-process node. No-op if nothing is running.
func StopNode() error {
	mu.Lock()
	defer mu.Unlock()
	if current == nil {
		return nil
	}
	ctx, cancelCtx := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelCtx()
	err := current.Close(ctx)
	if cancel != nil {
		cancel()
	}
	current = nil
	cancel = nil
	apiURL = ""
	httpAPI = nil
	stopAPIErrorDrain()
	return err
}

// APIBaseURL returns the HTTP base URL of the running node, e.g.
// "http://127.0.0.1:9181". Useful for tests + the Phase 2 Swift layer.
// Returns empty string if no node is running.
func APIBaseURL() string {
	mu.Lock()
	defer mu.Unlock()
	return apiURL
}

// LoadCollections is the function-callable equivalent of
// `defradb client collection add <sdl>` — body lifted from cli/collection_add.go.
// Returns nil on success or when the schema already exists (idempotent — matches
// the "already exists" tolerance we built into DefraCLI.run for the sidecar path).
func LoadCollections(sdl string) error {
	client, ctx, err := snapshot()
	if err != nil {
		return err
	}
	_, err = client.AddCollection(ctx, sdl)
	if err != nil && isAlreadyExists(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("defradbembed: AddCollection: %w", err)
	}
	return nil
}

func snapshot() (*defrahttp.Client, context.Context, error) {
	mu.Lock()
	defer mu.Unlock()
	if current == nil || httpAPI == nil {
		return nil, nil, fmt.Errorf("defradbembed: not running (call StartNode first)")
	}
	return httpAPI, context.Background(), nil
}

// isAlreadyExists matches the stderr-based tolerance the Swift DefraCLI.isTolerable
// helper applies. DefraDB returns a structured error on schema duplication; we
// fall back to substring matching since the alpha's error wording is moving.
func isAlreadyExists(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	for _, phrase := range []string{"already exists", "already added", "schema is already"} {
		if containsCI(msg, phrase) {
			return true
		}
	}
	// DefraDB-typed errors sometimes surface via errors.Is — try that too.
	return defraerrors.Is(err, defraerrors.New("already exists"))
}

func containsCI(haystack, needle string) bool {
	hl := []byte(haystack)
	nl := []byte(needle)
	if len(nl) == 0 {
		return true
	}
	if len(hl) < len(nl) {
		return false
	}
	// ASCII-only lowercase compare — adequate for the English error phrases above.
	lower := func(b byte) byte {
		if b >= 'A' && b <= 'Z' {
			return b + 32
		}
		return b
	}
	for i := 0; i <= len(hl)-len(nl); i++ {
		match := true
		for j := 0; j < len(nl); j++ {
			if lower(hl[i+j]) != lower(nl[j]) {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}
