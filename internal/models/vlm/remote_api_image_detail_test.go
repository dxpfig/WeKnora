package vlm

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	secutils "github.com/Tencent/WeKnora/internal/utils"
)

// captureRequestJSON spins up an OpenAI-compatible mock endpoint that echoes
// back the request body so the test can assert what Predict actually sent.
// Returns the server URL, the channel that receives each raw request body,
// and the captured request body (for the final assertion).
func captureRequestJSON(t *testing.T) (string, <-chan []byte) {
	t.Helper()
	// httptest.NewServer binds to 127.0.0.1, which the VLM SSRF guard rejects
	// by default. The whitelist is a process-wide singleton so we must reset
	// it back to empty at test end to avoid leaking state into the next test.
	t.Setenv("SSRF_WHITELIST", "127.0.0.1")
	secutils.ResetSSRFWhitelistForTest()
	t.Cleanup(secutils.ResetSSRFWhitelistForTest)

	bodies := make(chan []byte, 4)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		bodies <- body
		w.Header().Set("Content-Type", "application/json")
		// Minimal OpenAI-compatible response so Predict doesn't error.
		_, _ = w.Write([]byte(`{
            "id": "chatcmpl-test",
            "object": "chat.completion",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": "ok"},
                "finish_reason": "stop"
            }],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}
        }`))
	}))
	t.Cleanup(srv.Close)
	return srv.URL, bodies
}

// TestRemoteAPIVLM_OmitsImageDetailWhenEmpty is the regression guard for the
// MiniMax M3 "invalid image detail: auto (2013)" bug. Before the fix, every
// request hardcoded `detail: "auto"` regardless of provider support. Now an
// empty ImageDetail must result in the field being absent from the JSON body
// so providers fall back to their own default (typically "high").
func TestRemoteAPIVLM_OmitsImageDetailWhenEmpty(t *testing.T) {
	url, bodies := captureRequestJSON(t)
	v, err := NewRemoteAPIVLM(&Config{
		BaseURL:    url,
		APIKey:     "sk",
		ModelName:  "minimax-m3",
		ImageDetail: "", // explicit: do not emit the field
	})
	if err != nil {
		t.Fatalf("NewRemoteAPIVLM: %v", err)
	}

	if _, err := v.Predict(context.Background(), [][]byte{png1x1}, "describe"); err != nil {
		t.Fatalf("Predict: %v", err)
	}

	body := <-bodies
	raw := string(body)
	if strings.Contains(raw, `"detail"`) {
		t.Errorf("expected request body to omit `detail` when ImageDetail is empty; got body:\n%s", raw)
	}
}

// TestRemoteAPIVLM_ForwardsConfiguredImageDetail verifies the round-trip:
// setting ModelParameters.ImageDetail = "high" produces `"detail":"high"` in
// the request body. This is the path users on MiniMax M3 (or any other
// provider that rejects "auto") will rely on.
func TestRemoteAPIVLM_ForwardsConfiguredImageDetail(t *testing.T) {
	url, bodies := captureRequestJSON(t)
	v, err := NewRemoteAPIVLM(&Config{
		BaseURL:    url,
		APIKey:     "sk",
		ModelName:  "minimax-m3",
		ImageDetail: "high",
	})
	if err != nil {
		t.Fatalf("NewRemoteAPIVLM: %v", err)
	}
	if _, err := v.Predict(context.Background(), [][]byte{png1x1}, "describe"); err != nil {
		t.Fatalf("Predict: %v", err)
	}

	body := <-bodies
	var parsed struct {
		Messages []struct {
			Role         string `json:"role"`
			MultiContent []struct {
				Type     string `json:"type"`
				Text     string `json:"text,omitempty"`
				ImageURL *struct {
					URL    string `json:"url"`
					Detail string `json:"detail,omitempty"`
				} `json:"image_url,omitempty"`
			} `json:"content"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		t.Fatalf("unmarshal body: %v\nbody=%s", err, string(body))
	}
	if len(parsed.Messages) != 1 {
		t.Fatalf("expected 1 message, got %d", len(parsed.Messages))
	}
	parts := parsed.Messages[0].MultiContent
	if len(parts) != 2 {
		t.Fatalf("expected [text, image_url], got %d parts", len(parts))
	}
	if parts[1].Type != "image_url" || parts[1].ImageURL == nil {
		t.Fatalf("second part is not image_url: %+v", parts[1])
	}
	if parts[1].ImageURL.Detail != "high" {
		t.Errorf("detail = %q, want \"high\"", parts[1].ImageURL.Detail)
	}
}

// TestRemoteAPIVLM_ArbitraryImageDetailPassesThrough covers the
// provider-specific escape hatch. We don't validate the value — if a user
// types "minimax_default" and their provider happens to accept it, the
// request should carry that string verbatim. Better to surface a clear
// provider-side error than to silently rewrite it to "auto".
func TestRemoteAPIVLM_ArbitraryImageDetailPassesThrough(t *testing.T) {
	url, bodies := captureRequestJSON(t)
	v, err := NewRemoteAPIVLM(&Config{
		BaseURL:    url,
		APIKey:     "sk",
		ModelName:  "minimax-m3",
		ImageDetail: "minimax_default",
	})
	if err != nil {
		t.Fatalf("NewRemoteAPIVLM: %v", err)
	}
	if _, err := v.Predict(context.Background(), [][]byte{png1x1}, "describe"); err != nil {
		t.Fatalf("Predict: %v", err)
	}
	body := <-bodies
	if !strings.Contains(string(body), `"detail":"minimax_default"`) {
		t.Errorf("expected provider-specific detail value to pass through; body:\n%s", string(body))
	}
}

// png1x1 is a minimal valid PNG (1x1 transparent) — enough to satisfy the
// VLM client's base64 encoding without pulling in a test fixture file.
var png1x1 = []byte{
	0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, // signature
	0x00, 0x00, 0x00, 0x0d, 'I', 'H', 'D', 'R',
	0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
	0x08, 0x06, 0x00, 0x00, 0x00,
	0x1f, 0x15, 0xc4, 0x89,
	0x00, 0x00, 0x00, 0x0d, 'I', 'D', 'A', 'T',
	0x78, 0x9c, 0x62, 0x00, 0x01, 0x00, 0x00, 0x05,
	0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4,
	0x00, 0x00, 0x00, 0x00, 'I', 'E', 'N', 'D',
	0xae, 0x42, 0x60, 0x82,
}
