# Lore Architecture

Last updated: 2026-07-16

## System Goal

Lore is a local-first, voice-first journal and biography system with adaptive compute. The iPhone contains the canonical durable transcript archive and every accepted derived view. Work may execute on-device or on ephemeral remote infrastructure, depending on user privacy settings, device capability, task complexity, connectivity, and runtime conditions.

The execution location must not change the product data model. Capture, processing, validation, persistence, provenance, and biography assembly use stable interfaces so local models, gateways, hosted models, and later self-hosted inference remain replaceable.

## Architectural Principles

- **Save before processing.** A source story is durably committed locally before any AI job begins.
- **Local is canonical.** Ordinary remote processing does not create a second durable biography store.
- **Local-first is not local-only.** Less capable devices receive the same core product through privacy-conscious remote compute.
- **User policy is a hard boundary.** Device Only mode never uses a server. Adaptive mode never silently uploads a story after a local attempt fails.
- **Minimize every request.** Send text instead of audio when possible and only the context required for one task.
- **Separate evidence from narrative.** Source stories and user corrections ground a memory graph; generated prose is a replaceable view.
- **Preserve uncertainty and disagreement.** Approximate dates and conflicting accounts remain explicit.
- **Provenance survives model changes.** Every derived fact and passage links to source stories and records how it was produced.
- **Provider details stay behind ports.** Feature code does not depend directly on MLX, Vercel AI Gateway, or a model vendor.
- **Offline capture always works.** Connectivity may delay processing but must not block recording or reading the archive.
- **Privacy claims are testable system properties.** Retention, log redaction, provider settings, and deletion acknowledgements require verification.

## Trust Boundaries

### On the iPhone

Durable by default:

- user profile and preferences
- stories, immutable raw transcripts, and corrected transcript versions until user deletion
- corrections and provenance
- memory graph and temporal relationships
- biography fragments, chapters, and timelines
- processing job state and remote deletion receipts

Temporary:

- audio files under the local retention policy
- local model caches, prompts, and intermediate results

### Lore processing backend

The backend is a task orchestrator, not the user's archive. It authenticates the app, enforces privacy and retention policy, selects an allowed model route, sends the minimum required payload, validates the response, and returns the result. Normal synchronous inference is request-ephemeral on a verified zero-data-retention route. Content is persisted only when an asynchronous job or undelivered result requires recovery, and then only encrypted under a hard TTL.

### Model router and inference provider

Lore's backend owns provider adapters and may call an approved inference provider directly or through a gateway. Direct Groq is the leading MVP candidate for hosted Whisper transcription and GPT-OSS text generation; Fireworks is the leading text fallback. Vercel AI Gateway remains an optional text-routing tool rather than an architectural requirement and should be bypassed for MVP transcription because it does not expose the preferred Groq route and adds another processor.

The selected upstream model may be open-weight and hosted by a third party. "Open-weight" does not by itself establish license suitability or privacy; the exact model license, host, gateway, endpoint, feature configuration, and provider route must all be approved. Every intermediary is a separate data processor with separate logging and retention behavior.

Later, the same backend can route to self-hosted inference without changing the iOS feature interfaces or stored biography format.

## End-to-End Pipeline

```text
Record audio
  -> commit local audio asset and capture metadata
  -> transcribe on-device when supported
       OR enqueue consented ephemeral remote transcription
  -> commit immutable raw transcript + transcription provenance locally
  -> create corrected/canonical transcript version when the user edits
  -> delete audio after a usable transcript is safely committed
       OR retain locally in a visible short-lived retry state
  -> create durable local processing job(s)
  -> ComputeRouter selects local or remote execution under user policy
  -> extract source-grounded memory candidates
  -> validate and merge candidates into the local memory graph
  -> retrieve relevant prior memories and source summaries
  -> write or revise biography fragments
  -> validate provenance and commit results locally
  -> acknowledge remote delivery and purge remote working data
  -> update timeline, chapters, people, places, and themes
```

