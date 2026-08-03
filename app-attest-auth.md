# ADR: App Attest–Backed Installation Sessions

Status: accepted for implementation

Date: 2026-08-03

## Decision

Lore will protect remote transcription and daily-entry generation with anonymous, App Attest–backed installation sessions. App Attest establishes that a key belongs to a legitimate instance of Lore on Apple hardware; it does not identify a person or create a Lore account.

The iOS app will:

1. Check `DCAppAttestService.isSupported` before offering remote processing.
2. Generate one App Attest key per installation and store only its opaque key identifier in non-synchronizing, device-only Keychain storage.
3. Obtain a random, one-time challenge from Lore before attestation or assertion.
4. Attest the key once, then use assertions to renew short-lived, scoped Lore session tokens.
5. Serialize assertion generation for the key so valid counters cannot arrive out of order.
6. Keep session credentials out of logs and never place Fireworks or Groq credentials in the app.

The backend will:

1. Atomically issue and consume short-lived challenges.
2. Validate Apple's complete attestation chain, nonce, key identifier, RP ID, zero counter, and AAGUID/environment. On iOS 27 and later, also validate the launch category and bundle-version extensions; older supported systems legitimately omit those newer fields.
3. Store the verified public key and monotonically increasing assertion counter in a durable, content-free security store.
4. Bind assertion client data to the challenge, purpose, key, and session request before atomically advancing the counter.
5. Issue short-lived HMAC-signed session tokens scoped to Lore's `request_ephemeral` processing routes.
6. Accept only App Attest-backed sessions and fail closed when App Attest or its durable security store is unavailable.

Apple's client and server procedures are authoritative: [establishing app integrity](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity), [validating apps that connect to a server](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server), and the [attestation validation guide](https://developer.apple.com/documentation/devicecheck/attestation-object-validation-guide).

## Why a short-lived session

An App Attest assertion is appropriate at the sensitive bootstrap/renewal boundary. A short-lived Lore session then authenticates bounded inference requests without repeatedly invoking Secure Enclave signing for every audio chunk. The token lifetime limits the usefulness of a stolen token, while server-side installation quotas and idempotency claims bound inference abuse.

This session is not an account login. A later Lore account can associate multiple attested installation hashes without changing the processing contract.

## Wire protocol

### `POST /v1/auth/challenges`

Input:

- schema version
- purpose: `attestation` or `assertion`
- key ID for assertion renewal

Output:

- opaque challenge ID
- 32 random challenge bytes encoded as base64url
- absolute expiry

### `POST /v1/auth/attestations`

Input:

- schema version
- challenge ID
- App Attest key ID
- unmodified attestation object encoded as base64

After complete verification and an atomic challenge consume/key insert, the backend returns a scoped session token and expiry. The pseudonymous installation reference remains server-side.

### `POST /v1/auth/sessions`

The client creates canonical sorted-key JSON bytes containing `schema_version`, `action=create_session`, `challenge_id`, and `challenge`. It hashes those exact bytes for `generateAssertion` and sends both the assertion and standard-base64 canonical client data. The backend validates the client data against the stored, key-bound challenge, verifies the assertion, and atomically advances the counter before issuing a replacement session.

Processing routes accept `Authorization: Bearer <session>` and continue requiring their existing idempotency and `request_ephemeral` fields.

## Durable security state

The production store contains only:

- HMAC-pseudonymized key/installation identifiers
- verified public keys and encrypted Apple receipts
- attestation environment, optional iOS 27+ validation category and bundle version, status, and assertion counter
- challenge hashes, purposes, expiries, and consumption state
- content-free rate-limit buckets and idempotency/lease metadata
- session revocation/version metadata if later required

It must never contain audio, transcripts, prompts, vocabulary, generated prose, biography facts, raw request bodies, raw IP addresses, authorization tokens, attestation/assertion objects, or provider responses.

Vercel Functions cannot use process memory or their filesystem as authoritative state because invocations scale independently. Production uses a Neon Postgres database installed through Vercel Marketplace. `backend/migrations/001_app_attest_auth.sql` supplies row-locking transactions for one-winner challenge consumption, key registration, and counter advancement. `backend/migrations/002_processing_leases.sql` supplies expiring, token-conditional one-winner provider leases. Tests use an in-memory implementation only as a deterministic substitute.

## Distribution policy

- Debug and Simulator builds are local-only and never connect to the Lore processing API.
- TestFlight and App Store builds use Apple's production App Attest environment; development attestations and static application credentials are rejected.
- `isSupported == false`: recording and local processing remain available, but anonymous remote inference is unavailable in Production. A future authenticated-account fallback requires a separate threat and quota decision.
- Reinstall, device restore, or key loss: create and attest a new key. Old keys are not silently reused or immediately assumed malicious.

The key identifier uses a `ThisDeviceOnly` Keychain accessibility class and is not synchronized or restored to another device.

## Abuse and replay controls

- Coarse Vercel WAF limits protect unauthenticated auth endpoints.
- Application limits use a keyed pseudonymous installation hash and route, never story content or a raw device identifier.
- Challenges are random, short-lived, purpose-bound, and single-use.
- Assertion counters only advance; concurrent or replayed counters fail.
- Session tokens have an audience, issuer, installation subject, scopes, issued-at time, expiry, and unique ID.
- Processing idempotency identities are HMACed with the installation/task scope. An active duplicate receives retryable `409 processing_in_progress`; an expired lease can be taken over, and an old token cannot release its replacement.
- Processing retains at-least-once provider semantics after an ambiguous upstream timeout, while the iPhone installs results idempotently by `ProcessingJob` ID.

## Production gates

Production remote processing remains disabled until all of these are proven:

- App Attest capability and the production environment entitlement exist in TestFlight and App Store signing profiles.
- The backend has the exact Lore App ID prefix/team ID, bundle ID, allowed iOS 27+ build versions/categories, strong signing/HMAC/encryption keys, and the migrated Neon security store.
- Apple validation vectors and malformed CBOR/ASN.1 cases pass.
- Expired, replayed, wrong-purpose, wrong-key, wrong-app, wrong-environment, and non-increasing-counter requests fail before provider invocation.
- Concurrent challenge/counter/idempotency tests prove a single winner against the real Production data store using synthetic content.
- Logs and traces contain no auth artifacts or user content.
- A TestFlight build completes the enrollment and renewal flows on a physical device.

## Consequences

This adds a small amount of durable security metadata and a storage dependency, but not a cloud biography. It prevents a static application secret from becoming an inference-spending credential. It also means remote processing cannot be promised on unsupported or unattested devices until Lore has a separately approved authenticated fallback.
