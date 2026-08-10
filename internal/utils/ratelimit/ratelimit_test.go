package ratelimit

import (
	"errors"
	"testing"
)

// TestIsLikelyRateLimitError_Moved covers the 5 needles the package
// matches against, plus the nil-error edge case. Regression guard for
// the 2026-08-10 refactor (function moved here from
// knowledge_process.go so it could be reused by image_multimodal.go).
func TestIsLikelyRateLimitError_Moved(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		err  error
		want bool
	}{
		{name: "nil returns false", err: nil, want: false},
		{name: "exact 429", err: errors.New("HTTP 429 Too Many Requests"), want: true},
		{name: "rate limit phrase", err: errors.New("provider returned rate limit response"), want: true},
		{name: "ratelimit no space", err: errors.New("error: ratelimit exceeded"), want: true},
		{name: "too many requests", err: errors.New("openai: too many requests in last minute"), want: true},
		{name: "quota", err: errors.New("quota exceeded for this billing period"), want: true},
		{name: "case-insensitive", err: errors.New("RATE LIMIT HIT"), want: true},
		{name: "Chinese 速率限制", err: errors.New("已达到 Token Plan 速率限制"), want: false}, // no Chinese needle
		{name: "unrelated error", err: errors.New("json parse failed: unexpected EOF"), want: false},
	}
	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := IsLikelyRateLimitError(tt.err); got != tt.want {
				t.Errorf("IsLikelyRateLimitError(%q) = %v, want %v", tt.err, got, tt.want)
			}
		})
	}
}