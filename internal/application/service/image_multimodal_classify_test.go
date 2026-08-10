package service

import (
	"errors"
	"testing"

	"github.com/Tencent/WeKnora/internal/types"
)

// TestClassifyVLMError covers the two output classes used in
// image_statuses entries. Defensive — also asserts that nil returns
// empty string so callers can safely check `entry.ErrorClass != ""`.
func TestClassifyVLMError(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		err  error
		want string
	}{
		{name: "nil returns empty", err: nil, want: ""},
		{name: "rate_limit", err: errors.New("HTTP 429 from upstream"), want: "rate_limit"},
		{name: "vlm_error", err: errors.New("json parse failed"), want: "vlm_error"},
		{name: "Chinese rate limit not detected (no Chinese needle)", err: errors.New("已达到速率限制"), want: "vlm_error"},
	}
	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := classifyVLMError(tt.err); got != tt.want {
				t.Errorf("classifyVLMError(%v) = %q, want %q", tt.err, got, tt.want)
			}
		})
	}
}

// TestComputeFinalStatus exercises the priority rule: rate_limit beats
// vlm_error, the longer error message wins, and a clean run (no errors)
// produces ImageStatusSucceeded.
func TestComputeFinalStatus(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name         string
		imgOut       types.JSONMap
		wantStatus   types.ImageStatus
		wantErrorCls string
	}{
		{
			name:       "no errors -> succeeded",
			imgOut:     types.JSONMap{},
			wantStatus: types.ImageStatusSucceeded,
		},
		{
			name: "ocr rate_limit -> failed rate_limit",
			imgOut: types.JSONMap{
				"ocr_error":       "HTTP 429",
				"ocr_error_class": "rate_limit",
			},
			wantStatus:   types.ImageStatusFailed,
			wantErrorCls: "rate_limit",
		},
		{
			name: "caption vlm_error only -> failed vlm_error",
			imgOut: types.JSONMap{
				"caption_error":       "json parse failed",
				"caption_error_class": "vlm_error",
			},
			wantStatus:   types.ImageStatusFailed,
			wantErrorCls: "vlm_error",
		},
		{
			name: "rate_limit wins over vlm_error",
			imgOut: types.JSONMap{
				"ocr_error":          "json parse failed",
				"ocr_error_class":    "vlm_error",
				"caption_error":      "HTTP 429",
				"caption_error_class": "rate_limit",
			},
			wantStatus:   types.ImageStatusFailed,
			wantErrorCls: "rate_limit",
		},
	}
	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := computeFinalStatus(tt.imgOut)
			if got.Status != tt.wantStatus {
				t.Errorf("status = %q, want %q", got.Status, tt.wantStatus)
			}
			if got.ErrorClass != tt.wantErrorCls {
				t.Errorf("error_class = %q, want %q", got.ErrorClass, tt.wantErrorCls)
			}
		})
	}
}

// TestShouldRetryImage covers the rules the user chose on 2026-08-10:
//   - only ImageStatusFailed can be retried
//   - empty OnlyErrorClasses means "retry any failed" (operator opted out)
//   - strict MaxAttempts: attempts >= max → skip
//   - operator-friendly reason messages
func TestShouldRetryImage(t *testing.T) {
	t.Parallel()

	rateLimitEntry := types.ImageStatusEntry{
		Status:      types.ImageStatusFailed,
		ErrorClass:  "rate_limit",
		Attempts:    2,
	}
	vlmErrEntry := types.ImageStatusEntry{
		Status:      types.ImageStatusFailed,
		ErrorClass:  "vlm_error",
		Attempts:    2,
	}
	successEntry := types.ImageStatusEntry{
		Status:   types.ImageStatusSucceeded,
		Attempts: 1,
	}
	atLimitEntry := types.ImageStatusEntry{
		Status:      types.ImageStatusFailed,
		ErrorClass:  "rate_limit",
		Attempts:    3,
	}

	tests := []struct {
		name        string
		entry       types.ImageStatusEntry
		opts        types.RetryFailedImagesOptions
		wantRetry   bool
		wantReasonC string // substring expected in reason
	}{
		{
			name:      "succeeded never retries",
			entry:     successEntry,
			opts:      types.RetryFailedImagesOptions{},
			wantRetry: false,
			wantReasonC: "not in failed state",
		},
		{
			name:      "failed + empty filter = retry",
			entry:     rateLimitEntry,
			opts:      types.RetryFailedImagesOptions{},
			wantRetry: true,
		},
		{
			name:      "failed + matching filter = retry",
			entry:     rateLimitEntry,
			opts:      types.RetryFailedImagesOptions{OnlyErrorClasses: []string{"rate_limit"}},
			wantRetry: true,
		},
		{
			name:      "failed + non-matching filter = skip",
			entry:     vlmErrEntry,
			opts:      types.RetryFailedImagesOptions{OnlyErrorClasses: []string{"rate_limit"}},
			wantRetry: false,
			wantReasonC: "not a retriable error type",
		},
		{
			name:      "filter includes multiple classes",
			entry:     vlmErrEntry,
			opts:      types.RetryFailedImagesOptions{OnlyErrorClasses: []string{"rate_limit", "vlm_error"}},
			wantRetry: true,
		},
		{
			name:      "attempts at limit = skip (strict)",
			entry:     atLimitEntry,
			opts:      types.RetryFailedImagesOptions{MaxAttempts: 3},
			wantRetry: false,
			wantReasonC: "reached max attempts",
		},
		{
			name:      "MaxAttempts 0 = no cap, retry allowed",
			entry:     rateLimitEntry,
			opts:      types.RetryFailedImagesOptions{MaxAttempts: 0},
			wantRetry: true,
		},
	}
	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			retry, reason := shouldRetryImage("img1", tt.entry, tt.opts)
			if retry != tt.wantRetry {
				t.Errorf("retry = %v, want %v (reason: %s)", retry, tt.wantRetry, reason)
			}
			if tt.wantReasonC != "" && !containsSubstr(reason, tt.wantReasonC) {
				t.Errorf("reason %q does not contain %q", reason, tt.wantReasonC)
			}
		})
	}
}

func containsSubstr(s, sub string) bool {
	if len(sub) == 0 {
		return true
	}
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}