# Lore Remote Processing Delivery Plan

Last updated: 2026-08-03

Status: local implementation integrated and test-covered; live provider and production release gates remain open. No task in this document is complete merely because an interface or mock exists.

## Implementation Progress

As of 2026-08-03:

- `RP-P0` is implemented and unit-tested: the app commits the local `Story`, protected `AudioAsset`, and queued transcription `ProcessingJob` before opening a remote request.
- `RP-00` is implemented locally: TypeScript and Swift use explicit snake-case wire contracts, strict enums/schemas, stable aliases, retention fields, and cross-boundary fixture tests. Live deployment compatibility remains part of `RP-09`.
- `RP-01` is partial: the API foundation, health route, fail-closed configuration, and content-free logger are implemented and tested. The GitHub-connected `lore` Vercel project exists with `backend` as its root, but Production is behind the current branch.
- `RP-02` is implemented locally but not live-proven: iOS and backend now implement Production App Attest bootstrap/renewal, short installation sessions, content-free rate limits, encrypted receipts, atomic Neon challenge/counter state, one-winner processing leases, and bounded cleanup. Static bearer credentials do not exist. Apple capability/profile setup, real Neon concurrency, WAF, physical enrollment, and TestFlight evidence remain open.
- `RP-03` is implemented for foreground processing: iOS transcodes unsupported recordings to M4A, creates bounded deterministic chunks, uploads multipart binary sequentially, and assembles ordered text and segment provenance. Background transfer restoration and a streaming implementation that avoids retaining every prepared chunk in memory remain production-hardening work.
- `RP-04` is implemented behind the policy gate: the direct Groq adapter and real iOS HTTP/transcription client handle bounded multipart input, timestamped output, chunk provenance, errors, retries, and cancellation. A live ZDR-enabled synthetic canary remains required.
- `RP-05` is implemented behind the global remote switch and a source-controlled provider/model policy identifier: the direct Fireworks adapter, strict grounded result contract, iOS request path, and complete local result persistence are covered by mocked tests. Live synthetic verification and production cache-policy approval remain required.
- `RP-06` is implemented locally with an ephemeral, HTTPS-only iOS client, strict request/response validation, provider-neutral errors, idempotency, and no provider credentials in the app.
- `RP-07` is implemented locally: onboarding and Settings provide Device Only/Adaptive selection, revocable text and separate audio-upload consent, and routing enforces current network and cellular policy.
- `RP-08` is implemented for in-app/relaunch execution: durable jobs own leases, retry/backoff, cancellation, consent/network waiting, idempotent transcript commits, complete daily-entry commits, and commit-driven audio deletion. Background URLSession restoration remains release hardening.
- `RP-09` and `RP-10` remain open: live synthetic canaries, live App Attest/Neon evidence, deployment evidence, privacy review, and physical-device validation have not been completed.

No Fireworks or Groq credential or live user content has been sent. Processing routes remain fail-closed.

The canonical deployment is the GitHub-connected Vercel project `lore`, with `backend` as its root directory and `main` as its only deployment-enabled branch. Lore maintains no separate Preview backend, and provider/auth secrets are scoped only to Production.

## End Goal

Lore's remote path is complete when a user on an older or unvalidated iPhone can record a voice note and, after explicit consent:

1. Lore saves the audio locally before making a network request.
2. The app uploads the finalized recording or deterministic bounded chunks to an authenticated Lore API deployed on Vercel.
3. The Lore API sends each request directly to Groq Audio Transcriptions using a server-only key, with organization-level ZDR verified; neither Lore nor Groq creates a persistent audio object.
4. The app assembles and validates the batch transcription, commits an immutable raw transcript plus provenance locally, and then deletes the local audio.
5. The app sends the newest transcript version—not audio—to the Lore API.
6. The Lore API calls Fireworks Chat Completions directly with GPT-OSS 120B, which returns strict schema-constrained output for the source-grounded daily entry.
7. The app validates and stores the entry, source references, provider provenance, and remote-retention attestation locally.
8. If any required step fails, the source audio or transcript remains available locally for an explicit retry; Lore never silently loses the only source or changes a local job into an upload.

