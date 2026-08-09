# Lore Architecture

Last updated: 2026-08-05

## System statement

Lore is a voice-first iPhone journal with remote inference and a private CloudKit-backed canonical archive. The iOS app records and protects audio, submits bounded synchronous processing requests, validates responses, stores source and derived artifacts with provenance, syncs recoverable records through the user's private iCloud database, and deletes captured audio only after the source transcript is durable.

The backend is a request-ephemeral security and provider boundary. Groq performs transcription. Fireworks produces grounded daily entries. Neon stores content-free authentication and replay-protection state only; it is not a journal database.

## Non-negotiable boundaries

- User audio, transcripts, prompts, generated prose, names, and biography facts are never written to Lore's server database or logs.
- SwiftData's local cache and the user's private CloudKit database are the durable stores for the personal archive.
- Audio files, audio paths, and processing jobs remain device-local and never sync to another phone.
- Provider keys exist only in Vercel Production.
- Feature code depends on provider-neutral contracts and stable aliases.
- One onboarding permission covers the current remote transcription and journal-writing pipeline.
- The app exposes no compute mode, device capability tier, cellular routing switch, or downloadable inference model.
- Audio deletion is commit-driven: a successful network response alone is insufficient.
- A failed or interrupted request remains a durable, recoverable `ProcessingJob`.

## End-to-end data flow

```text
User speaks
  -> iOS writes a protected temporary audio file
  -> iOS creates a local story and transcription ProcessingJob
  -> App Attest authorizes a short-lived Lore session
  -> Lore API validates auth, input, size, and idempotency
  -> Groq returns a synchronous transcript with segments
  -> Lore API validates and returns the provider-neutral result
  -> iOS atomically stores transcript artifact + version + provenance
  -> iOS deletes the captured audio file
  -> iOS creates/runs a daily-entry ProcessingJob
  -> Lore API sends the bounded transcript package to Fireworks
  -> Lore API validates the structured, source-grounded result
  -> iOS stores the complete result and biography fragment locally
```

If transcription cannot finish, the protected audio remains available for retry. If daily-entry generation cannot finish, the transcript remains usable and the derived job retries independently.

## iOS application

### Navigation

The current shell has three primary destinations:

| View | Responsibility |
| --- | --- |
| Record | Minimal capture, audio-level feedback, and current processing state |
| Journal | Read privately synced daily entries and their source relationships |
| Biography | Read the evolving assembled narrative |

Settings currently owns vocabulary, writing style, shortcuts, and About. Processing infrastructure is deliberately not presented as a user-tunable mode.

### Persistence model

SwiftData owns the canonical archive. User-authored and derived records use a private CloudKit configuration; device-bound operational records use a separate local-only configuration:

- `Story`: one capture and its user-visible lifecycle;
- `TranscriptArtifact`: stable source identity for a story;
- `TranscriptVersion`: immutable transcript content and provenance;
- `ProcessingJob`: durable orchestration state, attempt count, retry time, cancellation, and execution metadata;
- `DailyEntryResultArtifact`: the complete validated response snapshot;
- `BiographyFragment`: locally accepted derived prose tied to source facts;
- vocabulary and profile records.

`AudioAsset`, `ProcessingJob`, and `DailyBiographyGenerationSnapshot` remain in the device-local store because another phone cannot access the originating sandbox audio file. Existing single-store installs are copied into the split stores by an idempotent migration that retains the legacy store as a recovery copy.

Legacy profile fields related to earlier processing experiments remain in the schema only to migrate existing installs. They do not drive behavior or appear in the UI.

### Capture and transcription

`SpeechRecognitionViewModel` coordinates the capture lifecycle. It records to an app-private protected file, persists a remote transcription job, and uses `LoreBackendRemoteSpeechTranscriber`. `SpeechTranscriptionPolicy` has only two outcomes: remote when permission and connectivity are available, or deferred otherwise.

The transcript commit transaction must install the artifact, immutable version, story status, provenance, and job success together. Only after that save succeeds may the capture file be deleted. Missing, empty, malformed, or mismatched results fail the job and preserve the recording.

### Daily-entry orchestration

`DailyEntryJobRunner` treats journal generation as a durable job. It builds a bounded request from a committed transcript, uses a deterministic idempotency key, handles retry scheduling and restart recovery, and delegates installation to `DailyEntryResultPersistence`.

The complete remote result is persisted, including title, prose, source/fact references, model alias, model identifier, policy version, prompt/schema versions, request identity, and retention attestation. The UI never treats only title and prose as sufficient provenance.

### Authentication

