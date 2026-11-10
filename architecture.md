# Lore Architecture

Last updated: 2026-09-04

## System statement

Lore is a voice-first Apple-platform journal with remote inference and a private CloudKit-backed canonical archive. The iPhone app is the primary experience and processing coordinator. A companion Apple Watch app launches with it as a secondary capture surface, transferring protected voice notes to the paired iPhone so both sources enter the same transcript, journal, and biography pipeline.

The iPhone app records or imports protected audio, submits bounded synchronous processing requests, validates responses, stores source and derived artifacts with provenance, syncs recoverable records through the user's private iCloud database, and deletes captured audio only after the source transcript is durable.

The backend is a request-ephemeral security and provider boundary. Groq performs transcription. Fireworks produces grounded daily entries. Neon stores content-free authentication and replay-protection state only; it is not a journal database.

## Non-negotiable boundaries

- User audio, transcripts, prompts, generated prose, names, and biography facts are never written to Lore's server database or logs.
- SwiftData's local cache and the user's private CloudKit database are the durable stores for the personal archive.
- Raw audio never enters CloudKit. Apple Watch audio may move only through the paired-device capture handoff; after import, audio paths and processing jobs remain local to the iPhone that accepted the capture and never sync to another phone.
- The Apple Watch is a companion input surface, not a second canonical archive, and it does not call Lore's Processing API or inference providers directly.
- Provider keys exist only in Vercel Production.
- Feature code depends on provider-neutral contracts and stable aliases.
- One onboarding permission covers the current remote transcription and journal-writing pipeline.
- The app exposes no compute mode, device capability tier, cellular routing switch, or downloadable inference model.
- Audio deletion is commit-driven: a successful network response alone is insufficient.
- A failed or interrupted request remains a durable, recoverable `ProcessingJob`.

## End-to-end data flow