The iPhone remains the only durable archive. The normal MVP backend does not store audio, transcripts, prompts, generated prose, or biography context in a database, object store, queue, cache, analytics system, trace, or log.

## Definition of Done

The remote-processing milestone is complete only when all of the following are true:

- A production Vercel deployment serves the versioned transcription and daily-entry endpoints over TLS.
- Production endpoints reject missing, expired, malformed, or unauthorized credentials.
- No permanent Fireworks, Groq, or infrastructure secret exists in the iOS bundle, repository, client logs, or API response.
- The direct Fireworks route is proven to use open-model ZDR with no provider fallback; the controlling terms cover Lore consumers, transcripts, third-party mentions, and expected sensitive data; persistent storage and reusable prompt caches are disabled or bounded by an approved policy.
- Groq organization Data Controls enable ZDR, and the exact Audio Transcriptions endpoint and resolved Whisper model are verified as ZDR-eligible.
- The app enforces Device Only versus Adaptive behavior, separate audio-upload consent, and the cellular-data preference before opening a request.
- Long recordings are split into deterministic chunks whose complete multipart requests are at most 3.5 MB, with at most 3.25 MB of audio; audio is sent as multipart binary, not base64 JSON.
- A successful remote transcription creates one immutable `TranscriptArtifact`, a source `TranscriptVersion`, complete provider/chunk provenance, and no duplicate local records after retry.
- Local audio is deleted only after the transcript transaction succeeds. Failed, empty, interrupted, or invalid transcriptions retain the audio and create a retryable local job.
- Daily-entry output passes server-side and client-side schema validation, and every generated sentence has source references.
- The remote response includes a truthful retention-policy attestation; the app commits it to the local job/provenance record.
- Application logs, Vercel runtime logs, traces, analytics, and error responses contain no audio, transcript text, prompts, model output, names, vocabulary terms, authorization tokens, or provider keys.
- Backend unit/contract tests, iOS unit tests, failure-path tests, and a synthetic production canary all pass.
- A physical-device test verifies the Adaptive path on at least one older or explicitly remote-routed iPhone before release.
- A runbook explains deployment, key rotation, ZDR verification, rollback, incident response, and how to disable remote processing without shipping a new app.

## Fixed MVP Decisions

- Hosting: Vercel Functions using TypeScript and the Node.js runtime.
- Provider path: direct Fireworks Chat Completions for text; direct Groq Audio Transcriptions for speech, with no intermediary inference gateway.
- Remote retention class: synchronous `requestEphemeral` only.
- Server persistence: none for user content. Any rate-limit or idempotency store may contain only keyed hashes, timestamps, status codes, and expiry metadata.
- Transcription model alias: `transcription-fallback-v1` maps to Groq `whisper-large-v3-turbo` only after the account ZDR and Lore benchmark gates pass.
- Accuracy alias: `transcription-accuracy-v1` maps to Groq `whisper-large-v3` only when explicitly selected; it is never a silent fallback.
- Daily-entry alias: `daily-entry-v1` maps initially to Fireworks model `accounts/fireworks/models/gpt-oss-120b` with strict JSON Schema output.
- Audio transport: `multipart/form-data`, maximum 3.5 MB complete request and 3.25 MB audio part.
- Text transport: versioned JSON over HTTPS.
- Canonical storage: SwiftData and protected files on the iPhone.
- Failover: fail closed. An unapproved provider, missing ZDR attestation, invalid schema, or unavailable service never causes a silent provider change.

## Inputs Required From the Owner

These are external prerequisites, not tasks an implementation agent should guess:

- Vercel team/project ownership and the production domain.
- A Production Fireworks API key, plus approval of the verified ZDR, cache, DPA, region, and subprocessor configuration.
- A Groq API key for synthetic speech testing and confirmation that organization Data Controls have ZDR enabled for the selected Audio Transcriptions endpoint/models.
- Enable App Attest for `cascadianpines.lore` and generate Distribution profiles after the committed Production entitlement is reviewed.
- Provision one Production Neon store through Vercel Marketplace and apply migrations `001`, `002`, and `003` in filename order.
- The supported minimum iOS version and at least one physical older iPhone for the release test.
- Approval of final privacy copy before real user content is enabled.

