# Lore Vision

Last updated: 2026-07-16

## Product Thesis

Lore is a voice-first private journal that can grow into a personal memory and biography system.

The user speaks naturally about today, old memories, relationships, turning points, and reflections. Lore first preserves a trustworthy transcript, then turns that source into readable daily entries and, over time, a durable account of the user's life. It learns how people, places, events, themes, and eras relate; revises derived writing as new context arrives; and always lets the user trace a passage back to what they actually said.

Lore is not a voice-memo folder or a generic chatbot. Voice is the fastest input, the transcript archive is the source of truth, and the evolving journal and biography are the first useful views built from it. Later products such as personal insights can use the same grounded archive without weakening its provenance.

## Core Promise

Speak freely. Lore keeps the record and helps turn it into your story.

The experience should feel like a patient, trusted biographer:

- The user should not need to organize memories before speaking.
- Stories can arrive in any order and can correct, deepen, or contradict earlier stories.
- The biography should improve continuously rather than become a pile of isolated summaries.
- Important claims should remain grounded in source stories, with uncertainty preserved.
- The user's iPhone is the canonical archive. Remote compute, when allowed, is a temporary processor rather than the home of the biography.
- The quality of the core experience should not depend on owning a recent or expensive phone.

## Product Experience

The primary loop is deliberately simple:

1. The user opens Lore and answers a prompt or speaks freely.
2. Lore records the story and uses local transcription only on a validated newer-device configuration; older or unvalidated devices use the consented remote transcription route by default.
3. Lore safely saves the source story to the on-device archive before further processing.
4. Lore deletes the audio after a usable transcript is durably committed, unless a short visible retry state is still needed.
5. Lore writes a short, faithful daily entry in the selected perspective and can extract people, places, events, dates, relationships, and themes.
6. The user can read the raw transcript or the evolving narrative, inspect its sources, and correct Lore when it misunderstood.

Processing may happen locally or on privacy-conscious remote infrastructure. That routing should feel seamless, but never secret: the app must explain the selected privacy mode, show when data will leave the device, and let the user choose Device Only mode.

No live transcript is required while recording. Capture should remain calm and immersive. Processing can finish afterward, resume later, or wait for connectivity without risking the recording.

## Launch Information Architecture

The first release has three primary surfaces:

- **Notes:** a minimal, fast capture home focused entirely on starting, stopping, and understanding the state of the current recording.
- **Biography:** daily entries written from those notes, grouped chronologically, with a clear path to the raw or corrected supporting transcripts. The initial default is short, warm third-person prose; perspective and style can become customizable.
- **Settings:** privacy mode, remote-transcription permission, cellular policy, audio recovery behavior, writing perspective/style, export/delete controls, and optional local-model management.

Additional graph, people, places, timeline, interview, and insight views come later. They should not complicate the capture-first MVP.

## One Source Archive, Many Evolving Views

Every new story can change the user's understanding of an earlier one. Lore should therefore maintain three related layers:

- **Source archive:** recordings only while needed, immutable raw transcripts, corrected transcript versions, capture metadata, and user corrections.
- **Memory model:** source-grounded people, places, events, relationships, themes, dates, confidence, and contradictions.
- **Narrative:** biography fragments, timelines, and chapters assembled from the memory model and linked to sources.

The original transcript is never silently rewritten by a model. User corrections create a new canonical transcript version while preserving the raw transcription and edit history. Generated prose is a view over that evidence, not the evidence itself. It can be regenerated as understanding improves or the user changes the writing style. Corrections should update relevant memory and narrative without erasing provenance.

## Adaptive Compute

Lore is local-first, not local-only.

The app should choose the least invasive execution route that can complete a task with acceptable quality and reliability. The choice can depend on:

- the user's privacy mode
- whether on-device speech recognition is available for the language and device
- installed local models and their measured capability
- task complexity and context size
- available memory and storage
- battery level, Low Power Mode, and thermal state
- connectivity and the user's cellular-data preference
- expected local latency versus remote latency

On validated newer devices, transcription, extraction, and some writing may run locally. For the initial release, marketed iPhone 17-class and newer hardware (`iPhone18,*` identifiers and above) may enter the local-transcription and Bonsai biography-processing routes only when the installed OS API, requested locale, runtime availability, and Lore quality checks all pass. Earlier, unknown, or unvalidated devices use remote speech transcription and biography processing by default when the user's privacy mode permits it. This allowlist is a remotely configurable release policy backed by measured results, not a permanent claim about a phone generation.

