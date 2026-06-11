// probe brings up the in-process DefraDB wrapper and parks on SIGINT, so the
// `./Tools/sync-status.sh` script and ad-hoc `curl` commands can hit a wrapper-
// served HTTP API exactly the way they hit the current sidecar.
//
// Usage:
//
//	go run ./cmd/probe
//
// Defaults to the same ports our sidecar uses (HTTP 9181, libp2p 9171) so the
// existing scripts work unchanged. Override via flags.
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	defradbembed "github.com/edjroz/noop/Packages/DefraSync/defradb-embed"
)

func main() {
	rootdir := flag.String("rootdir", "", "data dir (default: temp dir, deleted on exit)")
	httpListen := flag.String("http", "127.0.0.1:9181", "HTTP API listen address")
	p2pListen := flag.String("p2p", "/ip4/0.0.0.0/tcp/9171", "libp2p listen multiaddr")
	loadSDL := flag.String("load-sdl", "", "file path to load as SDL after StartNode (optional)")
	flag.Parse()

	rd := *rootdir
	if rd == "" {
		tmp, err := os.MkdirTemp("", "defra-embed-probe-")
		if err != nil {
			log.Fatalf("temp dir: %v", err)
		}
		rd = tmp
		defer os.RemoveAll(tmp)
	}

	log.Printf("StartNode rootdir=%s http=%s p2p=%s", rd, *httpListen, *p2pListen)
	if err := defradbembed.StartNode(rd, *httpListen, *p2pListen, true); err != nil {
		log.Fatalf("StartNode: %v", err)
	}
	log.Printf("API at %s", defradbembed.APIBaseURL())

	if *loadSDL != "" {
		data, err := os.ReadFile(*loadSDL)
		if err != nil {
			log.Printf("read SDL: %v", err)
		} else if err := defradbembed.LoadCollections(string(data)); err != nil {
			log.Printf("LoadCollections: %v", err)
		} else {
			log.Printf("loaded SDL from %s", *loadSDL)
		}
	}

	addrs, err := defradbembed.SelfMultiaddrs()
	if err != nil {
		log.Printf("SelfMultiaddrs: %v", err)
	} else {
		for _, a := range addrs {
			log.Printf("multiaddr: %s", a)
		}
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig
	log.Print("shutdown")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	_ = ctx
	if err := defradbembed.StopNode(); err != nil {
		log.Printf("StopNode: %v", err)
	}
}