Until those inputs exist, agents may complete local development and offline synthetic testing, but must report production tasks as blocked rather than complete.

## Immediate Execution Slice

The existing recording UI, audio engine, transcript models, route policies, and remote contracts are foundations to reuse. The immediate work is not a recording rebuild.

The local implementation slice through `RP-08` now exists. Execute the remaining release path in this order:

1. Merge the current branch so the GitHub-connected `lore` project deploys the current backend, install one Production Neon store, apply migrations `001`–`003`, and configure only Production provider/auth variables.
2. Enable App Attest for Lore, refresh Distribution signing, and prove enrollment plus session renewal from a physical iPhone through TestFlight.
3. Prove content-free processing leases and bounded cleanup under real Production database concurrency with synthetic data, then add Production WAF rules.
4. Run `RP-09` synthetic Groq and Fireworks canaries through the real TestFlight iOS HTTP client; capture schema, privacy, retry, cancellation, and no-content-log evidence.
5. Keep real-user processing disabled until those Production canaries and provider-policy approvals pass.
6. Harden background transfer restoration and long-recording memory behavior without changing the frozen public contract.
7. Complete `RP-10` physical-device transcription accuracy, latency, interruption, thermal, and deletion validation before enabling real user content.

## API Contract

### `GET /v1/health`

Returns service availability, API schema versions, and content-free model aliases. It never returns secrets, raw provider configuration, account details, or ZDR control values.

### `POST /v1/transcriptions`

Authenticated multipart fields:

- `audio`: one supported binary audio chunk
- `schema_version`
- `job_id`
- `idempotency_key`
- `chunk_id`, `chunk_index`, `chunk_count`
- `start_milliseconds`, `duration_milliseconds`
- `language_code`, when known
- `vocabulary_hints`, as a bounded JSON array
- `retention_mode=request_ephemeral`

This is the primary remote speech contract. The server rejects unsupported media, mismatched metadata, missing ordering fields, retention modes other than `request_ephemeral`, an unverified Groq ZDR/model mapping, and payloads above the configured limit before any provider call.

The response is a versioned `RemoteTranscriptionResponse` with transcript text, timestamped source segments, the Lore request ID, provider request ID when available, model alias and resolved model ID, processing time, and a retention attestation. It never echoes audio or vocabulary hints.

### `POST /v1/daily-entries`

Accepts the versioned `DailyEntryGenerationRequest` already represented in the iOS project. The server:

- bounds total input and the number/length of source segments
- treats transcript content as untrusted data, never as instructions
- uses the versioned journal prompt and strict JSON Schema output
- validates source references against the submitted segment/fact IDs
- rejects unsupported prompt/schema versions rather than silently adapting them
- returns the versioned `DailyEntryGenerationResponse`

### Errors

Every endpoint returns a stable code, retry classification, request ID, and safe user-facing message. Errors never return provider response bodies, prompts, transcript excerpts, stack traces, or secrets.

Required codes include:

- `unauthorized`
- `consent_required`
- `unsupported_schema`
- `invalid_request`
- `payload_too_large`
- `unsupported_audio`
- `provider_rate_limited`
- `provider_unavailable`
- `provider_policy_unverified`
- `invalid_provider_response`
- `empty_transcript`
- `request_cancelled`
- `internal_error`

## Task Dependency Order

```text
RP-P0 save before network ------------------------------+
                                                         |
RP-00 contracts                                          |
  -> RP-01 Vercel foundation
  -> RP-02 authentication and abuse controls
  -> RP-03 audio framing/transport ----> RP-04 Groq batch speech
  -> RP-05 Fireworks daily entries ----> RP-06 iOS live client
                                         -> RP-07 privacy/routing UI
                                         -> RP-08 durable jobs and complete commits <---+
                                              -> RP-09 automated end-to-end verification
                                                   -> RP-10 production deployment and release evidence
```

The dependency graph records the order used to build the local foundation. `RP-P0` and `RP-00` through `RP-08` now have local implementations. The active dependency edge is from the Git-connected Production deployment plus live App Attest/Neon/provider-policy evidence into `RP-09`, then TestFlight and physical-device evidence into `RP-10`.

