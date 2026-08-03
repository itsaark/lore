-- Bounded cleanup for content-free security metadata only. Each invocation
-- deletes at most p_batch_size rows from each table and never touches audio,
-- transcripts, prompts, generated text, or App Attest key/receipt state.
CREATE OR REPLACE FUNCTION lore_cleanup_expired_security_metadata(
  p_now timestamptz,
  p_batch_size integer
) RETURNS TABLE(
  deleted_challenges integer,
  deleted_rate_limit_buckets integer,
  deleted_processing_leases integer
) LANGUAGE plpgsql AS $$
BEGIN
  IF p_batch_size IS NULL OR p_batch_size < 1 OR p_batch_size > 1000 THEN
    RAISE EXCEPTION 'security metadata cleanup batch must be between 1 and 1000';
  END IF;

  WITH candidates AS (
    SELECT ctid
    FROM lore_app_attest_challenges
    WHERE expires_at <= p_now
    ORDER BY expires_at
    LIMIT p_batch_size
    FOR UPDATE SKIP LOCKED
  ), deleted AS (
    DELETE FROM lore_app_attest_challenges AS target
    USING candidates
    WHERE target.ctid = candidates.ctid
    RETURNING 1
  )
  SELECT count(*)::integer INTO deleted_challenges FROM deleted;

  WITH candidates AS (
    SELECT ctid
    FROM lore_auth_rate_limits
    WHERE expires_at <= p_now
    ORDER BY expires_at
    LIMIT p_batch_size
    FOR UPDATE SKIP LOCKED
  ), deleted AS (
    DELETE FROM lore_auth_rate_limits AS target
    USING candidates
    WHERE target.ctid = candidates.ctid
    RETURNING 1
  )
  SELECT count(*)::integer INTO deleted_rate_limit_buckets FROM deleted;

  WITH candidates AS (
    SELECT ctid
    FROM lore_processing_leases
    WHERE lease_expires_at <= p_now
    ORDER BY lease_expires_at
    LIMIT p_batch_size
    FOR UPDATE SKIP LOCKED
  ), deleted AS (
    DELETE FROM lore_processing_leases AS target
    USING candidates
    WHERE target.ctid = candidates.ctid
    RETURNING 1
  )
  SELECT count(*)::integer INTO deleted_processing_leases FROM deleted;

  RETURN NEXT;
END;
$$;