Extraction and prose generation are separate jobs. Each can use a different execution route and can retry independently. A generation failure never invalidates the saved story or successful transcription.

## Launch Navigation and Responsibilities

The initial app shell has three top-level destinations:

| Surface | Primary responsibility | Explicitly deferred |
| --- | --- | --- |
| Notes | Provide a minimal, focused start/stop recording surface and communicate capture state without visual clutter | Transcript lists, graph browsing, and long-form composition |
| Biography | Show short daily narrative entries and provide access to their raw transcript sources | Full chapter editor, people/place/theme explorers |
| Settings | Privacy and network modes, audio fallback consent, writing perspective/style, retention, export/delete, optional local models | General-purpose assistant configuration |

Capture must remain one tap away and must not wait for model initialization or network reachability. Notes stays focused on capture; Biography is a derived, revisable surface that also provides access to source material.

## Privacy Modes and Routing Constraints

```swift
enum PrivacyMode {
    case deviceOnly
    case adaptive
}

enum ExecutionRoute {
    case local
    case remote
    case deferred(reason: DeferralReason)
}
```

`ComputeRouter` evaluates, in order:

1. User privacy mode and per-feature permissions.
2. Whether the payload includes text, audio, or sensitive metadata.
3. Task requirements: modality, context length, structured-output support, and quality floor.
4. Local readiness: membership in a remotely configurable device allowlist, OS support, model installed, measured memory headroom, storage, language support, and predicted latency. The initial local speech and biography-processing floor is marketed iPhone 17-class hardware (`iPhone18,*` identifiers and above).
5. Runtime state: thermal pressure, Low Power Mode, battery, foreground/background budget, and current memory pressure.
6. Network policy: offline state, Wi-Fi/cellular permission, expected transfer size, and remote service health.
7. Model policy: allowed providers, regional requirements, retention guarantees, and current availability.

The router returns a decision plus a user-readable reason. For speech, earlier, unknown, or unvalidated devices select remote transcription before recording begins when consent and network policy permit it. A device model may establish eligibility, but local routing still requires measured/runtime checks. A remote route must fail closed when its provider policy is unknown or incompatible.

Adaptive mode can select a remote route before work begins under the user's standing text/audio and network permissions. If the selected local route begins and then fails, the job becomes retryable; the router may not silently change it to remote. Uploading that story requires a visible, explicit retry action. Device Only jobs can only retry locally or remain deferred.

Suggested task preferences:

| Task | Preferred route | Allowed fallback |
| --- | --- | --- |
| Speech transcription | Local on validated newer devices; remote on older or unvalidated devices | Deferred when the selected route is not permitted |
| Entity/event extraction | Local when reliable | Remote with minimized transcript/context |
| Biography prose | Local Bonsai on validated iPhone 17-class and newer hardware; remote on earlier or unknown devices | Deferred or smaller local model |
| Chapter reconciliation | Remote for large context initially | Local when a capable model is installed |
| Search and graph traversal | Local | No remote requirement |
| Follow-up question selection | Local rules/graph first | Remote generation when permitted |

## Core iOS Modules

### CaptureService

- Starts and stops audio recording.
- Writes audio to protected local file storage.
- Emits levels for recording UI.
- Creates `AudioAsset` records with creation and expiry dates.
- Recovers finalized recordings after interruption when possible.

### TranscriptionService

A provider-neutral boundary:

```swift
protocol TranscriptionService {
    func transcribe(_ input: TranscriptionInput, route: ExecutionRoute) async throws -> TranscriptionResult
}
```

Implementations:

- `AppleOnDeviceTranscriptionService`
- possible future local speech-model service
- `RemoteTranscriptionService`

On-device recognition remains preferred. Remote transcription receives audio only for that task and only when privacy settings permit it.

### StoryStore

SwiftData-backed persistence boundary. It commits source stories before processing, exposes capture and life chronology queries, applies user corrections, and coordinates deletion propagation.

### MetadataService