## RP-P0 — Persist Remote Capture Before Processing

End goal: once the user stops recording, Lore can be terminated immediately without losing the local source or its retry state, even when the selected route is remote.

Requirements:

- Reuse the existing recording pipeline; do not redesign the recording UI or replace `AVAudioEngine` capture.
- On stop, finalize the audio file and transactionally insert the local `Story`, `AudioAsset`, and queued transcription `ProcessingJob` before calling any remote service.
- Store no empty `TranscriptArtifact` merely to represent pending work; create the immutable artifact only after a usable transcript exists.
- Move remote invocation out of the pre-persistence portion of `saveCurrentRecording()` and execute it from the durable job path.
- Ensure failure to create the local transaction prevents upload and retains the audio file for recovery.
- Ensure metadata enrichment remains optional and cannot block the source transaction.

Acceptance criteria:

- A test proves the `Story`, real `AudioAsset`, and queued job exist before the mock remote transcriber receives its first byte.
- Terminating or cancelling immediately before/during the remote call leaves a discoverable local audio asset and retryable job after relaunch.
- Failure to save the local transaction produces zero network requests and does not delete the file.
- A successful later transcription creates exactly one artifact/source version and only then deletes the audio.
- Existing local-transcription behavior and the minimal recording UI remain unchanged.

Verification evidence:

- Ordering test using a blocking/capturing remote transcriber.
- Relaunch recovery and file-existence assertions.
- XcodeBuildMCP build and full iOS test output.

## RP-00 — Freeze Contracts and Shared Fixtures

End goal: the backend and iOS app agree on one versioned wire format before either side implements live networking.

Requirements:

- Create a `backend/` TypeScript workspace with a committed lockfile, strict TypeScript settings, Zod schemas, and Vitest.
- Add OpenAPI documentation for health, transcription, daily-entry, and error responses.
- Represent snake-case wire fields explicitly; do not rely on accidental Swift or JavaScript encoder defaults.
- Add sanitized golden fixtures for successful and failed requests/responses.
- Update the Swift contracts if needed so JSON fields, nullability, enums, dates, segment IDs, and retention attestations match exactly.
- Remove binary audio from the JSON transcription contract; audio belongs only in multipart transport.
- Version prompt, API, request, response, and model-alias policy separately.

Acceptance criteria:

- TypeScript decodes every success fixture, re-encodes it, and passes schema validation.
- Swift decodes the same response fixtures and encodes requests accepted by the TypeScript schemas.
- Unknown enum values and unsupported major schema versions fail deterministically.
- No fixture contains a real person's story, credentials, or identifying metadata.

Verification evidence:

- Backend contract test output.
- iOS contract test output through XcodeBuildMCP.
- A table in the pull request listing every schema/version identifier.

## RP-01 — Build the Vercel Foundation

End goal: the Production Vercel deployment runs the API shell with validated configuration and content-free observability.

Requirements:

- Use supported Node.js Vercel Functions with explicit runtime and region configuration.
- Implement `/v1/health`, request IDs, timeouts, abort propagation, response security headers, and normalized errors.
- Validate environment variables at cold start without printing their values.
- Implement a logger with an allowlist of content-free fields. Logging arbitrary objects or provider errors is forbidden.
- Keep Production processing available whenever provider credentials are configured; emergency shutdown uses provider-key revocation or a deployment rollback without affecting the local app.
- Do not add a content-bearing database, Blob store, queue, analytics SDK, error-reporting SDK, or request-body capture. A transactional store is required only for the bounded, content-free security state defined in `app-attest-auth.md`.

Acceptance criteria:

- Production deployment health check passes.
- Missing configuration fails startup or returns `provider_policy_unverified`; it never silently uses a default provider.
- Tests prove the logger drops known sensitive field names and never serializes request bodies.
- A repository scan finds no committed secrets.

Verification evidence:

- Production deployment URL.
- Deployment command and output.
- Logger/redaction test output.
- Sanitized environment-variable inventory containing names only.

## RP-02 — Authentication, Rate Limits, and Content-Free Idempotency

