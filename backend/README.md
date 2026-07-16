# Lore Processing API

Provider-neutral, request-ephemeral backend for Lore transcription and grounded daily-entry generation.

## Current status

- Vercel Functions scaffold and health endpoint
- strict versioned Zod contracts
- bounded multipart transcription endpoint
- grounded daily-entry endpoint
- direct Groq Whisper and GPT-OSS adapters
- strict JSON Schema provider output
- source-reference validation
- preview-only bearer authentication
- fail-closed ZDR/provider configuration
- content-free operational logging
- mocked provider and route tests

Production authentication, iOS networking, durable job orchestration, and live Groq/Vercel verification remain incomplete. Preview bearer authentication is deliberately rejected when `VERCEL_ENV=production`.

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

- `GROQ_API_KEY`: server-only Groq key
- `LORE_GROQ_ZDR_VERIFIED`: must be exactly `true`
- `LORE_PROVIDER_POLICY_VERSION`: owner-reviewed policy identifier
- `LORE_REMOTE_PROCESSING_ENABLED`: must be exactly `true`
- `LORE_PREVIEW_BEARER_TOKEN`: preview/local synthetic testing only

Groq does not return a per-request ZDR flag or deletion receipt. The Lore retention attestation states which reviewed deployment policy handled the request; it is not represented as a provider-issued receipt.

Set `GROQ_API_KEY`, `LORE_GROQ_ZDR_VERIFIED`, `LORE_PROVIDER_POLICY_VERSION`, and `LORE_REMOTE_PROCESSING_ENABLED` separately for each intended Vercel environment. `LORE_PREVIEW_BEARER_TOKEN` belongs only in Preview/local environments. Production content processing must remain disabled until production installation/session authentication replaces the preview bearer.