A local language model is therefore an enhancement, not a prerequisite for using Lore. Local processing should continue to improve, but the product must work well on devices older or less capable than iPhone 14.

## Privacy Modes

Lore should make privacy a comprehensible product choice rather than a hidden implementation detail.

### Device Only

Speech, transcripts, memory extraction, and biography generation never leave the device. Work may be slower, use a smaller model, or remain queued until a compatible local model is available. This mode never falls back to a server.

### Adaptive

Lore processes locally when it can do so reliably and sends only the minimum necessary input for heavier work when remote compute is materially better. Text is preferred over audio. The app should clearly disclose the first remote transfer and provide controls for cellular use and audio upload.

This is the intended mainstream experience, subject to user validation. Whether it becomes the default is a product decision that must be made before launch.

Adaptive consent permits the router to select a remote route before a task begins. It does not permit silent cloud failover: if a task was routed locally and local processing fails, Lore must show the failure and obtain an explicit retry choice before uploading that story. A future "prefer remote quality" setting can exist within Adaptive mode without weakening this rule.

Changing privacy mode affects future processing. Any reprocessing that would newly send existing material off-device requires an explicit action.

## Remote Processing Promise

Remote processing is ephemeral. Lore should send a narrowly scoped story or context package, receive structured memories or prose, save the validated result on the iPhone, and remove the server-side working data.

The product promise should be:

- Lore does not keep a cloud copy of the user's biography as part of ordinary processing.
- Content is not used to train models or for advertising.
- Requests use transport encryption and authenticated, short-lived app sessions.
- The backend and model providers receive only the content needed for the specific task.
- Normal synchronous inference uses a verified zero-data-retention route: request content is held only for the request and discarded immediately when the response completes.
- Encrypted persistence is permitted only for explicitly asynchronous work or an undelivered result. It is deleted immediately after successful delivery or terminal failure and has a hard maximum recovery lifetime of seven days.
- Operational logs exclude story content and use pseudonymous identifiers.
- The app shows pending remote jobs and lets the user cancel work that has not begun.

This promise must be backed by the actual behavior and contracts of every infrastructure and model provider. A gateway retention setting alone is not sufficient if an upstream provider, logs pipeline, or backup system keeps content longer. A route cannot be described as zero-data-retention until the full route has been verified.

Lore's backend should initially call approved providers through provider-specific adapters, with direct Groq routes as the leading MVP candidate and Fireworks as a text-generation fallback. A gateway may be added later where it improves operations without weakening the verified retention path. This is an implementation choice, not part of the product contract: Lore's processing API must remain provider-agnostic so models can change and inference can later move to infrastructure we operate ourselves.

## Transcription Strategy

Speech processing should follow an explicit device policy:

1. On-device speech recognition for validated newer-device, OS, and locale combinations.
2. Ephemeral remote transcription through Lore's backend, with prior audio-upload consent, for older or unvalidated devices.
3. A downloadable or bundled local speech model only if later product testing justifies its size and performance.

Device Only mode never overrides this boundary. If a device is not approved for local transcription and remote processing is disabled, Lore keeps the encrypted recording in a visible waiting state rather than uploading it or pretending a lower-confidence transcript is complete.

By default, remote language-model work should receive the transcript rather than audio. Audio should leave the device only for an explicitly permitted transcription task.

Audio deletion is completion-based, not timer-only. Once a non-empty transcript and its provenance have been committed locally and any required remote transcription job has been acknowledged, Lore deletes the source audio promptly. If transcription fails or produces no usable speech, Lore retains encrypted audio locally in a visible retry state for a short recovery window, never silently discarding the only source.

## Memory and Narrative Strategy

Lore needs a biographical temporal memory graph, not generic agent memory.

The graph must support non-linear storytelling and store:

- when a story was captured
- when a remembered event happened, if known
- who was involved and how they relate
- where it happened
- what themes it relates to
- which biography passages it supports
- confidence, uncertainty, contradiction, and provenance back to source material

If the user says "this was probably around 2012," Lore stores an approximate period rather than inventing an exact date. If a later story disagrees, Lore should preserve both claims, ask for clarification when useful, and avoid presenting the disputed detail as settled fact.

Default prose should be warm, literary, third-person, chronological biography prose: honest but not clinical, reflective without becoming melodramatic. Style can become customizable because the evidence and memory graph remain separate from generated prose.

## Long-Term Experience

Lore should become a two-way interviewer and editor. It should use gaps, recurring subjects, contradictions, and meaningful transitions to ask thoughtful questions such as:

