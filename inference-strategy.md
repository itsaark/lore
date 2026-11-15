# Lore Inference Strategy

Last updated: 2026-11-15

## Decision

Lore uses one remote inference pipeline for voice notes captured in the primary iPhone app or the companion Apple Watch app:

- on-device Fluid Speech Mini (FluidAudio) for English speech-to-text once its model is downloaded, with Groq `whisper-large-v3-turbo` as the fallback and for every other language;
- Fireworks `accounts/fireworks/models/glm-5p3` (GLM 5.3) for grounded daily-entry writing, with `accounts/fireworks/models/gpt-oss-120b` as an automatic fallback;
- Fireworks `accounts/fireworks/models/gpt-oss-120b` for Reflect's live questions, where latency matters most;
- Lore's Vercel API as the only credential, validation, privacy, and provider boundary.

The Watch does not call the pipeline directly; it transfers a protected recording to the paired iPhone, which becomes the processing coordinator. Capture device and hardware generation do not influence routing. Wi-Fi and cellular are both eligible after iPhone import. When Watch transfer, network access, or authorization is unavailable, work remains deferred in a durable, retryable state.

## Why this is the MVP

One pipeline makes transcription quality, latency, cost, privacy review, support, and failure behavior measurable. It also lets older phones deliver the same result as current hardware. The app has no model management, capability benchmark, mode picker, or alternate quality tier.

## Transcription

### Provider contract

The iPhone app submits one bounded recorded file to `POST /v1/transcriptions`, whether the file was captured locally or durably imported from the paired Apple Watch. The Lore API validates authentication, MIME type, byte size, duration metadata, locale, vocabulary, idempotency, and processing purpose before calling Groq's synchronous Audio Transcriptions endpoint.

The provider request uses:

- `whisper-large-v3-turbo`;
- `verbose_json` response format;
- segment timestamps;
- temperature `0`;
- a language hint when a valid ISO-639-1 code is available; and
- a bounded vocabulary prompt.

The Lore API converts the provider response into a versioned provider-neutral result and rejects empty or malformed transcripts.

### Audio lifecycle

The capture device writes the recording to protected app storage first. For an Apple Watch capture, the Watch retains its file until the iPhone acknowledges that it has durably imported the recording and created the corresponding Story/job. The iPhone then retains its processing copy through transient failures. After the transcript artifact, version, provenance, and successful job state are committed atomically, the iPhone deletes that copy. These two acknowledgement boundaries are required even when transfer or the upstream request appears to have succeeded.

The backend does not use Groq Files, Batch, or stored objects. Production use requires Groq ZDR to be verified for the selected organization, endpoint, and model.

## Daily-entry generation

The app submits a bounded source package to `POST /v1/daily-entries` only after a transcript version is durable. The package contains the transcript, allowed style preferences, vocabulary, and source identifiers required to ground the result.

Fireworks Chat Completions uses strict JSON Schema output. The Lore API re-validates the full response, including source and fact references, before returning it. iOS persists the complete artifact and provenance rather than extracting only prose.

### Writer and prompt (2026-11-15)

- **Prompt:** `grounded-journal-v2`, the biographer voice described in `narrative-voice-plan.md`. It keeps every v1 faithfulness rule and adds craft rules: open on something concrete, use the telling detail, quote the person's own words, and understate. Scene detail may come only from what the person said. The backend still answers `grounded-journal-v1` requests from older builds with the v1 prompt.
- **Writer:** GLM 5.3 ($1.40 / $4.40 per million input / output tokens on Fireworks serverless, about $0.01 per entry). At the time of the switch it was the best-scoring cheap open model on EQ-Bench Creative Writing v3, ranked by third-party trackers. The founder chose it on benchmark before Model Lab scores existed, because there were no users yet. The founder's policy is to stay on cheap open models.
- **Fallback:** if GLM errors, returns an unusable answer, or takes longer than 30 seconds, the request is retried once on GPT-OSS 120B with the same prompt. Rate limits, cancellation, and credential failures are not retried. Provenance records whichever model wrote the entry.
- **Evaluation:** writers and prompts are compared only in the DEBUG Model Lab (Settings → Developer → Model Lab → Compare journal writers). The Lab calls `POST /v1/lab/daily-entries`, which admits only development App Attest keys.

The prompt must:

- preserve the user's facts and uncertainty;
- avoid invented names, dates, motives, dialogue, or events;
- create a concise journal entry rather than advice or analysis;
- follow the requested perspective and style;
- return only the declared structured schema; and
- reference only source and fact IDs present in the request; and
- in v2, write in a narrative biographer's voice without adding any detail the person didn't say.

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

- Every connected, consented iPhone uses the remote route for both iPhone-originated and Watch-originated captures.
- Apple Watch captures are duplicate-safe and remain recoverable until durable iPhone import is acknowledged.
- Offline devices create or retain recoverable work without data loss.
- Provider credentials never appear in the app bundle or repository.
- A transcription response is not enough to delete audio; the local commit must succeed first.
- Daily-entry output is rejected if it is incomplete, malformed, or references unknown sources.
- Duplicate requests do not intentionally trigger duplicate provider work.
- Logs, traces, and Neon contain no audio, transcript, prompt, or generated prose.
- The user sees one permission during onboarding, not routing controls throughout the product.