Captures date, timezone, location, and WeatherKit snapshots with permission. Remote requests should omit precise location unless the task needs it; a human-readable place from the transcript is usually sufficient.

### ProcessingJobStore

Persists the state machine for every task so work survives app restarts:

```text
captured -> ready -> routing -> runningLocal | uploading | runningRemote
         -> validating -> committing -> completed
         -> deferred | retryableFailure | permanentFailure | cancelled
```

Each job includes:

- stable local job ID and idempotency key
- story ID, task kind, input revision, and dependency IDs
- selected route and reason
- attempt count, timestamps, and retry eligibility
- model/provider metadata without prompt content in logs
- remote request ID, result-delivery state, and deletion status when applicable

Retrying the same idempotency key must not create duplicate graph facts or fragments. A new user edit increments the input revision and supersedes stale results.

### ComputeRouter

Applies privacy and capability policy to a processing job. The router is deterministic for a supplied capability snapshot and returns a reason suitable for diagnostics and user disclosure.

### DeviceCapabilityService

Reports observed capabilities instead of relying only on phone generation:

- available memory and storage headroom
- model availability and load success history
- thermal and power state
- supported speech languages and on-device availability
- task-specific benchmark/latency class
- current network policy and reachability

Capability data should be coarse and remain local unless aggregate, consented telemetry is introduced later.

### LocalModelManager

Owns optional downloadable MLX model lifecycle: storage validation, download integrity, load/unload, cancellation, removal, and memory-pressure response. It exposes capabilities rather than selecting product behavior itself.

Initial 1.7B, 4B, and 8B Ternary Bonsai support is existing experimental infrastructure, not a promise that every tier works on every device. Larger models, including 27B-class models, require physical-device validation and should not gate the core experience.

### GenerationService

Single app-facing boundary for model work:

```swift
protocol GenerationService {
    func writeBiographyProse(_ request: BiographyRequest, route: ExecutionRoute) async throws -> BiographyResult
    func extractMemories(_ request: ExtractionRequest, route: ExecutionRoute) async throws -> ExtractionResult
    func reconcileBiography(_ request: ReconciliationRequest, route: ExecutionRoute) async throws -> ReconciliationResult
    func generatePrompt(_ request: PromptRequest, route: ExecutionRoute) async throws -> PromptResult
}
```

Local and remote implementations return the same versioned, structured result types. Feature code never calls MLX, a gateway SDK, or provider API directly.

### MemoryGraphService

- Parses versioned structured extraction results.
- Creates or merges people, places, themes, events, relationships, and facts.
- Preserves temporal uncertainty, contradiction, confidence, and source spans.
- Makes merge actions reversible.
- Retrieves source-bounded context for biography revision.
- Removes or marks provenance when a source is deleted.

### BiographyEngine

- Creates and revises fragments from graph evidence.
- Maintains event chronology separately from capture chronology.
- Reconciles passages affected by new facts or corrections.
- Assembles chapter, relationship, place, theme, and timeline views.
- Requires supporting source IDs for factual generated passages.

### RetentionService

Owns local cleanup and coordinates deletion semantics:

- deletes audio promptly after a usable transcript and provenance are durably committed
- retains failed or unprocessed audio locally in a visible recovery state for no more than 7 days by default
- keeps raw transcripts and corrected transcript versions locally until explicit user deletion
- applies cascading or provenance-aware cleanup after user deletion
- removes expired local prompt and result caches
- tracks remote deletion acknowledgements and surfaces exceptions

Local cleanup must delete content, not merely store an expiry date.

## Remote Processing Architecture

The iOS app must call a Lore-owned API, not embed gateway or inference-provider credentials.

```text
iPhone
  -> authenticated Lore Processing API
       -> policy + retention guard
       -> prompt/context builder
       -> ModelGateway port
            -> approved direct provider adapter (Groq initially)
            -> approved fallback adapter (Fireworks candidate)
            -> optional text gateway adapter
            -> self-hosted inference later
       -> schema/safety validation
       -> request-ephemeral result delivery
  -> local commit and delivery acknowledgement
  -> server purge + deletion receipt
```

