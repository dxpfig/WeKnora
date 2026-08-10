-- Per-image retry feature: status is stored inside
-- chunks.metadata.image_statuses[image_url] (JSONB). To make
-- "WHERE metadata @> '...'" queries indexable, add a GIN index.
--
-- This index also benefits the existing custom_metadata / faq keys
-- that already live inside chunks.metadata — no harm.
--
-- Backwards compatible: existing rows have NULL metadata; the UPDATE
-- just initializes them to '{}' so the @> operator works.

UPDATE chunks SET metadata = '{}'::jsonb WHERE metadata IS NULL;

CREATE INDEX IF NOT EXISTS idx_chunks_metadata_gin
  ON chunks USING GIN (metadata jsonb_path_ops);