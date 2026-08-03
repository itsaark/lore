-- Content-free, one-winner leases for remote provider invocations.
-- claim_ref is an HMAC of installation + task + idempotency identity; neither
-- raw identity, request bodies, audio, transcripts, nor generated text live here.
CREATE TABLE IF NOT EXISTS lore_processing_leases (
  claim_ref text PRIMARY KEY CHECK (claim_ref ~ '^[0-9a-f]{64}$'),
  lease_token text NOT NULL CHECK (length(lease_token) BETWEEN 20 AND 128),
  lease_expires_at timestamptz NOT NULL,
  acquired_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS lore_processing_leases_expiry
  ON lore_processing_leases (lease_expires_at);

CREATE OR REPLACE FUNCTION lore_acquire_processing_lease(
  p_claim_ref text,
  p_lease_token text,
  p_now timestamptz,
  p_expires_at timestamptz
) RETURNS TABLE(result_status text, result_expires_at timestamptz)
LANGUAGE plpgsql AS $$
DECLARE
  existing_expires_at timestamptz;
BEGIN
  IF p_expires_at <= p_now THEN
    RAISE EXCEPTION 'processing lease expiry must follow acquisition';
  END IF;

  LOOP
    INSERT INTO lore_processing_leases
      (claim_ref, lease_token, lease_expires_at, acquired_at, updated_at)
    VALUES
      (p_claim_ref, p_lease_token, p_expires_at, p_now, p_now)
    ON CONFLICT (claim_ref) DO NOTHING;

    IF FOUND THEN
      RETURN QUERY SELECT 'acquired'::text, p_expires_at;
      RETURN;
    END IF;

    SELECT lease_expires_at INTO existing_expires_at
    FROM lore_processing_leases
    WHERE claim_ref = p_claim_ref
    FOR UPDATE;

    -- A concurrent release can remove the row between INSERT and SELECT.
    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    IF existing_expires_at <= p_now THEN
      UPDATE lore_processing_leases
      SET lease_token = p_lease_token,
          lease_expires_at = p_expires_at,
          acquired_at = p_now,
          updated_at = p_now
      WHERE claim_ref = p_claim_ref;
      RETURN QUERY SELECT 'acquired'::text, p_expires_at;
      RETURN;
    END IF;

    RETURN QUERY SELECT 'active'::text, existing_expires_at;
    RETURN;
  END LOOP;
END;
$$;