The request-ephemeral MVP interfaces should include:

- `POST /v1/transcriptions` as a bounded `multipart/form-data` audio request
- `POST /v1/daily-entries` as a versioned JSON request
- `GET /v1/health` with no content or provider details

Both processing endpoints require a pseudonymous authenticated session, an idempotency key, an explicit `requestEphemeral` retention policy, and versioned response schemas. They return the result synchronously and persist no request or result content. The app's durable local `ProcessingJob` remains the recovery and retry record.

If asynchronous recovery is introduced later, the backend may add:

- `POST /v1/jobs` with an idempotency key and explicit task/retention policy
- `GET /v1/jobs/{id}` for resumable status/result delivery
- `DELETE /v1/jobs/{id}` for cancellation and early deletion
- `POST /v1/jobs/{id}/ack` after the result is durably committed locally

Exact endpoints may change, but the semantics should remain stable.

### Vercel MVP transport constraints

The first Lore backend is planned as TypeScript Vercel Functions using the Node.js runtime and direct Groq adapters. Vercel AI Gateway is not on the MVP data path.

Vercel currently documents a 4.5 MB function request/response body limit. Groq accepts direct speech attachments up to 25 MB and larger files by URL, but using a provider URL would require a separate temporary object store and weaken the request-ephemeral design. Therefore:

- the app must encode speech efficiently and split long recordings into independently transcribable chunks
- each complete multipart request must remain at or below 3.5 MB; Lore currently reserves 3.25 MB for the audio part and the remainder for form overhead
- audio bytes must not be base64-encoded inside the JSON contract
- the backend must stream or forward each bounded part without writing it to durable disk, object storage, a queue, or a database
- transcript segments must retain stable chunk/time identifiers so the app can assemble them deterministically and preserve provenance
- a later dedicated upload service is an architectural change requiring a new retention review

