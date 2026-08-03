CREATE TABLE IF NOT EXISTS lore_app_attest_challenges (
  challenge_id uuid PRIMARY KEY,
  challenge_hash text NOT NULL,
  purpose text NOT NULL CHECK (purpose IN ('attestation', 'assertion')),
  key_ref text,
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS lore_app_attest_challenges_expiry
  ON lore_app_attest_challenges (expires_at);

CREATE TABLE IF NOT EXISTS lore_app_attest_keys (
  key_ref text PRIMARY KEY,
  key_id_hash text NOT NULL UNIQUE,
  public_key_pem text NOT NULL,
  receipt_ciphertext text NOT NULL,
  environment text NOT NULL CHECK (environment IN ('development', 'production')),
  validation_category integer,
  bundle_version text,
  CONSTRAINT lore_app_attest_extension_pair CHECK (
    (validation_category IS NULL) = (bundle_version IS NULL)
  ),
  counter bigint NOT NULL DEFAULT 0 CHECK (counter >= 0 AND counter <= 4294967295),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS lore_auth_rate_limits (
  bucket_ref text NOT NULL,
  window_started_at timestamptz NOT NULL,
  request_count integer NOT NULL CHECK (request_count > 0),
  expires_at timestamptz NOT NULL,
  PRIMARY KEY (bucket_ref, window_started_at)
);

CREATE INDEX IF NOT EXISTS lore_auth_rate_limits_expiry
  ON lore_auth_rate_limits (expires_at);

-- App Attest validation-category and bundle-version extensions are available
-- beginning with iOS 27. Legacy enrollments intentionally store both as NULL.
ALTER TABLE lore_app_attest_keys
  ALTER COLUMN validation_category DROP NOT NULL,
  ALTER COLUMN bundle_version DROP NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'lore_app_attest_extension_pair'
      AND conrelid = 'lore_app_attest_keys'::regclass
  ) THEN
    ALTER TABLE lore_app_attest_keys ADD CONSTRAINT lore_app_attest_extension_pair
      CHECK ((validation_category IS NULL) = (bundle_version IS NULL));
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION lore_register_app_attest_key(
  p_challenge_id uuid, p_challenge_hash text, p_now timestamptz,
  p_key_ref text, p_key_id_hash text, p_public_key_pem text,
  p_receipt_ciphertext text, p_environment text, p_validation_category integer,
  p_bundle_version text, p_counter bigint, p_created_at timestamptz
) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  challenge_row lore_app_attest_challenges%ROWTYPE;
BEGIN
  SELECT * INTO challenge_row FROM lore_app_attest_challenges
    WHERE challenge_id = p_challenge_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'missing'; END IF;
  IF challenge_row.consumed_at IS NOT NULL THEN RETURN 'replayed'; END IF;
  IF challenge_row.expires_at <= p_now THEN RETURN 'expired'; END IF;
  IF challenge_row.challenge_hash <> p_challenge_hash
     OR challenge_row.purpose <> 'attestation'
     OR challenge_row.key_ref IS NOT NULL THEN RETURN 'mismatch'; END IF;

  UPDATE lore_app_attest_challenges SET consumed_at = p_now
    WHERE challenge_id = p_challenge_id;
  INSERT INTO lore_app_attest_keys
    (key_ref, key_id_hash, public_key_pem, receipt_ciphertext, environment,
     validation_category, bundle_version, counter, created_at, updated_at)
    VALUES (p_key_ref, p_key_id_hash, p_public_key_pem, p_receipt_ciphertext,
            p_environment, p_validation_category, p_bundle_version, p_counter,
            p_created_at, p_created_at)
    ON CONFLICT DO NOTHING;
  IF NOT FOUND THEN RETURN 'key_exists'; END IF;
  RETURN 'consumed';
END;
$$;

CREATE OR REPLACE FUNCTION lore_advance_app_attest_counter(
  p_challenge_id uuid, p_challenge_hash text, p_key_ref text,
  p_expected_counter bigint, p_next_counter bigint, p_now timestamptz
) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  challenge_row lore_app_attest_challenges%ROWTYPE;
  key_counter bigint;
BEGIN
  SELECT * INTO challenge_row FROM lore_app_attest_challenges
    WHERE challenge_id = p_challenge_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'missing'; END IF;
  IF challenge_row.consumed_at IS NOT NULL THEN RETURN 'replayed'; END IF;
  IF challenge_row.expires_at <= p_now THEN RETURN 'expired'; END IF;
  IF challenge_row.challenge_hash <> p_challenge_hash
     OR challenge_row.purpose <> 'assertion'
     OR challenge_row.key_ref IS DISTINCT FROM p_key_ref THEN RETURN 'mismatch'; END IF;

  SELECT counter INTO key_counter FROM lore_app_attest_keys
    WHERE key_ref = p_key_ref FOR UPDATE;
  IF NOT FOUND OR key_counter <> p_expected_counter OR p_next_counter <= key_counter THEN
    RETURN 'counter_replayed';
  END IF;

  UPDATE lore_app_attest_challenges SET consumed_at = p_now
    WHERE challenge_id = p_challenge_id;
  UPDATE lore_app_attest_keys SET counter = p_next_counter, updated_at = p_now
    WHERE key_ref = p_key_ref;
  RETURN 'consumed';
END;
$$;
