# Lore Inference Strategy

Last updated: 2026-08-04

## Decision

Lore currently uses one remote inference pipeline for every supported iPhone:

- Groq `whisper-large-v3-turbo` for speech-to-text;
- Fireworks `accounts/fireworks/models/deepseek-v4-flash` for grounded daily-entry writing;
- Lore's Vercel API as the only credential, validation, privacy, and provider boundary.

Hardware generation does not influence routing. Wi-Fi and cellular are both eligible. When the network or authorization is unavailable, work is deferred as a durable job.

## Why this is the MVP

One pipeline makes transcription quality, latency, cost, privacy review, support, and failure behavior measurable. It also lets older phones deliver the same result as current hardware. The app has no model management, capability benchmark, mode picker, or alternate quality tier.

## Transcription

### Provider contract

The app submits one bounded recorded file to `POST /v1/transcriptions`. The Lore API validates authentication, MIME type, byte size, duration metadata, locale, vocabulary, idempotency, and processing purpose before calling Groq's synchronous Audio Transcriptions endpoint.

The provider request uses:

- `whisper-large-v3-turbo`;
- `verbose_json` response format;
- segment timestamps;
- temperature `0`;
- a language hint when a valid ISO-639-1 code is available; and
- a bounded vocabulary prompt.

The Lore API converts the provider response into a versioned provider-neutral result and rejects empty or malformed transcripts.

### Audio lifecycle

The iPhone writes the recording to protected app storage before upload. It retains that file through transient failures. After the transcript artifact, version, provenance, and successful job state are committed atomically, the app deletes the recording. This ordering is required even when the upstream request succeeded.

The backend does not use Groq Files, Batch, or stored objects. Production use requires Groq ZDR to be verified for the selected organization, endpoint, and model.

## Daily-entry generation

The app submits a bounded source package to `POST /v1/daily-entries` only after a transcript version is durable. The package contains the transcript, allowed style preferences, vocabulary, and source identifiers required to ground the result.

Fireworks Chat Completions uses strict JSON Schema output. The Lore API re-validates the full response, including source and fact references, before returning it. iOS persists the complete artifact and provenance rather than extracting only prose.

The prompt must:

- preserve the user's facts and uncertainty;
- avoid invented names, dates, motives, dialogue, or events;
- create a concise journal entry rather than advice or analysis;
- follow the requested perspective and style;
- return only the declared structured schema; and
- reference only source and fact IDs present in the request.

## Privacy and retention

Lore does not intentionally persist request content on its backend. Server logs use an allowlist of content-free operational fields. Neon contains only authentication, replay-protection, rate-limit, and processing-lease metadata.

Provider release requirements:

| Provider | Required state | Important limitation |
| --- | --- | --- |
| Groq | Organization ZDR verified for Audio Transcriptions | Usage metadata may still be retained under Groq policy |
| Fireworks | Open-model ZDR behavior approved | Documented prompt/KV cache may remain in volatile memory after the response |

Lore may describe the backend as request-ephemeral and zero persistent content retention after these gates are met. It must not promise mathematically instantaneous erasure from volatile provider memory without a provider guarantee.

## Cost and latency controls

- Keep recordings and request bodies bounded.
- Use synchronous endpoints; do not create provider files or background jobs.
- Send only the transcript context needed for the current entry.
- Use deterministic idempotency keys and Neon leases to prevent duplicate paid inference.
- Retry transient errors with bounded backoff; never retry validation or permission failures automatically.
- Record provider/model aliases, latency, and usage metadata without recording content.
- Review model quality and pricing behind the stable Lore aliases before changing production models.

## Provider replacement

Provider adapters are replaceable server-side. A provider or model change must pass:

1. transcript accuracy on Lore's multilingual, names, dates, noisy-room, and long-note evaluation set;
2. grounded-writing review with no unsupported facts;
3. p50/p95 latency and error-rate targets;
4. modeled cost per recorded hour and per journal entry;
5. documented retention and training controls;
6. strict schema compatibility; and
7. synthetic end-to-end canaries through the Lore API.

The iOS app should not require a release solely because the backend swaps the exact provider model behind an unchanged, compatible alias and policy version.

## Acceptance criteria

- Every connected, consented physical device selects the remote route.
- Offline devices create or retain recoverable work without data loss.
- Provider credentials never appear in the app bundle or repository.
- A transcription response is not enough to delete audio; the local commit must succeed first.
- Daily-entry output is rejected if it is incomplete, malformed, or references unknown sources.
- Duplicate requests do not intentionally trigger duplicate provider work.
- Logs, traces, and Neon contain no audio, transcript, prompt, or generated prose.
- The user sees one permission during onboarding, not routing controls throughout the product.