- "You mentioned your father again. Should we capture that story properly?"
- "Was this before or after you moved to Seattle?"
- "What did that moment change for you?"

It should never drift into being a generic assistant. Every prompt should serve the biography: capture a missing story, resolve uncertainty, deepen an important relationship, or improve the narrative.

## Retention and Ownership

The iPhone owns the durable archive. The user should be able to export it, delete individual stories and derived material, or erase everything.

Initial local defaults:

- Audio after successful transcription: delete promptly after the transcript and provenance are durably committed.
- Audio awaiting transcription or user review: retain locally for recovery, with a hard maximum of 7 days unless the user explicitly chooses otherwise.
- Raw transcripts and corrected transcript versions: keep locally until the user deletes them. They are the durable source archive, not disposable model input.
- User corrections, polished prose, extracted memories, provenance records, and biography structure: keep until the user deletes them.
- Normal synchronous remote inputs and outputs: request-ephemeral under a verified zero-data-retention route and discarded immediately when the request completes.
- Asynchronous or undelivered remote inputs and outputs: encrypted, deleted immediately after delivery or terminal failure, and never retained beyond the seven-day recovery ceiling.

Retention controls must explain consequences. Deleting source material may reduce Lore's ability to show a quote or re-evaluate a generated claim. Derived facts must either be deleted with their source or visibly marked as no longer source-verifiable.

## Business Model

The working commercial direction is:

- Monthly subscription: approximately $10/month.
- Lifetime purchase: approximately $250 one-time.

Entitlements should pay for ongoing processing and advanced biography features, not hold the user's archive hostage. If access lapses, existing local stories and biography content remain readable and exportable. Pricing, remote-compute limits, and fair-use policy need validation before launch.

## Product Phases

### Phase 1: Trustworthy capture and adaptive processing

- Establish Notes, Biography, and Settings as the three launch surfaces.
- Make capture durable across interruptions and offline use.
- Store immutable raw transcripts, corrected versions, source hashes, and transcription provenance.
- Delete audio promptly after verified transcription while preserving a visible retry state on failure.
- Add automatic retry, cancellation, and understandable processing states.
- Introduce the provider-neutral processing boundary and remote job API.
- Use local transcription first only on validated newer-device configurations; route older or unknown devices to consented remote transcription by default.
- Add privacy modes, transfer disclosure, cellular controls, and retention controls.
- Enforce and verify remote deletion rather than relying on a policy statement.
- Build a measured device-capability matrix instead of hard-coding model choices by phone name.

### Phase 2: The evolving biography

- Make biography, timeline, people, places, and themes primary product surfaces.
- Reconcile new stories with existing memories rather than summarizing each in isolation.
- Link every passage and memory to source stories.
- Add correction, merge, contradiction, and uncertainty workflows.
- Complete provenance-aware user deletion propagation without silently expiring the source archive.

### Phase 3: Patient interviewer and durable ownership

- Ask source-grounded follow-up questions that fill gaps or resolve uncertainty.
- Generate and revise chapters as the archive grows.
- Add encrypted export, restore, and optional user-controlled backup without making a server archive mandatory.
- Move suitable inference workloads to self-hosted infrastructure when scale, economics, and privacy justify it.

### Phase 4: Private local publishing

- Let the user temporarily turn Lore into a password-protected local web server that is reachable from a laptop on the same Wi-Fi network.
- Provide a username and password for the session, clear connection instructions, and an obvious way to stop access from the app.
- Offer a private, interactive presentation of the user's biography and personal insights, alongside a polished ebook-style reading experience.
- Keep the iPhone as the canonical archive: this local publishing mode should not require uploading or permanently hosting the biography in the cloud.

## Success Criteria

Lore succeeds when:

- A user can speak without first deciding how to categorize a memory.
- A story is never lost because AI processing, connectivity, or model download failed.
- Older supported iPhones deliver the core biography experience.
- The biography becomes more coherent as the user adds context and corrections.
- Users can see why Lore believes something and where a passage came from.
- Device Only mode is absolute, and Adaptive mode meets its stated deletion promise.
- The user can leave with a complete, useful copy of their archive.

## Non-Goals

- Building a generic AI assistant.
- Treating capture order as life chronology.
- Requiring a large local model or recent flagship phone.
- Maintaining a conventional cloud copy of the user's biography for routine processing.
- Social sharing in the first release.
- Silent cloud fallback after a local route fails, in either privacy mode.
- Claiming zero-data-retention or end-to-end privacy for a provider route that has not been verified.
