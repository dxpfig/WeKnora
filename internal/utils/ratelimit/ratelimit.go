// Package ratelimit provides shared helpers for classifying rate-limit
// failures from upstream LLM / VLM / embedding providers.
//
// Moved from internal/application/service/knowledge_process.go (was
// package-private isLikelyRateLimitError) so the same fuzzy classifier
// can be reused by image_multimodal.go for VLM 429 detection, without
// duplicating the needle list at three call sites.
package ratelimit

import "strings"

// needles is the case-insensitive substring list we match against the
// error message. Kept as a package-private constant so adding/removing
// a provider-specific phrasing happens in one place. Order does not
// matter — strings.Contains is the discriminator.
var needles = []string{
	"rate limit",
	"ratelimit",
	"429",
	"too many requests",
	"quota",
}

// IsLikelyRateLimitError performs a fuzzy classification of an error as
// a rate-limit / quota / backpressure failure.
//
// We only need a hint — the caller maps the boolean to one of two
// outcomes (e.g. error_code "embedding_rate_limit" vs. a generic
// internal error). False positives are harmless: the underlying
// error message is preserved on the result regardless.
//
// Returns false for nil errors.
func IsLikelyRateLimitError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	for _, needle := range needles {
		if strings.Contains(msg, needle) {
			return true
		}
	}
	return false
}