```text
User speaks on iPhone
  -> iOS writes a protected temporary audio file
or
User speaks on Apple Watch
  -> watchOS writes a protected pending audio file
  -> watchOS transfers audio + capture metadata to the paired iPhone
  -> iOS durably imports the capture and acknowledges receipt
  -> watchOS removes its pending copy only after that acknowledgement
then
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

## Apple client applications

### iPhone application

#### Navigation

The current shell has three primary destinations:

| View | Responsibility |
| --- | --- |
| Record | Minimal capture, audio-level feedback, and current processing state |
| Journal | Read privately synced daily entries and their source relationships |
| Biography | Read the evolving assembled narrative |

Settings currently owns vocabulary, writing style, shortcuts, and About. Processing infrastructure is deliberately not presented as a user-tunable mode.

#### Persistence model

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

#### Capture and transcription

`SpeechRecognitionViewModel` coordinates the iPhone capture lifecycle. It records to an app-private protected file, persists a remote transcription job, and uses `LoreBackendRemoteSpeechTranscriber`. A Watch import enters this lifecycle at the durable local-file and Story/job creation boundary. `SpeechTranscriptionPolicy` has only two outcomes: remote when permission and connectivity are available, or deferred otherwise.

The transcript commit transaction must install the artifact, immutable version, story status, provenance, and job success together. Only after that save succeeds may the capture file be deleted. Missing, empty, malformed, or mismatched results fail the job and preserve the recording.

Every Story records whether its capture originated on iPhone or Apple Watch, plus an opaque capture identifier used for duplicate-safe Watch imports. Capture source is provenance, not a quality tier or routing choice.

#### Daily-entry orchestration

`DailyEntryJobRunner` treats journal generation as a durable job. It builds a bounded request from a committed transcript, uses a deterministic idempotency key, handles retry scheduling and restart recovery, and delegates installation to `DailyEntryResultPersistence`.

The complete remote result is persisted, including title, prose, source/fact references, model alias, model identifier, policy version, prompt/schema versions, request identity, and retention attestation. The UI never treats only title and prose as sufficient provenance.

#### Biography memory and chapter assembly

Status: planned. This section defines the target design for chapters and the full biography.

The biography is built from a layered memory held entirely in the SwiftData archive and synced through the private CloudKit configuration with `.allowsCloudEncryption` on content fields. No layer is stored in Neon or any Lore server database. Each generation call is a bounded, request-ephemeral package assembled on the iPhone, exactly like daily-entry generation.

Lore does not use learned latent memory (for example memory-token modules) or retrieval-ranked context to write the biography. Both lose exact names and dates or hide which source supported a sentence, and the biography must stay traceable to recordings. Chapters are bounded by life period, so their inputs are selected deterministically by time and entity rather than by similarity search.

##### Memory layers

| Layer | Records | Role |
| --- | --- | --- |
| 1. Source | `TranscriptArtifact`, `TranscriptVersion` | Ground truth. Every higher layer cites it and can be rebuilt from it. |
| 2. Facts | `BioEntity`, `BioFact` | Atomic, citable claims and the people, places, and organisations they mention. |
| 3. Representations | `EntityProfile`, `PeriodSummary` | Consolidated pages per entity and per month that make chapter inputs small. |
| 4. Narrative | `BiographyOutline`, `ChapterVersion` | User-facing prose, versioned and fully cited. |
| Always-loaded | `NarratorProfile` | A small summary of the narrator, writing style, and outline sent with every biography request. |

The always-loaded layer stays small (target under 1,500 tokens). Detail lives in the lower layers and is pulled in per request.

##### Proposed SwiftData models

All models below live in the private CloudKit configuration. Content fields use `.allowsCloudEncryption`.

- `BioEntity`: `id`, `kind` (person, place, organisation, pet, other), `canonicalName`, `aliases` (for example "Mom", "Linda"), `relationshipToNarrator`, `status` (extracted, userConfirmed, userCorrected, merged), `mergedIntoEntityId`, `createdAt`, `updatedAt`.
- `BioFact`: `id`, `statement` (one atomic claim), `sourceQuote` (the verbatim transcript span that supports it), `sourceTranscriptVersionId`, `sourceSegmentRange`, `entityIds`, `occurredStart`, `occurredEnd`, `datePrecision` (day, month, season, year, decade, unknown), `placeEntityId`, `status` (extracted, userConfirmed, userCorrected, retracted), `supersedesFactId`, `extractionJobId`, `createdAt`.
- `EntityProfile`: one page per entity, with `entityId`, `summary`, `citedFactIds`, `inputFactSetHash`, `isStale`, `version`.
- `PeriodSummary`: one per calendar month that has entries, with `periodStart`, `periodEnd`, `summary`, `citedFactIds`, `inputFingerprint`, `isStale`, `version`.
- `BiographyOutline`: the ordered chapter plan, with each chapter's title, period range, theme, and key entities. It is user-editable.
- `ChapterVersion`: immutable, with `chapterId`, `revision`, `prose`, `citedFactIds`, `inputPeriodSummaryVersionIds`, `inputEntityProfileVersions`, `narratorProfileVersion`, model and prompt/schema versions, `createdAt`. It follows the `TranscriptVersion` pattern, so a regenerated chapter never overwrites an earlier version.
- `NarratorProfile`: narrator name, preferred perspective and tone, birth year if given, a short life overview, and the outline summary.

Facts are partitioned by entity and period, so each fact belongs to exactly one source span. Generation steps write separate records rather than editing one shared document. This prevents concurrent jobs from overwriting each other's facts.

##### Pipeline

1. **Fact extraction** runs inside or immediately after the daily-entry job. The structured result gains `facts[]` and `entityMentions[]`. Each fact carries a verbatim `sourceQuote`, and the API rejects any fact whose quote is not a substring of the submitted transcript.
2. **Entity resolution** runs on device. A new mention is matched to existing entities by canonical name and aliases. Ambiguous matches are left as separate entities and queued for consolidation or user confirmation. They are never silently merged.
3. **Representation refresh** happens when the inputs change. A new or changed fact marks its `PeriodSummary` and `EntityProfile` records stale. A `ProcessingJob` rebuilds each stale record from its facts, using the same idempotency, retry, and lease rules as daily entries.
4. **Chapter generation** runs when the user requests it or when a chapter's inputs have materially changed. The iPhone assembles a package containing the `NarratorProfile`, the chapter's outline entry, its `PeriodSummary` texts, the relevant `EntityProfile` texts, and the cited `BioFact` statements and quotes. User-confirmed and user-corrected facts are listed first. The response schema requires each paragraph to list the fact IDs it relies on. The API rejects any cited fact ID that was not in the package and any proper noun that does not appear in the supplied entities or facts. A rejected result is retried and never installed.
5. **Whole-biography assembly** concatenates chapters in outline order. Short transitions between chapters are generated separately, using only the two neighbouring chapters' summaries. There is no single whole-life generation call.

##### Consolidation ("dreaming")

A periodic background `ProcessingJob` reviews recent changes against source transcripts. It runs on charge or Wi-Fi with a modest cadence and is triggered by accumulated changes rather than a fixed timer. Its jobs are to:

- propose merges of duplicate entities ("Linda" and "Mom");
- flag facts that contradict each other or a newer user correction;
- re-date facts as more specific evidence arrives (for example "the 80s" becoming "1987");
- mark summaries and chapters stale when their cited facts change; and
- detect bloat, meaning a summary that is not shorter than its inputs.

Consolidation proposes. It does not overwrite user-confirmed or user-corrected records, and destructive merges require user confirmation. Every change is a new version or status transition with a pointer to the evidence.

##### User corrections

A correction in a transcript, entity, or chapter is written as a `userCorrected` fact or entity status that supersedes the original. This marks every dependent representation and chapter stale, so the fix flows into all later writing. Corrections are the highest-authority input in every request.

##### Local search

Interactive follow-up ("tell me more about Dad's shop") uses on-device SQLite FTS over transcripts and facts, plus entity lookup. On-device embeddings (`NLContextualEmbedding`) may be added only if keyword and entity search measurably miss relevant material. Search indexes are derived, device-local, and rebuildable, and are never uploaded.

##### Quality gates

Before chapters ship, a synthetic multi-year corpus must show:

- no invented proper nouns or dates in generated chapters;
- every paragraph resolves to at least one source quote;
- a user correction propagates to all affected chapters after refresh; and
- the cost and latency per chapter fit the modeled budget.

#### Authentication

Physical iPhone builds use App Attest to establish an anonymous installation key and obtain short-lived scoped sessions. Provider secrets never ship in either app. The Watch does not obtain a Lore processing session; its paired iPhone authorizes processing after durable import. The iOS Simulator cannot produce App Attest credentials and therefore cannot call Production processing routes.

If App Attest is unsupported or enrollment fails, recording can remain available, but processing is deferred because there is no insecure fallback credential embedded in the client.

### Apple Watch companion

The watchOS app is intentionally narrow: start and stop a voice note, protect the recording locally, show its transfer state, and retry delivery to the paired iPhone. It uses WatchConnectivity-backed application transfer so a note can be captured while the phone is temporarily unreachable and delivered later.

The handoff is acknowledgement-driven. The Watch retains its pending file until the iPhone has copied it into protected storage and durably created the corresponding Story and transfer/import state. Replayed transfers use the same capture identifier and must resolve to the same Story rather than create duplicates. The iPhone then owns processing and retains its imported copy until transcript commit succeeds.

The launch version does not put transcript correction, journal or biography reading, archive deletion, provider authentication, or remote processing on the Watch. Those responsibilities stay in the primary iPhone app.

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

The iPhone app recovers unfinished processing jobs on launch, and the Watch retries unacknowledged transfers after relaunch or reconnection. Backend processing leases provide one-winner behavior for concurrent duplicates, while Watch import and iOS result installation remain idempotent by capture, job, and artifact identity.

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

### Planned for the joint iPhone and Apple Watch launch

- companion watchOS app target and shared capture contract;
- protected Watch recording and visible pending/transfer states;
- acknowledgement-driven, duplicate-safe transfer to the paired iPhone;
- capture-source provenance in the shared Story pipeline; and
- physical-device coverage for offline capture, delayed delivery, interruption, relaunch, and re-pairing edge cases.

### Production-capable only after gates pass

Remote processing is not considered production-ready until all secrets exist, migrations are applied, Groq ZDR is verified, Fireworks retention behavior is approved, App Attest succeeds on a signed physical build, synthetic content completes both provider routes, and logs/database contents pass the no-user-content audit.

## Immediate next tasks

1. Apply all Neon migrations to the Production database.
2. Verify the seven Production secrets and the `/v1/health` response.
3. Enable and validate the App Attest capability for the Lore App ID.
4. Run a signed physical-device synthetic transcription and journal-generation test.
5. Exercise offline capture, app termination, retry, cancellation, and duplicate submission.
6. Inspect Vercel logs and Neon rows to prove they contain no user content.
7. Add the companion watchOS capture target and duplicate-safe iPhone import path.
8. Validate offline Watch capture, delayed transfer, acknowledgement, relaunch recovery, and audio deletion on physical paired devices.
9. Finish transcript correction and journal/biography reading polish.
10. Add fact extraction to the daily-entry schema and the `BioEntity`/`BioFact` models (see Biography memory and chapter assembly).
11. Build monthly `PeriodSummary` refresh and entity profiles, then chapter generation against the synthetic multi-year corpus.
