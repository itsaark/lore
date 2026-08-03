# Lore Processing API

Provider-neutral, request-ephemeral backend for Lore transcription and grounded daily-entry generation.

## Current provider topology

- Daily entries: direct Fireworks Chat Completions using `accounts/fireworks/models/gpt-oss-120b`
- Transcription: direct Groq Audio Transcriptions using `whisper-large-v3-turbo`
- No provider-side files, batch jobs, stored response objects, or extra routing layer

The public Lore request and response contracts remain provider-neutral. Provider names and exact model IDs are recorded only in processing provenance. The model aliases `daily-entry-v1` and `transcription-fallback-v1` are stable app-facing identifiers.

Daily-entry requests use Fireworks' stateless Chat Completions endpoint with strict JSON Schema output. The backend re-validates the complete output and rejects invented source or fact references. It does not use Fireworks Responses API storage or conversation state.

Transcription requests use Groq's synchronous Audio Transcriptions endpoint with `verbose_json` segment timestamps, temperature zero, an ISO-639-1 language hint when available, and a bounded vocabulary prompt. The backend never uses Groq Files or Batch APIs.

The iOS HTTPS client and durable transcription/daily-entry job orchestration are implemented and covered by local mocked tests. Live app-to-Vercel-to-provider canaries have not run. Production authentication remains incomplete, and Preview bearer authentication is deliberately rejected when `VERCEL_ENV=production`.

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
- `POST /v1/transcriptions`
- `POST /v1/daily-entries`

See `openapi.yaml` for the public HTTP contract.

## Configuration

Copy `.env.example` to a local untracked environment file. Never commit credentials.

- `FIREWORKS_API_KEY`: server-only Fireworks API key for daily-entry generation
- `GROQ_API_KEY`: server-only Groq API key for audio transcription
- `LORE_FIREWORKS_DATA_POLICY_VERIFIED`: must be exactly `true` only after Fireworks' applicable data policy is reviewed for the intended Lore environment
- `LORE_GROQ_ZDR_VERIFIED`: must be exactly `true` only after Zero Data Retention is enabled and verified for the Groq organization/project handling Lore requests
- `LORE_PROVIDER_POLICY_VERSION`: owner-reviewed policy identifier; cannot be `unverified`
- `LORE_REMOTE_PROCESSING_ENABLED`: global fail-closed switch; must be exactly `true`
- `LORE_PREVIEW_BEARER_TOKEN`: preview/local synthetic testing only

Set both provider keys and policy gates separately in every intended Vercel environment. Do not enable production content processing until production installation/session authentication replaces the preview bearer.

The retention attestation returned by Lore records the policy configuration under which the request ran. It is not a provider-issued deletion receipt. Its zero-second value refers to persistent content retention, not the time plaintext exists in volatile inference memory. Request-ephemeral processing means Lore does not intentionally persist provider-bound audio, prompts, or outputs on the server. Groq's ZDR setting must prevent inference inputs and outputs from being retained for reliability or abuse monitoring; usage metadata may still be retained. Fireworks' open-model inference policy and any prompt-cache behavior must remain covered by the reviewed policy version. A unique prompt-cache isolation key prevents reuse across Lore requests, but it does not delete the volatile cache; do not enable the Fireworks policy gate until that lifetime is accepted or a cache-disabled route is available.

## Official API and data-policy references

- <https://docs.fireworks.ai/api-reference/post-chatcompletions>
- <https://docs.fireworks.ai/structured-responses/structured-response-formatting>
- <https://docs.fireworks.ai/guides/security_compliance/data_handling>
- <https://console.groq.com/docs/speech-to-text>
- <https://console.groq.com/docs/your-data>
