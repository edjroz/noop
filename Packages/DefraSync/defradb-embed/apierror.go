package defradbembed

// APIErrorCallback is the gomobile-bindable shape we'd surface to Swift to be
// notified if the in-process HTTP server dies unexpectedly. v1.0.0-rc1 doesn't
// expose the channel for that — node.startAPI's goroutine just logs on error
// instead of signalling — so the registration is a no-op for now.
//
// Phase 3 (Strand integration) can poll `HealthCheck` from Swift as a workaround,
// or we revisit this once defradb merges the APIError surface that's been
// discussed in issue #4735.
type APIErrorCallback interface {
	OnError(msg string)
}

// RegisterAPIErrorCallback is currently a no-op — see APIErrorCallback for why.
// Kept as a public surface so Phase 3 callers don't have to be reshaped when we
// wire the underlying channel in a later defradb version.
func RegisterAPIErrorCallback(cb APIErrorCallback) {
	_ = cb
}

// startAPIErrorDrain is invoked from StartNode under the package mutex. No-op
// today (see APIErrorCallback). Defined so the StartNode body doesn't need a
// build-tag dance when we add it back.
func startAPIErrorDrain(_ any) {}

// stopAPIErrorDrain is invoked from StopNode under the package mutex. No-op.
func stopAPIErrorDrain() {}