End goal: only genuine Lore installations can invoke processing, and abuse controls do not create a shadow archive.

Requirements:

- Write an ADR for the production installation/session authentication flow.
- Recommended design: validate Apple App Attest during bootstrap, issue a short-lived signed Lore session token, and rotate/expire it without requiring a biography account.
- Production routes must not accept a shared secret embedded in the app.
- Processing routes accept only short-lived App Attest-backed sessions; shared or static bearer credentials are forbidden in every environment.
- Rate-limit by a keyed pseudonymous installation hash and route; never by transcript, name, or raw device identifier.
- If idempotency metadata is persisted, store only a keyed idempotency hash, task kind, timestamps, status class, and TTL. Never store input or output content.

Acceptance criteria:

- Missing, invalid, expired, wrong-environment, and replayed credentials are rejected.
- Valid sessions cannot invoke disabled task types or unsupported retention classes.
- Rate-limit tests return a stable retryable error and `Retry-After` value.
- A data inventory demonstrates that the auth/rate-limit path stores no story content.

Verification evidence:

- ADR and threat-model update.
- Automated auth/replay/rate-limit test output.
- Production-only authentication configuration test.

## RP-03 — Implement Bounded Audio Transport

End goal: a finalized local recording is encoded into deterministic requests that traverse Vercel's request limit without server-side file storage.

Requirements:

- Reuse the existing finalized `AudioAsset`; do not replace the capture UI or recording pipeline.
- Convert the finalized remote-bound recording to a Groq-supported format without blocking the capture UI.
- Apply bounded buffering and backpressure. A slow or disconnected upload must retain the finalized local source, not grow memory without limit.
- Transcode and split finalized recordings into ordered chunks with audio parts no larger than 3.25 MB and complete multipart bodies no larger than 3.5 MB.
- Preserve small overlap or another deterministic boundary strategy so words are not lost between chunks.
- Send multipart binary data with chunk ID, order, time range, language, and bounded vocabulary hints.
- Request `verbose_json` where supported, assemble returned segments locally, and retain per-segment time provenance.
- Cancel outstanding requests when the user cancels; never delete the source audio on cancellation.
- Remove or refactor the current base64-style `RemoteAudioPayload.bytes` JSON path.

Acceptance criteria:

- A long synthetic recording remains memory-bounded and produces one correctly ordered final transcript.
- Every multipart body remains below 3.5 MB.
- A missing, duplicated, or out-of-order chunk is detected and cannot produce a committed transcript.
- Network interruption leaves the original audio and a retryable local job.
- No temporary chunk survives past completion/cancellation beyond the local recovery policy.

Verification evidence:

- Unit tests for transcoding/backpressure, chunk boundaries, and overlap assembly.
- Integration test recording sizes, buffer bounds, and resulting request sizes.
- File-system assertion showing successful cleanup and failure retention.

## RP-04 — Implement Groq Batch Transcription

End goal: an authenticated older or remote-routed iPhone uploads a finalized recording, and Lore returns a validated Groq transcript without any persistent server-side audio object.

Requirements:

- Use the implemented direct Groq client for the official Audio Transcriptions endpoint; remove or reject any path that attempts speech inference through another provider.
- Keep `GROQ_API_KEY` server-only. Never return it, bundle it, log it, or expose it through health/config responses.
- Verify and record organization-level ZDR before the route can make a provider request. The route must make zero provider requests while that gate is false.
- Map `transcription-fallback-v1` to `whisper-large-v3-turbo`; allow `whisper-large-v3` only through the explicit accuracy alias.
- Use direct file upload and request `verbose_json` segments when supported. Preserve timestamped segment evidence needed by `TranscriptArtifact`.
- Define timeout, cancellation, app-background, response-loss, and network-switch behavior. Never represent an incomplete or empty response as a successful transcript.
- Map authentication, rate limit, timeout, provider unavailability, invalid events, and empty final output into Lore's provider-neutral error codes.
- Include provider/model/request provenance without exposing credentials or raw provider errors.
- Keep the multipart route fail-closed until the Groq model mapping, ZDR policy version, consent, and request bounds are all verified.

Acceptance criteria:

