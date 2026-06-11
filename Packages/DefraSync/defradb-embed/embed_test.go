package defradbembed_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	defradbembed "github.com/edjroz/noop/Packages/DefraSync/defradb-embed"
)

// Subset of the real DefraSync SDL — same 5 type names so the wrapper exercises
// the same surface the macOS smoke test does, just trimmed for test speed.
const testSDL = `
type SleepSession {
  naturalKey: String @index(unique: true)
  deviceId: String @index
  startTs: Int @index
  endTs: Int
  efficiency: Float
  lastWriterPeer: String
  lastWriterTs: Int
}
type DailyMetric {
  naturalKey: String @index(unique: true)
  deviceId: String @index
  day: String @index
  recovery: Float
  lastWriterPeer: String
  lastWriterTs: Int
}
type Journal {
  naturalKey: String @index(unique: true)
  deviceId: String @index
  day: String @index
  question: String
  lastWriterPeer: String
  lastWriterTs: Int
}
type Workout {
  naturalKey: String @index(unique: true)
  deviceId: String @index
  startTs: Int @index
  sport: String
  lastWriterPeer: String
  lastWriterTs: Int
}
type AppleDaily {
  naturalKey: String @index(unique: true)
  deviceId: String @index
  day: String @index
  steps: Int
  lastWriterPeer: String
  lastWriterTs: Int
}
`

func TestStartLoadUpsertQueryStop(t *testing.T) {
	// Use port :0 so the kernel picks free ports — lets tests run in parallel
	// later and avoids collisions if a real sidecar is alive on :9181.
	err := defradbembed.StartNode(
		t.TempDir(),
		"127.0.0.1:0",
		"/ip4/127.0.0.1/tcp/0",
		true, // dev mode = ephemeral identity, no keyring required
	)
	if err != nil {
		t.Fatalf("StartNode: %v", err)
	}
	t.Cleanup(func() {
		if err := defradbembed.StopNode(); err != nil {
			t.Errorf("StopNode: %v", err)
		}
	})

	baseURL := defradbembed.APIBaseURL()
	if baseURL == "" {
		t.Fatal("APIBaseURL is empty after StartNode")
	}

	// Schema bootstrap.
	if err := defradbembed.LoadCollections(testSDL); err != nil {
		t.Fatalf("LoadCollections: %v", err)
	}

	// LoadCollections must be idempotent — re-loading the same SDL is what our
	// Swift code does on every Strand launch when the schema-hash matches cache.
	if err := defradbembed.LoadCollections(testSDL); err != nil {
		t.Fatalf("LoadCollections (second call): %v", err)
	}

	// P2P subscribe is also idempotent and runs every launch.
	collections := []string{"SleepSession", "DailyMetric", "Journal", "Workout", "AppleDaily"}
	if err := defradbembed.P2PSubscribe(collections); err != nil {
		t.Fatalf("P2PSubscribe: %v", err)
	}
	if err := defradbembed.P2PSubscribe(collections); err != nil {
		t.Fatalf("P2PSubscribe (second call): %v", err)
	}

	// Real upsert via the HTTP API — same wire shape DefraSyncer uses in Swift.
	mutation := `mutation {
		upsert_DailyMetric(
			filter: {naturalKey: {_eq: "mock-A|2026-06-11"}},
			add: {naturalKey: "mock-A|2026-06-11", deviceId: "mock-A", day: "2026-06-11", recovery: 72.5, lastWriterPeer: "test", lastWriterTs: 1717800000},
			update: {naturalKey: "mock-A|2026-06-11", deviceId: "mock-A", day: "2026-06-11", recovery: 72.5, lastWriterPeer: "test", lastWriterTs: 1717800000}
		) { _docID }
	}`
	if err := postGraphQL(baseURL, mutation); err != nil {
		t.Fatalf("upsert mutation: %v", err)
	}

	// Read back through GraphQL — proves DefraClient on the Swift side would
	// see the same data.
	var got struct {
		Data struct {
			DailyMetric []struct {
				NaturalKey string  `json:"naturalKey"`
				Day        string  `json:"day"`
				Recovery   float64 `json:"recovery"`
			} `json:"DailyMetric"`
		} `json:"data"`
	}
	if err := getGraphQL(baseURL, `{ DailyMetric { naturalKey day recovery } }`, &got); err != nil {
		t.Fatalf("read mutation: %v", err)
	}
	if len(got.Data.DailyMetric) != 1 {
		t.Fatalf("expected 1 DailyMetric, got %d", len(got.Data.DailyMetric))
	}
	if got.Data.DailyMetric[0].Day != "2026-06-11" {
		t.Fatalf("unexpected day: %s", got.Data.DailyMetric[0].Day)
	}
}

// TestStopWithoutStart confirms StopNode is a safe no-op so Swift callers can
// invoke it unconditionally in deinit paths.
func TestStopWithoutStart(t *testing.T) {
	if err := defradbembed.StopNode(); err != nil {
		t.Fatalf("StopNode without StartNode should be a no-op, got: %v", err)
	}
}

// TestDoubleStartRejected confirms the singleton guard fires.
func TestDoubleStartRejected(t *testing.T) {
	err := defradbembed.StartNode(t.TempDir(), "127.0.0.1:0", "/ip4/127.0.0.1/tcp/0", true)
	if err != nil {
		t.Fatalf("StartNode: %v", err)
	}
	t.Cleanup(func() { _ = defradbembed.StopNode() })

	err = defradbembed.StartNode(t.TempDir(), "127.0.0.1:0", "/ip4/127.0.0.1/tcp/0", true)
	if err == nil {
		t.Fatal("expected second StartNode to error, got nil")
	}
	if !strings.Contains(err.Error(), "already running") {
		t.Fatalf("expected 'already running' error, got: %v", err)
	}
}

// postGraphQL fires a GraphQL mutation against the in-process API. Mirrors
// what Packages/DefraSync/Sources/DefraSync/DefraClient.swift does over HTTP.
func postGraphQL(baseURL, query string) error {
	body, _ := json.Marshal(map[string]any{"query": query})
	req, err := http.NewRequestWithContext(context.Background(), "POST",
		baseURL+"/api/v0/graphql", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	rb, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return fmt.Errorf("graphql status %d: %s", resp.StatusCode, string(rb))
	}
	var envelope struct {
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}
	if err := json.Unmarshal(rb, &envelope); err == nil && len(envelope.Errors) > 0 {
		return fmt.Errorf("graphql errors: %v", envelope.Errors)
	}
	return nil
}

func getGraphQL(baseURL, query string, out any) error {
	body, _ := json.Marshal(map[string]any{"query": query})
	req, err := http.NewRequestWithContext(context.Background(), "POST",
		baseURL+"/api/v0/graphql", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	rb, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return fmt.Errorf("graphql status %d: %s", resp.StatusCode, string(rb))
	}
	return json.Unmarshal(rb, out)
}
