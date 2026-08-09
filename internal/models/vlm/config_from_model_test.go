package vlm

import (
	"net/http"
	"net/http/httptest"
	"testing"

	secutils "github.com/Tencent/WeKnora/internal/utils"
	"github.com/Tencent/WeKnora/internal/types"
)

func TestConfigFromModel_RemoteDefaultsToOpenAI(t *testing.T) {
	m := &types.Model{
		ID:     "v1",
		Name:   "gpt-4o",
		Source: types.ModelSourceRemote,
		Parameters: types.ModelParameters{
			BaseURL:       "https://api.example.com/v1",
			APIKey:        "sk",
			Provider:      "openai",
			ExtraConfig:   map[string]string{"x": "y"},
			CustomHeaders: map[string]string{"H": "v"},
		},
	}
	cfg := ConfigFromModel(m, "app", "secret")
	if cfg.InterfaceType != "openai" {
		t.Errorf("expected openai default for remote, got %q", cfg.InterfaceType)
	}
	if cfg.CustomHeaders["H"] != "v" {
		t.Errorf("CustomHeaders not propagated: %+v", cfg.CustomHeaders)
	}
	if cfg.Extra["x"] != "y" {
		t.Errorf("ExtraConfig not propagated as Extra: %+v", cfg.Extra)
	}
	if cfg.AppID != "app" || cfg.AppSecret != "secret" {
		t.Errorf("cloud creds mismatch: %+v", cfg)
	}
}

func TestConfigFromModel_LocalDefaultsToOllama(t *testing.T) {
	m := &types.Model{
		Name:   "qwen2-vl",
		Source: types.ModelSourceLocal,
	}
	cfg := ConfigFromModel(m, "", "")
	if cfg.InterfaceType != "ollama" {
		t.Errorf("expected ollama default for local, got %q", cfg.InterfaceType)
	}
}

func TestConfigFromModel_RespectsExplicitInterface(t *testing.T) {
	m := &types.Model{
		Name:   "qwen2-vl",
		Source: types.ModelSourceRemote,
		Parameters: types.ModelParameters{
			InterfaceType: "ollama",
		},
	}
	if got := ConfigFromModel(m, "", "").InterfaceType; got != "ollama" {
		t.Errorf("expected explicit interface to win, got %q", got)
	}
}

// TestConfigFromModel_ImageDetailPropagation pins down the ModelParameters.ImageDetail
// → vlm.Config.ImageDetail wiring. This is the knob users turn when their
// provider rejects the SDK default of "auto" (e.g. MiniMax M3, code 2013).
// Without this mapping the field would be silently dropped and every request
// would still send "auto".
func TestConfigFromModel_ImageDetailPropagation(t *testing.T) {
	cases := []struct {
		name      string
		setOnModel string
		want      string
	}{
		{"empty stays empty (omitempty will drop the field)", "", ""},
		{"low is forwarded", "low", "low"},
		{"high is forwarded", "high", "high"},
		{"auto is forwarded (still allowed when user opts in)", "auto", "auto"},
		// Provider-specific escape hatch — we do not validate the value, the
		// upstream decides. If a provider rejects it, that's a config error
		// the user should see, not a silent hardcoded "auto" surprise.
		{"arbitrary provider-specific value is forwarded", "minimax_default", "minimax_default"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := &types.Model{
				ID:     "vlm-x",
				Name:   "minimax-m3",
				Source: types.ModelSourceRemote,
				Parameters: types.ModelParameters{
					ImageDetail: tc.setOnModel,
				},
			}
			cfg := ConfigFromModel(m, "", "")
			if cfg.ImageDetail != tc.want {
				t.Errorf("Config.ImageDetail = %q, want %q", cfg.ImageDetail, tc.want)
			}
		})
	}
}

// TestNewRemoteAPIVLM_StoresTrimmedImageDetail guards against the easy mistake
// of leaving a stray space (YAML is whitespace-tolerant) that would round-trip
// as " auto" and silently break matching.
func TestNewRemoteAPIVLM_StoresTrimmedImageDetail(t *testing.T) {
	// Use the httptest mock server so we don't trip the SSRF DNS check
	// against an unrelated domain. The server doesn't need to actually be
	// hit for this test — we only assert the field is stored.
	t.Setenv("SSRF_WHITELIST", "127.0.0.1")
	secutils.ResetSSRFWhitelistForTest()
	t.Cleanup(secutils.ResetSSRFWhitelistForTest)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()

	v, err := NewRemoteAPIVLM(&Config{
		BaseURL:     srv.URL,
		APIKey:      "sk",
		ModelName:   "minimax-m3",
		ImageDetail: "  high  ",
	})
	if err != nil {
		t.Fatalf("NewRemoteAPIVLM: %v", err)
	}
	if v.imageDetail != "high" {
		t.Errorf("imageDetail not trimmed: got %q", v.imageDetail)
	}
}
