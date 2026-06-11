// cshared exposes the Phase 1 defradbembed API through a C ABI so we can
// build it as a `-buildmode=c-shared` dylib that Swift can link via the
// generated header. Required because `-buildmode=c-shared` mandates
// `package main`; the actual Go-native logic stays in the parent package
// (`Packages/DefraSync/defradb-embed/`) so the Phase 1 tests under
// embed_test.go keep working without cgo gymnastics.
//
// Convention used by every wrapper:
//   - Errors: returns *C.char — nil on success, a C-allocated error message on
//     failure. Swift must free the message via DefraFreeString.
//   - Strings: returns *C.char (C.CString); Swift must free.
//   - []string: returned as a JSON-encoded *C.char (single allocation); Swift
//     decodes via JSONDecoder. Simpler than exposing a C array shape.
//
// Names are prefixed `Defra…` to avoid C symbol collisions with anything else
// statically linked into the host process. The Swift wrapper in Phase 3 will
// re-expose these as Swift-friendly types behind a thin Sendable façade.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"unsafe"

	defradbembed "github.com/edjroz/noop/Packages/DefraSync/defradb-embed"
)

//export DefraStartNode
func DefraStartNode(rootdir, httpListen, p2pListen *C.char, devMode C.int) *C.char {
	err := defradbembed.StartNode(
		C.GoString(rootdir),
		C.GoString(httpListen),
		C.GoString(p2pListen),
		devMode != 0,
	)
	return cErrorOrNil(err)
}

//export DefraStopNode
func DefraStopNode() *C.char {
	return cErrorOrNil(defradbembed.StopNode())
}

//export DefraAPIBaseURL
func DefraAPIBaseURL() *C.char {
	// Caller must free via DefraFreeString. Returns nil when no node is running.
	url := defradbembed.APIBaseURL()
	if url == "" {
		return nil
	}
	return C.CString(url)
}

//export DefraLoadCollections
func DefraLoadCollections(sdl *C.char) *C.char {
	return cErrorOrNil(defradbembed.LoadCollections(C.GoString(sdl)))
}

//export DefraP2PSubscribe
func DefraP2PSubscribe(collectionNamesJSON *C.char) *C.char {
	var names []string
	if err := json.Unmarshal([]byte(C.GoString(collectionNamesJSON)), &names); err != nil {
		return C.CString("DefraP2PSubscribe: invalid JSON: " + err.Error())
	}
	return cErrorOrNil(defradbembed.P2PSubscribe(names))
}

//export DefraP2PConnect
func DefraP2PConnect(multiaddr *C.char) *C.char {
	return cErrorOrNil(defradbembed.P2PConnect(C.GoString(multiaddr)))
}

//export DefraP2PReplicateTo
func DefraP2PReplicateTo(multiaddr, collectionNamesJSON *C.char) *C.char {
	var names []string
	if err := json.Unmarshal([]byte(C.GoString(collectionNamesJSON)), &names); err != nil {
		return C.CString("DefraP2PReplicateTo: invalid JSON: " + err.Error())
	}
	return cErrorOrNil(defradbembed.P2PReplicateTo(C.GoString(multiaddr), names))
}

// DefraSelfMultiaddrsJSON returns a JSON-encoded array of multiaddrs in *result
// (nil on error), and on error fills *errOut with a C-allocated string. Caller
// frees both pointers via DefraFreeString.
//
//export DefraSelfMultiaddrsJSON
func DefraSelfMultiaddrsJSON(result **C.char, errOut **C.char) {
	*result = nil
	*errOut = nil
	addrs, err := defradbembed.SelfMultiaddrs()
	if err != nil {
		*errOut = C.CString(err.Error())
		return
	}
	*result = jsonString(addrs)
}

//export DefraActivePeersJSON
func DefraActivePeersJSON(result **C.char, errOut **C.char) {
	*result = nil
	*errOut = nil
	peers, err := defradbembed.ActivePeers()
	if err != nil {
		*errOut = C.CString(err.Error())
		return
	}
	*result = jsonString(peers)
}

// DefraFreeString releases a C string returned by any function above. Failing
// to call this leaks memory inside the host process — Swift wrappers must call
// it from a `defer` immediately after consuming the returned value.
//
//export DefraFreeString
func DefraFreeString(s *C.char) {
	if s != nil {
		C.free(unsafe.Pointer(s))
	}
}

func cErrorOrNil(err error) *C.char {
	if err == nil {
		return nil
	}
	return C.CString(err.Error())
}

func jsonString(v any) *C.char {
	b, err := json.Marshal(v)
	if err != nil {
		// Fall back to a JSON-shaped empty array so Swift never sees a corrupt blob.
		return C.CString("[]")
	}
	return C.CString(string(b))
}

// main() is required for buildmode=c-shared but is never called. Keep empty.
func main() {}
