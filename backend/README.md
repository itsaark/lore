# Lore Processing API

Provider-neutral, request-ephemeral backend for Lore transcription and grounded daily-entry generation.

## Current provider topology

- Daily entries: direct Fireworks Chat Completions using `accounts/fireworks/models/gpt-oss-120b`
- Transcription: direct Groq Audio Transcriptions using `whisper-large-v3-turbo`
- No provider-side files, batch jobs, stored response objects, or extra routing layer

The public Lore request and response contracts remain provider-neutral. Provider names and exact model IDs are recorded only in processing provenance. The model aliases `daily-entry-v1` and `transcription-fallback-v1` are stable app-facing identifiers.

Daily-entry requests use Fireworks' stateless Chat Completions endpoint with strict JSON Schema output. The backend re-validates the complete output and rejects invented source or fact references. It does not use Fireworks Responses API storage or conversation state.

Transcription requests use Groq's synchronous Audio Transcriptions endpoint with `verbose_json` segment timestamps, temperature zero, an ISO-639-1 language hint when available, and a bounded vocabulary prompt. The backend never uses Groq Files or Batch APIs.

The iOS HTTPS client, durable transcription/daily-entry job orchestration, anonymous App Attest installation-session flow, and one-winner processing leases are implemented and covered by local mocked tests. Processing accepts only App Attest-backed sessions; there is no Preview bearer path. Live App Attest, Neon, and app-to-Vercel-to-provider canaries have not run.

## Deploy from GitHub

Import the Lore GitHub repository into Vercel and configure this service as an independently deployed monorepo application:

- Root directory: `backend`
- Framework preset: Other
- Node.js version: 24.x
- Production branch: `main`

The canonical `lore` project is connected to GitHub with `backend` as its root. Configure provider and authentication secrets only for Production. `vercel.json` enables Git deployment only for `main`, so Lore does not build or maintain a separate Preview backend.

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

Vercel Cron alone calls the server-only `GET /api/internal/security-metadata-cleanup` maintenance route. It is intentionally excluded from the public OpenAPI contract.

See `openapi.yaml` for the public HTTP contract.

## Configuration

Copy `.env.example` to a local untracked environment file. Never commit credentials.

- `FIREWORKS_API_KEY`: server-only Fireworks API key for daily-entry generation
- `GROQ_API_KEY`: server-only Groq API key for audio transcription
- `DATABASE_URL`: pooled Neon Postgres connection URL, injected automatically by the Vercel Marketplace integration
- `CRON_SECRET`: independent random secret of at least 32 characters used by Vercel Cron
- `LORE_SESSION_SIGNING_SECRET`: independent random secret of at least 32 characters
- `LORE_AUTH_STATE_HMAC_SECRET`: independent random secret of at least 32 characters for opaque database references
- `LORE_AUTH_RECEIPT_ENCRYPTION_KEY`: independent random 32-byte key encoded as base64

Those are the only seven Production variables, and all seven are secrets or contain credentials. Provider/model policy, Apple Team ID `6PP52WCRHS`, bundle ID `cascadianpines.lore`, Production App Attest categories, TTLs, and cleanup bounds are public source-controlled constants. Production routes are available whenever their provider key exists; there is no redundant remote-processing flag. Provider privacy approval is a release checklist decision, not a runtime environment switch.

Install one Production Neon database from Vercel Marketplace and apply migrations `001`, `002`, then `003` in filename order. Neon is not Lore's content store: it holds only App Attest public-key/counter state, one-time challenge hashes, content-free rate-limit buckets, and HMAC-pseudonymized processing leases. Serverless functions need this shared transactional state to prevent challenge, assertion, and paid-inference replay across instances. Audio, transcripts, prompts, generated text, names, and biography data are forbidden from the database.

Migration `003` installs a bounded cleanup function for expired challenges, rate-limit buckets, and processing leases. The hourly Vercel Cron invocation deletes at most 500 rows from each table using `FOR UPDATE SKIP LOCKED`; it never scans or deletes user content or App Attest key/receipt state. If any returned count reaches the limit, `may_have_more` signals that another bounded invocation may be useful. Do not send real user content until a physical App Attest flow and a synthetic production canary pass.

Every production processing request must carry a bounded `Idempotency-Key`. Transcription requires that header to exactly match the validated multipart `idempotency_key`; daily entry requires `daily-entry:<job_id>`. After App Attest authorization and complete input validation, Lore HMACs the installation, task, and idempotency identity and atomically acquires a Neon lease before calling a provider. The table stores only the HMAC claim, an opaque lease token, and timestamps—never raw identifiers or user content. An active duplicate returns retryable `409 processing_in_progress` with `Retry-After`; an expired lease may be taken over. Release is token-conditional so a stale invocation cannot clear a newer lease.

The retention attestation returned by Lore records the policy configuration under which the request ran. It is not a provider-issued deletion receipt. Its zero-second value refers to persistent content retention, not the time plaintext exists in volatile inference memory. Request-ephemeral processing means Lore does not intentionally persist provider-bound audio, prompts, or outputs on the server. Groq's ZDR setting must prevent inference inputs and outputs from being retained for reliability or abuse monitoring; usage metadata may still be retained. Fireworks documents ZDR by default for open-model inference, but also documents default volatile prompt caching that can last from several minutes to several hours. A unique per-request isolation key prevents reuse across Lore requests; it does not delete cached plaintext. Do not enable remote Fireworks processing for real user text until that bounded volatile lifetime is explicitly accepted or Fireworks provides a cache-disabled route.

## Official API and data-policy references

- <https://docs.fireworks.ai/api-reference/post-chatcompletions>
- <https://docs.fireworks.ai/structured-responses/structured-response-formatting>
- <https://docs.fireworks.ai/guides/security_compliance/data_handling>
- <https://console.groq.com/docs/speech-to-text>
- <https://console.groq.com/docs/your-data>
- <https://vercel.com/docs/cron-jobs>