- Mock-provider tests cover policy rejection, model allowlisting, cancellation, malformed responses, 429, 5xx, timeout, and empty-final behavior.
- A synthetic post-stop test returns a non-empty timestamped transcript within the measured end-to-end latency budget.
- Account evidence proves Groq ZDR was enabled during the test and the exact endpoint/models were eligible.
- The permanent provider key is absent from the built iOS app, responses, source, logs, and test artifacts.
- No audio or transcript content is written by Lore's backend, and no provider-side content object exists to delete after the synchronous request closes.
- Lore's recorded p50/p95 upload-plus-transcription latency, word/name/date accuracy, retry success rate, and error rate meet the release thresholds defined in `RP-09`.

Verification evidence:

- Mock and physical-device test output.
- Sanitized live-integration result containing IDs, timings, model, audio duration, and text length only.
- Account-policy screenshot or provider confirmation showing ZDR; no API key or console secret belongs in the repository.

## RP-05 — Implement Grounded Daily-Entry Generation

End goal: the Vercel daily-entry endpoint turns a transcript into faithful structured prose that can be traced back to source segments.

Requirements:

- Use the versioned prompt and `daily-entry-v1` alias mapped to `accounts/fireworks/models/gpt-oss-120b`.
- Call Fireworks Chat Completions directly with model `accounts/fireworks/models/gpt-oss-120b` and no provider/model fallback.
- Request strict JSON Schema output with every field required and `additionalProperties:false` on every object; validate the returned object server-side.
- Keep transcript and prior facts inside clearly delimited untrusted-data sections.
- Validate that every title/sentence/fact reference exists in the request.
- Preserve uncertainty and reject unsupported claims rather than repairing them with invented source IDs.
- Bound input segments, prior facts, target words, output size, reasoning effort, timeouts, and retries.
- Store no prompt, transcript, prior fact, or output on the server.

Acceptance criteria:

- Golden tests cover names, dates, uncertainty, corrections, prompt injection, ordinary days, and sensitive content.
- Invalid source references fail validation and are never returned as a successful entry.
- The same idempotency key can be retried without creating duplicate local prose after RP-08 integration.
- A synthetic direct Fireworks test returns schema-valid output with sentence-level sources and records the resolved Fireworks model plus approved data-policy version.

Verification evidence:

- Schema and prompt-injection test output.
- Sanitized live-integration metrics with no content.
- Prompt version and model-alias version recorded in the response fixture.

## RP-06 — Connect the iOS App to the Live Lore API

End goal: dependency injection selects a real Lore HTTP client for Groq-backed transcription and Fireworks-backed daily entries in configured builds, and fail-closed clients otherwise.

Requirements:

- Implement a URLSession-based `LoreBackendProcessingClient` for health, multipart transcription, and daily-entry routes.
- Configure the source-controlled Production base URL and pinned schema versions without embedding provider credentials.
- Apply request timeouts, cancellation, TLS-only transport, safe error mapping, and bounded response decoding.
- Inject the live HTTP client into `SpeechRecognitionViewModel`; remove production reliance on the unconfigured defaults when remote processing is enabled.
- Keep unconfigured and mock clients available for SwiftUI previews and tests; they never authenticate to a live backend.
- Never log request bodies, response bodies, transcript excerpts, vocabulary entries, authorization headers, or raw server errors.

Acceptance criteria:

- A TestFlight build reaches Production health, completes a synthetic multipart transcription, and reaches the daily-entry route.
- An unconfigured build still fails closed and preserves audio.
- Cancellation propagates to URLSession requests and retains the finalized local source.
- Oversized or unsupported responses fail before excessive allocation or local commit.
- Provider credentials are absent from the built app strings and repository scan.

Verification evidence:

- URLProtocol-based client tests.
- XcodeBuildMCP build/test output.
- Production synthetic-canary request IDs and local persistence assertions.

## RP-07 — Enforce Privacy, Consent, and Network Routing

End goal: remote processing is impossible unless user policy explicitly permits the exact transfer.

Requirements:

- Add persistent Device Only and Adaptive modes.
- Present a one-time Adaptive processing disclosure during onboarding before the first remote-capable use, and make the choice revocable in Settings.
- Obtain separate, explicit consent before the first audio upload. Text-processing consent does not imply audio consent.
- Explain that remote text passes transiently through Lore's Vercel service and Fireworks, while remote audio passes transiently through Lore's Vercel service and Groq after the user consents.
- Enforce the existing cellular-data preference using actual network path state.
- Show the selected route before capture begins on devices that are remote-first.
- Never silently upload after a local task has already failed.
- Add a remote kill-switch policy that makes jobs deferred/retryable without deleting their source.

Acceptance criteria:

- Device Only produces zero network requests in transcription and generation tests.
- Adaptive without audio consent records locally and defers transcription without uploading.
- Cellular-disabled mode produces zero uploads on a simulated cellular path.
- Revoking consent affects future jobs and leaves existing local content readable.
- Consent text and version are stored locally without storing story content remotely.

Verification evidence:

- Routing matrix tests covering privacy mode, consent, device class, network type, and local failure.
- Simulator screenshots/accessibility snapshots of consent and deferred states.

## RP-08 — Complete Durable Jobs, Commits, and Deletion Semantics

End goal: app termination, retry, or duplicate responses cannot lose a source or create duplicate transcript/biography records.

Requirements:

- Make `ProcessingJob` the workflow source of truth and stop using `Story.processingStatus` for decisions.
- Implement job dependencies, leasing, retry schedules, cancellation, relaunch resumption, and terminal failure.
- Use stable idempotency keys derived from task kind, story ID, and input transcript revision.
- Commit transcript artifact, source version, provenance, retention attestation, and job state in one local transaction before deleting audio.
- Commit daily entry, sentence provenance, memory candidates, provider provenance, and job state transactionally.
- Ignore stale generation results when a newer transcript version exists.
- Keep audio after any empty, invalid, interrupted, unacknowledged, or failed transcript result.
- Propagate user deletion to pending jobs and derived records without requiring the server to hold a biography copy.

Acceptance criteria:

- Terminating the app during upload, provider inference, response delivery, local commit, and audio deletion recovers correctly after relaunch.
- Replaying the same response creates no duplicate artifacts, versions, fragments, or facts.
- A correction made during generation causes the stale result to be rejected and a new revision job to be eligible.
- Audio deletion occurs only after a verified non-empty transcript transaction.
- Completed remote jobs contain provider/model/request IDs and retention-attestation timestamps but no copied prompt or audio.

Verification evidence:

- Deterministic interruption and replay tests.
- SwiftData assertions before and after every simulated crash point.
- XcodeBuildMCP test results.

## RP-09 — Add Automated End-to-End and Privacy Verification

End goal: one guarded command verifies the normal path and dangerous failure paths against Production using synthetic content, including direct Fireworks text and direct Groq speech.

Requirements:

- Add backend unit, contract, adapter, security, and log-redaction suites.
- Add iOS contract, client, routing, persistence, retry, cancellation, and deletion suites.
- Add a synthetic audio fixture with no real personal data.
- Add a guarded Production synthetic E2E test: TestFlight remote-routed device -> Vercel -> provider -> local transcript -> daily entry -> local commit -> audio deletion.
- Add guarded live canaries using production-shaped Fireworks and Groq settings with synthetic content only.
- Scan source, built app strings, logs, and test artifacts for seeded canary phrases and secrets.
- Test 401, 413, 429, timeout, provider 5xx, malformed JSON, invalid source IDs, empty transcript, cancellation, and response loss.

Acceptance criteria:

- All normal and failure-path suites pass from a clean checkout.
- The Groq canary meets the transcription WER, proper-name/date/number, silence, missing-tail, 99-of-100 reliability, five-second p95, and cost gates in `inference-strategy.md` on the documented corpus/network profile.
- The Fireworks evaluation meets the schema, provenance, unsupported-claim, correction, contradiction, prose-preference, latency, and cost gates in `inference-strategy.md`.
- Seeded transcript and prompt canaries do not appear in Vercel logs or retained backend artifacts after the documented observation window.
- Secrets scanning passes for repository and built iOS artifact.
- The live canary produces a local transcript and sourced entry, then confirms no remote content store exists to clean up.