Relevant platform references are [Vercel's function payload guidance](https://vercel.com/kb/guide/how-to-bypass-vercel-body-size-limit-serverless-functions), [Groq speech file limits](https://console.groq.com/docs/speech-to-text), and [Groq data controls](https://console.groq.com/docs/your-data). These constraints must be rechecked before production release.

### Repository and deployment topology

Lore uses one GitHub monorepo with independently deployable applications:

- the iOS application and its tests remain the primary client
- `backend/` is imported into Vercel as a standalone API project
- a future `web/` directory will contain the public landing page and later account-management UI, imported as a second Vercel project

The API and website may share versioned, content-free contract code in the future, but they must not share runtime environment variables or deployment lifecycles. The API owns provider secrets and processing endpoints. The website owns public pages and authenticated account UI, and calls the API through its public authenticated contract.

Using one repository keeps cross-client contract changes and privacy reviews atomic. Using separate Vercel projects preserves independent domains, previews, rollbacks, scaling, access controls, and secret scopes. Splitting into multiple repositories is deferred until team ownership, release cadence, or security boundaries make that separation materially useful.

### Remote request envelope

A request contains only:

- pseudonymous installation/session credential
- job ID, task kind, schema version, locale, and input revision
- minimized transcript or audio payload
- the smallest relevant context package, using source IDs meaningful only on-device
- selected retention class and absolute expiry timestamp
- required output schema and model capability constraints

It should not contain the user's full archive, advertising identifiers, address book, precise location, or gateway credentials.

### Gateway abstraction

```swift
protocol ModelGateway {
    func execute(_ request: ModelRequest) async throws -> ModelResponse
    func capabilities() async throws -> [ModelCapability]
}
```

Adapters translate Lore's request into direct Groq, Fireworks, an optional gateway, or self-hosted inference calls. Model aliases such as `daily-entry-v1`, `memory-extraction-v1`, and `transcription-fallback-v1` are configured server-side; the app does not depend on provider model IDs.

Structured extraction should require schema-constrained output when supported and undergo server and client validation. Invalid results are rejected rather than merged into the canonical graph.

At the current evaluation date, Groq exposes self-serve organization-level ZDR for its transcription endpoints and very low-cost Whisper Large V3 routes, making a direct adapter the strongest remote-audio candidate. That configuration still requires a dedicated consent and privacy release gate; ZDR means transient plaintext processing, not that PII was never disclosed. OpenAI transcription is an accuracy escalation candidate. Remote audio must never pass through an unapproved fallback.

## Remote Data Lifecycle

The deletion promise spans Lore's API, queues, object storage, gateway, inference provider, observability, crash reporting, and backups. There are two permitted retention classes:

- `requestEphemeral`: the normal synchronous route. Content remains in volatile request scope, the full gateway/provider path is verified for zero data retention, and input/output content is discarded immediately when the request completes.
- `asyncRecovery`: only for explicitly asynchronous work or an undelivered result. Content is encrypted with a job-scoped key, deleted immediately after delivery acknowledgement or terminal failure, and subject to a hard seven-day TTL.

Target lifecycle:

1. Receive an authenticated request with an allowed retention class.
2. For `requestEphemeral`, keep content only in memory, use a verified zero-data-retention provider route, stream/return the result, and discard all content as the request completes.
3. For `asyncRecovery`, assign an absolute expiry no later than seven days, encrypt the payload with a job-scoped key, and store it in a TTL-enforced working-data store.
4. Ensure queue messages and logs contain references, not content.
5. Send only the required data to an approved gateway/provider configuration.
6. Validate and encrypt the result under the same expiry.
7. Deliver the result to the app.
8. On durable local acknowledgement, delete request, result, and job key promptly.
9. On cancellation, permanent failure, abandonment, or expiry, delete them automatically.
10. Retain only a content-free audit record: task category, timestamps, route, outcome, policy version, and deletion status.

For a synchronous request, "delete immediately" means discarding input and output content as the response completes. For asynchronous work, it means deleting content immediately after delivery acknowledgement or terminal failure, not before the app has safely received the result. Seven days is only the hard maximum for encrypted recovery or an undelivered result; it is never the normal inference retention duration.

Before production, verify for every gateway/provider route:

- training and human-review policy
- request/response logging and configurable retention
- regional processing and subprocessors
- cache behavior
- abuse-monitoring exceptions
- deletion API or contractual deletion guarantee
- backup and observability retention
- data-processing agreement suitability

If a provider cannot meet the active privacy policy, the router must not use it. Provider claims and configuration should be captured in a versioned allowlist reviewed whenever a model route changes.

## Data Model

Existing SwiftData entities remain useful, but the schema should evolve toward the following boundaries.

### UserProfile

- identity and biography preferences
- default privacy mode
- audio-upload and cellular permissions
- local audio/transcript retention preferences
- writing style and important life eras

### Story

One capture session:

- `id`, `captureDate`, `createdAt`, `updatedAt`
- transcript artifact/version references and `rawTranscriptExpiresAt`
- `title`, prompt reference, audio and metadata references
- processing summary derived from jobs

`captureDate` is when the story was told, not necessarily when its events occurred.

### TranscriptArtifact and TranscriptVersion

The transcript is durable source material and should not remain a single mutable string on `Story`.

`TranscriptArtifact` records the first committed transcription:

- immutable raw text and normalized segments with stable IDs/timestamps when available
- source audio ID and content hash
- local or remote route, engine/model/version, locale, and transcription timestamp
- quality indicators, warnings, and validation outcome
- whether audio deletion completed

`TranscriptVersion` records the current corrected reading without destroying the source:

- artifact ID, monotonically increasing revision, and full corrected text or deterministic edit operations
- editor (`user` or an explicitly accepted suggestion), timestamps, and superseded revision
- hash used by downstream job idempotency and stale-result checks

Model-generated corrections are proposals until accepted. Downstream memory and prose jobs cite transcript artifact, version, and segment IDs.

### AudioAsset

- protected local file reference
- created/expiry dates, duration, deletion state
- transcription and upload permission state

### ProcessingJob

- state-machine and idempotency fields described above
- route decision and capability snapshot version
- input/output schema revisions
- remote lifecycle references and deletion status

Job payloads do not belong in analytics logs.

### LifeEvent, Person, Place, Theme, Relationship, and MemoryFact

Graph entities include confidence and source provenance. `MemoryFact` represents one source-grounded claim with subject, predicate, object/text, temporal bounds, certainty, source story and source span, creation metadata, and supersession/contradiction links.

### BiographyFragment and BiographyChapter

Fragments link prose to story, facts, life events, model/prompt version, and style. Chapters assemble fragments and record which sources support their current revision. Generated prose should migrate out of a single `Story.biographyProse` field as chapter reconciliation matures.

### GenerationProvenance

For each accepted result:

- task and schema version
- local/remote route
- model alias and resolved model/version when available
- prompt-template version and input revision
- source story/fact IDs
- generation timestamp
- validation outcome and user correction/supersession state

Do not store hidden reasoning or provider secrets.

## Retrieval and Context Construction

Retrieval stays local by default:

- chronology for timelines
- local full-text search for exact names and phrases
- local embeddings or lexical similarity for fuzzy recall
- graph traversal for relationships, events, contradictions, and affected passages

For remote generation, the iPhone or a trusted local context builder sends a bounded context package rather than the whole archive. Source IDs in the package are opaque outside the device. The result must cite those IDs so the app can validate provenance.

As archives grow, hierarchical local summaries can reduce context size, but summaries never replace underlying source records while those records are retained.

## Failure, Offline, and Consistency Behavior

- Recording and local persistence work offline.
- Local-capable jobs may run offline; remote jobs enter `deferred` and resume under user network policy.
- If a route fails, the router may retry or choose another allowed provider/model within the same local or remote execution class. Changing a failed local job to remote requires the explicit retry action described above, even in Adaptive mode, and no retry may cross the user's privacy boundary.
- Background termination is safe because job state and input revision are persisted.
- Results are committed transactionally with graph mutations and provenance.
- Duplicate remote responses are harmless because commits use job idempotency keys.
- A result for a stale transcript revision is retained only for diagnostics or discarded; it is never merged as current truth.
- If remote processing completed but acknowledgement was lost, the server retains encrypted working data only until acknowledgement or TTL expiry.
- Users can read, export, correct, and delete local content while AI services are unavailable.
- The UI distinguishes waiting for network, waiting for a local model, processing, retryable failure, privacy restriction, and permanent failure. Retry and cancel are first-class actions.

## Security and Privacy Controls

- Store local data with iOS Data Protection; decide whether optional app-level encryption is needed before launch.
- Use TLS and authenticated app sessions; keep gateway/provider secrets server-side.
- Rate-limit and abuse-protect by pseudonymous account or installation without logging story content.
- Redact request bodies, prompts, transcripts, audio, and model outputs from application, gateway, analytics, and crash logs.
- Separate content-free operational telemetry from biography data.
- Rotate credentials and model policy centrally.
- Provide an in-app explanation and consent before first remote text transfer and separately before first audio upload.
- Make export and delete-all available regardless of subscription state.
- Test retention with synthetic canary jobs and alert when deletion misses its deadline.

## Current Implementation Snapshot

This snapshot deliberately distinguishes code that exists from a feature that works end to end. A type, protocol, route decision, or passing unit test does not make the remote product path production-capable.

### Implemented foundations

- onboarding and user profile
- the Notes, Biography, and Settings shell, including the minimal recording surface and raw-transcript access from Biography
- audio recording, audio-level UI, and legacy Apple `SFSpeechRecognizer` transcription
- SwiftData persistence, legacy migration, and model registration
- immutable `TranscriptArtifact` source records and append-only `TranscriptVersion` corrections
- the `ProcessingJob` data model, state types, route metadata, and deletion metadata
- deterministic hardware/capability policies for local versus remote speech and biography routes
- completion-based local audio deletion after a usable transcript is committed, plus failed-transcription audio retention
- story deletion for linked local audio, transcript support records, and metadata
- local MLX/Bonsai generation, local memory extraction, basic graph merging, and model unloading
- vocabulary, automatic-mode, cellular preference, journal-style, privacy-copy, and local-model settings surfaces
- unit coverage for routing, contracts, transcript immutability, successful audio deletion, and failed-transcription recovery
- a TypeScript `lore-api` Vercel Functions project with strict Zod contracts, OpenAPI documentation, content-free logging, health routing, multipart transcription validation, and grounded daily-entry validation
- direct Groq Whisper and GPT-OSS adapters with mocked success/error coverage, strict JSON Schema output, source-reference validation, and fail-closed provider-policy configuration

### Partially wired systems

- Remote-routed capture is selected on older or unvalidated hardware, but the recording is currently sent to the remote transcriber before its `Story`, `AudioAsset`, and retry job are durably committed. Save-before-processing ordering must be corrected before live networking is enabled.
- `ProcessingJob` persists state, but it is not yet the workflow runner. Relaunch resumption, leasing, backoff, retry, cancellation, dependencies, and idempotent replay remain incomplete, while `Story.processingStatus` still drives part of the flow.
- Remote biography routing and request construction use the newest transcript version, but the successful branch currently persists only `Story.title` and `Story.biographyProse`.
- Completion-driven audio deletion works after a successful transcript transaction, but remote interruption and response-loss behavior are not yet orchestrated by a durable runner.
- Settings expose an automatic mode, cellular toggle, and privacy explanation, but they do not yet provide revocable Device Only/Adaptive permission, separate audio-upload consent, or enforce the cellular preference in routing.
- Transcript evidence is additive and immutable, but generated prose is still primarily stored on `Story`; complete sentence provenance, memory candidates, provider provenance, retention attestations, and versioned `BiographyFragment` commits are unfinished.
- The hardware policy exists, but the allowlist is local rather than a signed remotely managed policy, and iOS 26 `SpeechAnalyzer`, locale checks, thermal/power inputs, and physical-device validation remain incomplete.
- The backend builds and its health route has been verified in an ephemeral Vercel deployment, but the canonical GitHub-connected Vercel project has not been imported and no Groq credential or live provider test has been configured. Processing endpoints remain disabled/fail-closed.
- Backend authentication is preview-only scaffolding. Production deliberately rejects it until the App Attest/session design is implemented.

### Contracts and stubs only

- Provider-neutral transcription and daily-entry request/response types, retention fields, provenance types, and deletion-receipt types exist.
- `LoreBackendProcessingClient`, `RemoteDailyEntryGenerationService`, and remote speech protocols exist.
- `UnavailableRemoteSpeechTranscriber` and `UnconfiguredLoreBackendProcessingClient` intentionally fail closed.
- There is no live iOS HTTP implementation, production authentication/session flow, configured Groq organization, live provider result, or synthetic end-to-end canary through the app.

### Production-capable status

- No Adaptive remote-processing path is production-capable today.
- The local capture and archive foundation is functional and test-covered, but release readiness still requires the speech compatibility work, background/interruption hardening, privacy controls, and physical-device validation described above.
- No real user audio or transcript should be sent remotely until authentication, consent, content-free logging, Groq ZDR configuration, transactional local commits, and the end-to-end synthetic canary pass their release gates.

### Immediate next steps

The next implementation slice should build on the existing foundations rather than rebuild recording:

1. Correct remote persistence ordering: commit the local `Story`, `AudioAsset`, and queued `ProcessingJob` before opening any network request.
2. Build the Lore Vercel backend and direct Groq transcription/daily-entry adapters.
3. Wire the existing provider-neutral contracts into a real iOS HTTP client.
4. Add a one-time Adaptive processing disclosure during onboarding, with separate audio-upload permission and a revocable Device Only/Adaptive choice in Settings.
5. Make the existing cellular toggle an enforced input to route selection.
6. Make `ProcessingJob` the real runner for retry, restart recovery, cancellation, and idempotent commit.
7. Persist the complete remote result—sentence provenance, memory candidates, provider/model provenance, retention attestation, and versioned biography output—not only title and prose.
8. Verify the normal and failure paths with synthetic preview/production canaries before enabling real user content.

## Delivery Phases

### Phase A: Reliable local foundation

1. **Complete:** establish the Notes, Biography, and Settings navigation shell without slowing capture.
2. **Partial:** replace story-level status strings with durable `ProcessingJob` records.
3. **Complete for the source layer:** add `TranscriptArtifact`/`TranscriptVersion`, transcription provenance, and immutable source hashes.
4. Add automatic queue resumption, retry, cancellation, idempotent commits, and interrupted-work recovery.
5. **Partial:** delete audio after verified transcript commit; complete provenance-aware deletion propagation for all derived records.
6. Measure transcription and local model tasks across the supported device set.
7. Add remaining storage/integrity checks, real download progress, and model removal.

### Phase B: Provider-neutral adaptive compute

1. **Partial:** generalize generation and transcription behind provider-neutral, route-aware result types.
2. **Partial:** capability policies exist; add the full `DeviceCapabilityService`, signed remote policy, privacy/network inputs, and diagnostic routing reasons.
3. Build the Lore Processing API and direct provider adapters behind `ModelGateway`, beginning with Groq and an evaluated Fireworks fallback for text.
4. Start with approved hosted open-weight models for structured text extraction and daily-entry writing; add Groq Whisper remote speech only after separate audio consent, benchmark, and retention validation.
5. Add privacy modes, data-transfer disclosure, cellular controls, remote job status, cancellation, and deletion receipts.
6. Validate providers, logging, TTL cleanup, backups, and deletion using synthetic end-to-end tests before sending real user stories.

### Phase C: Evolving biography

1. Complete `MemoryFact`, relationship, contradiction, and source-span persistence.
2. Move generated prose into versioned, source-grounded biography fragments.
3. Build life timeline, chapter, people, place, and theme surfaces.
4. Add correction, entity merge/split, uncertain-date, and contradiction workflows.
5. Reconcile affected passages when new evidence or corrections arrive.

### Phase D: Scale and self-hosting

1. Measure cost, quality, latency, and privacy by task/model route.
2. Add model evaluation suites using synthetic and consented test corpora.
3. Introduce self-hosted inference behind the same `ModelGateway` for workloads where it improves control or economics.
4. Add regional routing, capacity management, and safe provider failover without weakening privacy policy.
5. Develop the source-grounded interviewer and chapter revision loop.

## Release Gates

Before enabling remote processing for production users:

- privacy copy accurately describes text and audio routes
- no content appears in logs, traces, analytics, or crash reports
- provider routes satisfy the versioned retention allowlist
- acknowledgement, cancellation, expiry, and delete-all paths pass end-to-end tests
- local archive commits and idempotent retries survive app/server interruption
- routing never violates Device Only or cellular/audio-upload settings and never silently uploads after local failure
- structured outputs are schema-validated and provenance-checked before merge
- export and local delete behavior are verified
- a security/privacy review covers authentication, storage, gateway, providers, and incident response

## Product Decisions Still Required

- Whether Adaptive mode is the launch default or explicit opt-in.
- Whether users need an account for remote compute, or can use a pseudonymous installation credential until backup/sync exists.
- Which languages and older devices define the supported launch matrix.
- Whether audio upload is offered at launch or text-only remote processing ships first.
- Which hosted open-weight models have suitable licenses and meet quality, schema, cost, regional, and privacy requirements.
- Whether optional encrypted backup/sync is in scope; it must remain distinct from ephemeral processing.
- Subscription limits, fair-use policy, and whether lifetime access includes ongoing remote compute.