Physical-device builds use App Attest to establish an anonymous installation key and obtain short-lived scoped sessions. Provider secrets never ship in the app. The Simulator cannot produce App Attest credentials and therefore cannot call Production processing routes.

If App Attest is unsupported or enrollment fails, recording can remain available, but processing is deferred because there is no insecure fallback credential embedded in the client.

## Lore Processing API

The backend is deployed from `backend/` as its own Vercel project and exposes:

- `GET /v1/health`
- `POST /v1/auth/challenges`
- `POST /v1/auth/attestations`
- `POST /v1/auth/sessions`
- `POST /v1/transcriptions`
- `POST /v1/daily-entries`

Each processing request is synchronous, size-bounded, schema-validated, authorized, rate-limited, and idempotency-scoped. The backend uses an ephemeral HTTP transport and allowlisted content-free logs. It does not create provider files, batches, stored responses, conversations, or background content jobs.

### Provider adapters

| Capability | Current provider | Stable alias | Current model |
| --- | --- | --- | --- |
| Speech transcription | Groq | `transcription-fallback-v1` | `whisper-large-v3-turbo` |
| Daily-entry writing | Fireworks | `daily-entry-v1` | `accounts/fireworks/models/deepseek-v4-flash` |

Exact provider IDs remain server-controlled. iOS stores them as provenance but routes against the stable Lore contract.

### Neon boundary

Serverless invocations cannot safely coordinate App Attest counters, single-use challenges, rate limits, or duplicate paid requests using process memory. Neon supplies transactional shared state for:

- HMAC-pseudonymized installation/key references;
- verified public keys, encrypted Apple receipts, and assertion counters;
- one-time challenge hashes and expiry/consumption state;
- content-free rate-limit buckets; and
- HMAC-pseudonymized expiring processing leases.

The schema forbids user content. Cleanup removes expired challenges, buckets, and leases in bounded batches. Neon can later be replaced by another transactional store without changing the iOS processing contracts.

## Retention semantics

Lore's API holds request content only for the lifetime of the synchronous invocation and does not intentionally persist it. A zero-second retention attestation means zero intentional persistent content retention; it is not a claim that all plaintext vanishes instantly from volatile provider memory.

Production release gates require:

- verified Groq ZDR for the selected transcription route;
- Fireworks open-model ZDR acceptance;
- explicit acceptance or mitigation of Fireworks' documented volatile prompt-cache window;
- no content fields in Lore logs, traces, database rows, or error reports; and
- a physical-device synthetic canary proving the complete flow.

## Failure and retry model

`ProcessingJob` is the source of truth for work state:

- `pending`: durable but not running;
- `running`: an attempt owns the job;
- `waitingForNetwork`: no usable connection;
- `retryScheduled`: transient failure with bounded backoff;
- `failed`: user action or a later retry is required;
- `cancelled`: no further automatic execution;
- `succeeded`: a validated result was committed.

The app recovers unfinished jobs on launch. Backend processing leases provide one-winner behavior for concurrent duplicates, while iOS installation remains idempotent by job and artifact identity.

## Current implementation snapshot

### Implemented foundations

- three-tab SwiftUI shell plus minimal recording surface;
- local Story, transcript artifact/version, processing job, daily-entry result, and biography-fragment models;
- protected audio capture and commit-driven deletion;
- provider-neutral remote contracts and real iOS HTTP clients;
- Groq and Fireworks adapters with strict response validation;
- App Attest client/server flow and short-lived sessions;
- Neon migrations for auth state, leases, and cleanup;
- retry/restart orchestration for daily-entry jobs;
- complete daily-entry result persistence;
- one remote-processing permission and no mode/settings UI;
- mocked iOS and backend test coverage.

### Partially proven

- physical-device App Attest enrollment against the Production deployment;
- real Neon migrations and transactional behavior in Production;
- provider privacy configuration and live provider canaries;
- interruption/retry/cancellation UX on a physical phone;
- transcript correction and biography assembly user flows.

### Production-capable only after gates pass

Remote processing is not considered production-ready until all secrets exist, migrations are applied, Groq ZDR is verified, Fireworks retention behavior is approved, App Attest succeeds on a signed physical build, synthetic content completes both provider routes, and logs/database contents pass the no-user-content audit.

## Immediate next tasks

1. Apply all Neon migrations to the Production database.
2. Verify the seven Production secrets and the `/v1/health` response.
3. Enable and validate the App Attest capability for the Lore App ID.
4. Run a signed physical-device synthetic transcription and journal-generation test.
5. Exercise offline capture, app termination, retry, cancellation, and duplicate submission.
6. Inspect Vercel logs and Neon rows to prove they contain no user content.
7. Finish transcript correction and journal/biography reading polish.
