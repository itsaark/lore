# Lore Production Runbook

Last updated: 2026-08-05

Lore has one backend environment: Production. Debug and Simulator builds are local-only, only `main` is deployment-enabled in Vercel, and provider/authentication variables are scoped only to Production.

## Architecture boundary

- The iPhone keeps the working SwiftData cache; transcripts, journal entries, profile, vocabulary, and biography data sync through the user's private CloudKit database.
- Audio files and processing jobs remain device-local and are not recoverable on another phone.
- Vercel handles request-ephemeral forwarding and validation only.
- Groq performs synchronous speech-to-text; Fireworks performs synchronous grounded daily-entry generation.
- Neon stores only content-free security state required by App Attest, replay prevention, rate limiting, and processing leases. It must never receive request bodies or user content.

## Production prerequisites

1. Enable App Attest for Apple App ID `cascadianpines.lore` and regenerate Distribution/TestFlight signing profiles.
2. Register iCloud container `iCloud.cascadianpines.lore`, attach it to the App ID with CloudKit support, enable Push Notifications, and regenerate signing profiles.
3. Initialize the CloudKit development schema from a signed Debug build, inspect encrypted fields and indexes in CloudKit Console, then deploy the schema to Production before TestFlight.
4. Install the Neon Vercel Marketplace integration on project `lore`, selecting only Production. Confirm that it injects a pooled `DATABASE_URL` only into Production.
5. Apply `backend/migrations/001_app_attest_auth.sql`, `002_processing_leases.sql`, and `003_security_metadata_cleanup.sql` in filename order using a direct/migration-capable Neon connection.
6. Confirm Groq organization Data Controls have ZDR enabled for the selected Audio Transcriptions endpoint and model before sending real audio.
7. Approve Fireworks' open-model ZDR and bounded volatile prompt-cache behavior before sending real text.

## Required Vercel Production variables

- `FIREWORKS_API_KEY`
- `GROQ_API_KEY`
- `DATABASE_URL` from Neon
- `CRON_SECRET`
- `LORE_SESSION_SIGNING_SECRET`
- `LORE_AUTH_STATE_HMAC_SECRET`
- `LORE_AUTH_RECEIPT_ENCRYPTION_KEY`

There are no other configuration variables. These seven values are secrets or contain credentials. The provider policy, Apple identifiers, Production App Attest categories, TTLs, cleanup bounds, and always-available Production processing routes are public source-controlled constants.

## Deploy and verify

1. Merge a verified change into `main`; Vercel deploys the `backend` root to Production.
2. Confirm `GET /v1/health` returns `200` without exposing configuration values.
3. Confirm an unauthenticated processing request returns `401` before any provider call.
4. From TestFlight, use synthetic content to prove first App Attest enrollment, cached-session processing, assertion renewal, reinstall/key rotation, and exactly-once retry after a rejected session.
5. Prove concurrent duplicate requests produce one provider call and a retryable `409` for the loser.
6. Verify Vercel logs contain only allowlisted content-free fields and that Neon contains only the tables/columns defined by migrations `001`–`003`.
7. Verify the hourly cleanup cron succeeds and deletes only expired challenges, rate buckets, and leases.
8. Only then allow real-user processing.

## Rotation and rollback

- Rotate provider keys independently in Vercel Production.
- Rotating `LORE_SESSION_SIGNING_SECRET` invalidates active sessions; clients automatically establish a new session.
- Rotate `LORE_AUTH_STATE_HMAC_SECRET` only with a re-enrollment plan because it changes opaque database references.
- Rotate `LORE_AUTH_RECEIPT_ENCRYPTION_KEY` only with a receipt re-encryption plan.
- Roll back the Production deployment in Vercel only to a schema-compatible commit. Database migrations are forward-only unless an explicit reviewed rollback exists.

## Incident response

1. Revoke the affected provider key or roll back the Production deployment; local recording and storage remain available.
2. Preserve only content-free deployment/request IDs and timing/error metadata.
3. Do not copy transcripts, audio, prompts, model output, authorization headers, or provider payloads into tickets or logs.
4. Revoke or rotate affected credentials, validate database/security-state integrity, deploy the fix, and repeat the synthetic TestFlight canary before re-enabling.
