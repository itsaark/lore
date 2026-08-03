# Lore Processing API

Provider-neutral, request-ephemeral backend for Lore transcription and grounded daily-entry generation.

## Current provider topology

- Daily entries: direct Fireworks Chat Completions using `accounts/fireworks/models/gpt-oss-120b`
- Transcription: direct Groq Audio Transcriptions using `whisper-large-v3-turbo`
- No provider-side files, batch jobs, stored response objects, or extra routing layer

The public Lore request and response contracts remain provider-neutral. Provider names and exact model IDs are recorded only in processing provenance. The model aliases `daily-entry-v1` and `transcription-fallback-v1` are stable app-facing identifiers.

Daily-entry requests use Fireworks' stateless Chat Completions endpoint with strict JSON Schema output. The backend re-validates the complete output and rejects invented source or fact references. It does not use Fireworks Responses API storage or conversation state.

Transcription requests use Groq's synchronous Audio Transcriptions endpoint with `verbose_json` segment timestamps, temperature zero, an ISO-639-1 language hint when available, and a bounded vocabulary prompt. The backend never uses Groq Files or Batch APIs.

The iOS HTTPS client, durable transcription/daily-entry job orchestration, anonymous App Attest installation-session flow, and one-winner processing leases are implemented and covered by local mocked tests. Production rejects Preview bearer authentication. Live App Attest, Neon, and app-to-Vercel-to-provider canaries have not run.

## Deploy from GitHub

Import the Lore GitHub repository into Vercel and configure this service as an independently deployed monorepo application:

- Root directory: `backend`
- Framework preset: Other
- Node.js version: 22.x
- Production branch: `main`

Do not create the canonical project with `vercel deploy` before connecting the repository. Once imported, Vercel should build Preview deployments for pull requests and Production deployments from `main`.

## Local verification

```sh
npm install
npm run typecheck
npm test
```

## Routes

- `GET /v1/health`
- `POST /v1/auth/challenges`
- `POST /v1/auth/attestations`
- `POST /v1/auth/sessions`
- `POST /v1/transcriptions`
- `POST /v1/daily-entries`

See `openapi.yaml` for the public HTTP contract.

## Configuration

Copy `.env.example` to a local untracked environment file. Never commit credentials.

- `FIREWORKS_API_KEY`: server-only Fireworks API key for daily-entry generation
- `GROQ_API_KEY`: server-only Groq API key for audio transcription
- `LORE_GROQ_ZDR_VERIFIED`: must be exactly `true` only after Zero Data Retention is enabled and verified for the Groq organization/project handling Lore requests
- `LORE_PROVIDER_POLICY_VERSION`: owner-reviewed policy identifier; cannot be `unverified`
- `LORE_REMOTE_PROCESSING_ENABLED`: global fail-closed switch; must be exactly `true`
- `LORE_PREVIEW_BEARER_TOKEN`: preview/local synthetic testing only
- `LORE_APP_ATTEST_TEAM_ID`: Apple Team/App ID prefix (`6PP52WCRHS` for Lore)
- `LORE_APP_ATTEST_BUNDLE_ID`: `cascadianpines.lore`
- `LORE_APP_ATTEST_ENVIRONMENT`: `development` for the isolated physical-device Preview path; `production` for TestFlight/App Store
- `LORE_APP_ATTEST_ALLOWED_BUNDLE_VERSIONS`: comma-separated allowed `CFBundleVersion` values used by the iOS 27+ extension policy
- `LORE_APP_ATTEST_ALLOWED_VALIDATION_CATEGORIES`: comma-separated allowed iOS 27+ launch categories; use `3` for physical Development Preview and `2,4` for TestFlight plus App Store Production
- `LORE_SESSION_SIGNING_SECRET`: independent random secret of at least 32 characters
- `LORE_AUTH_STATE_HMAC_SECRET`: independent random secret of at least 32 characters for opaque references
- `LORE_AUTH_RECEIPT_ENCRYPTION_KEY`: independent 32-byte key encoded as standard base64
- `LORE_AUTH_DATABASE_URL`: Neon Postgres connection URL
- `LORE_APP_ATTEST_CHALLENGE_TTL_SECONDS`: optional 60–300 second challenge TTL; default 300
- `LORE_SESSION_TTL_SECONDS`: optional 60–900 second session TTL; default 600
- `LORE_PROCESSING_LEASE_TTL_SECONDS`: optional 60–300 second one-winner provider lease; default 90

Generate the Preview bearer with `openssl rand -hex 32`; use the same value in Vercel Preview and the Xcode Debug scheme, and leave it unset in Production. `LORE_PROVIDER_POLICY_VERSION` is a non-secret audit label such as `2026-08-03-direct-fireworks-groq-v1`, not a provider-supplied value.

Install Neon from Vercel Marketplace and apply `migrations/001_app_attest_auth.sql` followed by `migrations/002_processing_leases.sql`. Keep Preview and Production databases/namespaces isolated. Set provider keys, the Groq ZDR gate, the policy-version label, and auth secrets separately in every intended Vercel environment. Do not enable production content processing until a physical App Attest flow and a synthetic production canary pass.

Every production processing request must carry a bounded `Idempotency-Key`. Transcription requires that header to exactly match the validated multipart `idempotency_key`; daily entry requires `daily-entry:<job_id>`. After App Attest authorization and complete input validation, Lore HMACs the installation, task, and idempotency identity and atomically acquires a Neon lease before calling a provider. The table stores only the HMAC claim, an opaque lease token, and timestamps—never raw identifiers or user content. An active duplicate returns retryable `409 processing_in_progress` with `Retry-After`; an expired lease may be taken over. Release is token-conditional so a stale invocation cannot clear a newer lease. Preview bearer traffic remains explicitly test-only and bypasses durable claims.

The retention attestation returned by Lore records the policy configuration under which the request ran. It is not a provider-issued deletion receipt. Its zero-second value refers to persistent content retention, not the time plaintext exists in volatile inference memory. Request-ephemeral processing means Lore does not intentionally persist provider-bound audio, prompts, or outputs on the server. Groq's ZDR setting must prevent inference inputs and outputs from being retained for reliability or abuse monitoring; usage metadata may still be retained. Fireworks documents ZDR by default for open-model inference, but also documents default volatile prompt caching that can last from several minutes to several hours. A unique per-request isolation key prevents reuse across Lore requests; it does not delete cached plaintext. Do not enable remote Fireworks processing for real user text until that bounded volatile lifetime is explicitly accepted or Fireworks provides a cache-disabled route.

## Official API and data-policy references

- <https://docs.fireworks.ai/api-reference/post-chatcompletions>
- <https://docs.fireworks.ai/structured-responses/structured-response-formatting>
- <https://docs.fireworks.ai/guides/security_compliance/data_handling>
- <https://console.groq.com/docs/speech-to-text>
- <https://console.groq.com/docs/your-data>