Verification evidence:

- Test commands, versions, totals, and reports.
- Content-free canary report with request IDs and timestamps.
- Redacted Vercel log review and secret-scan output.

## RP-10 — Deploy, Exercise, and Approve Production

End goal: the production path is deployed, reversible, documented, and verified on real hardware before user content is permitted.

Requirements:

- Provision production Vercel configuration with dedicated Fireworks and Groq keys scoped as narrowly as each provider permits.
- Verify Fireworks ZDR, cache policy, residency, DPA scope, and disabled persistence features for production; separately verify Groq organization-level ZDR for the exact Audio Transcriptions endpoint and model aliases.
- Configure the API domain, Production-only environment, rate limits, alerts, and key-rotation procedure.
- Run the synthetic production canary.
- Test an explicitly remote-routed physical iPhone through transcription and daily-entry generation.
- Inspect local artifacts/provenance and confirm successful audio deletion.
- Inspect Vercel logs and any configured drains for canary content.
- Review privacy copy against the actual processors and behavior.
- Document rollback and provider-disable procedures.

Acceptance criteria:

- Production health and both processing endpoints pass synthetic canaries.
- The physical-device test completes the full End Goal without manual database repair or console intervention.
- Disabling remote processing causes the app to retain/defer work safely.
- No content appears in production logs, traces, analytics, or error reports.
- Owner and engineering sign off on the release-gate checklist.

Verification evidence:

- Production deployment identifier and domain.
- Content-free physical-device test report.
- ZDR/configuration review date and reviewer.
- Signed release checklist and rollback drill result.

## Agent Completion Report Template

Every agent assigned one of these tasks must return:

1. **Outcome:** one sentence stating whether the task's end goal is achieved.
2. **Acceptance criteria:** each criterion marked pass, fail, or blocked with evidence.
3. **Changes:** files and infrastructure changed.
4. **Verification:** exact commands/tools, test totals, deployment URLs or IDs, and relevant content-free request IDs.
5. **Security/privacy check:** confirmation that no story content or secret entered logs, fixtures, commits, or responses.
6. **Remaining risks:** unresolved issues and who must decide them.
7. **Dependency handoff:** the contract or artifact the next task can rely on.

An agent must use **blocked**, not **complete**, when a required production credential, owner decision, physical device, deployment, or live verification is unavailable.

## Source Constraints to Recheck at Release

- [Vercel Functions payload limit guidance](https://vercel.com/kb/guide/how-to-bypass-vercel-body-size-limit-serverless-functions)
- [Vercel Runtime Logs and retention](https://vercel.com/docs/logs/runtime)
- [Fireworks zero-data-retention policy](https://docs.fireworks.ai/guides/security_compliance/data_handling)
- [Fireworks prompt caching](https://docs.fireworks.ai/guides/prompt-caching)
- [Fireworks GPT-OSS 120B](https://app.fireworks.ai/models/fireworks/gpt-oss-120b)
- [Fireworks Chat Completions](https://docs.fireworks.ai/api-reference/post-chatcompletions)
- [Fireworks structured outputs](https://docs.fireworks.ai/structured-responses/structured-response-formatting)
- [Fireworks U.S.-only serverless](https://docs.fireworks.ai/serverless/us-only-serverless)
- [Fireworks DPA](https://fireworks.ai/dpa)
- [Groq speech-to-text](https://console.groq.com/docs/speech-to-text)
- [Groq Audio Transcriptions API](https://console.groq.com/docs/api-reference#audio-transcriptions)
- [Groq data controls and ZDR](https://console.groq.com/docs/your-data)
- [Apple: establishing app integrity with App Attest](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity)
- [Apple: validating apps that connect to your server](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server)
- [Apple: attestation object validation guide](https://developer.apple.com/documentation/devicecheck/attestation-object-validation-guide)
- [Apple WWDC26: Secure your apps with App Attest](https://developer.apple.com/videos/play/wwdc2026/201/)
- [Vercel Marketplace storage](https://vercel.com/docs/marketplace-storage)
- [Vercel Postgres integrations](https://vercel.com/docs/postgres)
