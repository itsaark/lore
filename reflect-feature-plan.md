# Reflect: Guided Voice Conversation Plan

Status: MVP implemented locally; deployment and physical-device validation pending
Date: 2026-08-14

## Decision summary

Add a fourth primary tab named **Reflect**, placed between Notes and Biography.

- **Tab label:** `Reflect`
- **SF Symbol:** `bubble.left.and.text.bubble.right`
- **Selected treatment:** use the system-selected tab tint; do not add an “AI” badge or sparkle decoration
- **Accessibility label:** `Reflect`
- **One-line description:** “Talk through your day. Lore will listen, ask a few questions, and turn only what you said into a biography entry.”

The name describes the user’s intent rather than the implementation. It feels calmer and more personal than “Chat,” less clinical than “Interview,” and less anthropomorphic than “Companion.” The icon depicts a two-way exchange while remaining visually distinct from Notes’ `waveform`, Biography’s `book.closed`, and Settings’ `gearshape`.

Recommended tab order:

1. Notes
2. Reflect
3. Biography
4. Settings

## Implementation checkpoint

Implemented in the current workspace:

- Reflect tab, home, live conversation, review, recovery, and completion UI;
- authenticated Lore endpoints for scoped Soniox credentials, guide turns, and grounded finalization;
- separate persistent Soniox STT and TTS WebSocket transports;
- protected per-turn audio capture, reconnect replay, PCM playback, and keepalive handling;
- encrypted reflection session/turn persistence and the existing Biography artifact bridge;
- relaunch recovery for finalization, CloudKit reconciliation, migration coverage, and provider disclosure copy.

Still required before release: configure the production Soniox key and selected built-in voice, deploy the backend, complete live physical-iPhone and audio-route testing, and close the provider privacy/capacity and safety-policy gates described below.

If `bubble.left.and.text.bubble.right` fails the iOS 18.2 availability build check, use `bubble.left.and.bubble.right` as the fallback.

## Product definition

Reflect is a private, guided voice conversation about the user’s day. Lore asks one concise question at a time, listens to the answer, and asks a small number of grounded follow-ups. When the user ends the reflection, Lore creates a faithful third-person biography entry from the user’s statements.

The full dialogue does not appear in the Biography timeline. Biography receives the same kind of title and third-person grounded prose that Notes produces today. The source conversation remains privately reviewable so the user can audit or correct what supported the entry.

Reflect is not:

- a general-purpose chatbot;
- an advice, coaching, or therapy product;
- an autonomous memory editor;
- a replacement for Notes;
- a place where Lore’s questions or suggestions can become biography facts.

## Why it belongs in Lore

Notes is for uninterrupted narration. Reflect is for a day the user wants help unpacking. Biography remains the durable reading experience for both inputs.

The distinction is simple:

| Surface | User intent | Interaction | Biography result |
| --- | --- | --- | --- |
| Notes | “I already know what I want to say.” | User narrates; Lore listens. | Grounded third-person entry from the note transcript. |
| Reflect | “Help me talk through what happened.” | Lore asks; the user answers; Lore follows up. | Grounded third-person entry from user turns only. |
| Biography | “Show me the story so far.” | User reads and navigates. | Displays accepted derived entries and their sources. |

## Proposed experience

### Reflect home

The tab opens to a quiet, minimal screen that reuses Lore’s visual language without duplicating the Notes recorder.

- Title: **Take a moment**
- Supporting copy: “Talk through your day. Lore will ask a few questions and save only what you tell it.”
- Primary action: **Start reflection**
- Secondary explanation, shown only before the first reflection: “Your voice is transcribed by Soniox. Lore uses the transcript to guide the conversation and write your biography entry.”

The Start reflection tap immediately begins authorization and connection. There is no second ready screen or Begin confirmation.

Do not present model names, voice settings, or a conversation-mode picker on this screen.

### Live reflection

The first release should use controlled turn-taking instead of an always-open full-duplex microphone:

1. Lore asks, “What felt worth remembering about today?”
2. Soniox TTS speaks the question.
3. When playback ends, the app gives a subtle haptic and begins listening.
4. Soniox STT supplies provisional text for feedback and final tokens for the committed turn.
5. Lore creates one short follow-up question from the committed conversation context.
6. The cycle repeats until the user taps **End** or Lore has enough material and offers to finish.

During Lore’s speech, the microphone is not sent to STT. The user can tap the speaking orb to stop playback and begin answering. This provides predictable interruption without allowing the synthesized voice to be transcribed as the user. Automatic acoustic barge-in can be evaluated after the controlled flow is reliable.

Suggested controls and states:

- Top trailing action: **End**
- Central visual states: connecting, Lore speaking, listening, understanding, paused, recovering
- Current-turn captions: provisional text is visually subdued; committed text is stable
- Recovery actions: **Try again**, **Save what we have**, and **Discard reflection**
- End state: **Reflection saved**, followed by **View in Biography** when generation completes

### Conversation behavior

Lore should:

- ask one question at a time;
- keep spoken turns concise, normally under 45 words;
- begin broadly, then clarify people, sequence, feelings, and significance only when the user has introduced them;
- preserve uncertainty instead of resolving it;
- use preferred names and vocabulary already stored in Lore;
- avoid repeating a question the user has already answered;
- avoid advice, diagnosis, moral judgment, motivational speeches, or invented interpretations;
- never claim to remember a fact unless that accepted fact was included in the request;
- allow the user to end at any point without guilt-inducing copy.

Proposed session bounds for the first release are a soft target of 5–8 minutes and a hard product cap of 20 minutes. These are product safeguards rather than Soniox platform limits and can be changed after real usage testing.

## Grounding and biography contract

This is the central correctness rule:

> Only finalized user speech is factual evidence. Lore’s questions and generated speech are context, never evidence.

At finalization:

1. Freeze the reflection session so no more turns can be appended.
2. Atomically commit all finalized user turns, source segments, timestamps, and STT provenance.
3. Build a generation request containing:
   - evidence-eligible user turns;
   - context-only Lore turns;
   - accepted prior facts;
   - the local capture date and profile information;
   - an explicit `third_person` render configuration.
4. Generate a structured journal result through Lore’s backend.
5. Reject the result unless every title and sentence cites at least one user source segment.
6. Reject any source reference that points to a Lore/assistant turn.
7. Persist the complete result and provenance, then expose the entry through the existing Biography timeline.

Reflect always produces third-person biography prose, even if a separate Notes writing preference is later set to first person. The writer must preserve the current grounded-journal rules: no invented names, dates, motives, dialogue, scene details, or certainty.

Short answers need their question for interpretation. For example, “Yes, around six” is evidence, while the preceding Lore question explains what “six” refers to. The generation schema must therefore carry assistant turns in a separate context-only collection while allowing citations only to user turns.

## Proposed data model

Use new conversation records for the live session, then bridge the finished result into the existing Story, transcript, and biography pipeline.

### Private CloudKit-backed records

`ReflectionSession`

- `id`
- `startedAt`, `endedAt`
- `capturedLocalDate`
- `state`: active, finalizing, completed, failed, discarded
- `storyId`
- `transcriptArtifactId`
- `resultArtifactId`
- provider/model/policy identifiers
- schema version

`ReflectionTurn`

- `id`, `sessionId`, `sequence`
- `role`: user or lore
- `text`
- `isEvidenceEligible` — true only for finalized user turns
- `startedAt`, `endedAt`
- language and optional confidence
- source segment identifiers
- processing provenance for user turns

All turn text should use the same CloudKit encryption treatment as transcripts and generated prose. A source-detail screen may render the private dialogue, but Biography renders only the derived entry.

### Device-local operational records

`ReflectionRuntimeState`

- active STT/TTS connection identifiers;
- pending temporary-key expiry;
- current turn and retry state;
- protected audio file references for uncommitted user turns;
- reconnect counters and bounded backoff state.

Do not sync raw audio, temporary provider credentials, WebSocket state, or retry leases.

### Reuse existing records

When a reflection is frozen, create one `Story`, `TranscriptArtifact`, and immutable `TranscriptVersion` from the user turns. Reuse `ProcessingJob`, `DailyEntryResultArtifact`, `BiographyFragment`, and daily biography consolidation wherever their existing invariants fit. Add a source-kind discriminator such as `note` or `reflection` rather than creating a parallel Biography system.

## Audio lifecycle

Each user turn must be recorded to a protected device-local file while it is streamed to Soniox.

- Provisional Soniox tokens may update the live caption but are never persisted as authoritative text.
- Final tokens are assembled into source segments with token timestamps and confidence.
- The turn’s audio is deleted only after its finalized transcript and provenance commit succeeds.
- If STT disconnects before commit, retain the audio, obtain a new scoped key, and replay it at the cadence Soniox requires.
- If recovery cannot complete during the live session, pause the reflection and offer **Save what we have**. Never silently drop the unfinished turn.
- Ending or backgrounding the app closes both sockets. Durable committed turns survive app termination.

This maintains Lore’s existing “never delete on hope” rule while allowing live captions.

## Soniox integration

### Provider surfaces

- STT WebSocket: `wss://stt-rt.soniox.com/transcribe-websocket`
- STT model: `stt-rt-v5`
- TTS WebSocket: `wss://tts-rt.soniox.com/tts-websocket`
- TTS model: `tts-rt-v1`
- Initial output: mono `pcm_s16le` at 24 kHz for low-overhead playback
- Initial voice: a built-in voice selected during product testing; do not ship voice cloning in this feature

Use endpoint detection for natural turn completion, but retain an explicit stop/finalize control. Collect token-level timestamps and confidence. Speaker diarization is unnecessary because the app controls which side is speaking.

Soniox real-time content is the intended privacy path. Do not use Soniox async file transcription, because that API creates stored file and transcription objects that require explicit cleanup.

### Credential flow

The long-lived `SONIOX_API_KEY` remains in Vercel Production. The iPhone first authenticates with the existing App Attest-backed Lore session, then asks Lore’s backend for two Soniox temporary keys:

- one single-use key scoped to `transcribe_websocket`;
- one single-use key scoped to `tts_rt`.

Each key receives a short connection window, a bounded maximum session duration, and a content-free pseudonymous client reference. The app connects directly to Soniox, minimizing latency and keeping raw live audio out of Lore’s backend.

This requires refining the architecture rule from “provider keys exist only in Vercel” to “long-lived provider secrets exist only in Vercel; the app may receive short-lived, single-use, capability-scoped session credentials.” If that boundary is not acceptable, Reflect will require a dedicated WebSocket proxy and should not be implemented through the current synchronous Vercel functions.

### Backend endpoints

`POST /v1/reflections/session-credentials`

- requires a valid Lore processing session;
- checks reflection-specific rate and concurrency limits;
- creates the two scoped temporary keys;
- returns provider-neutral model aliases, expiry, maximum duration, and regional endpoints;
- never receives audio or transcript content.

`POST /v1/reflections/respond`

- accepts a bounded list of committed turns and accepted facts;
- treats all turn text as untrusted source data;
- asks Fireworks for one structured response containing `spoken_text`, `should_offer_finish`, and non-user-visible policy metadata;
- validates the schema and ensures the response is a question or brief acknowledgement plus question;
- returns no more than the configured spoken-word limit.

For the MVP, use a short, non-streaming structured LLM response and stream that completed text through Soniox TTS. This keeps response validation strict. Streaming LLM tokens directly into TTS can follow after interruption, cancellation, and partial-response semantics are defined.

`POST /v1/reflections/finalize`

- accepts immutable user evidence turns plus context-only Lore turns;
- forces third-person grounded output;
- uses a deterministic idempotency key and processing lease;
- validates that title and sentence references resolve only to user evidence;
- returns the same grounded entry and provenance shape used by Biography.

Provider-specific names remain behind Lore aliases such as `reflection-stt-v1`, `reflection-voice-v1`, `reflection-guide-v1`, and `reflection-entry-v1`.

## iOS architecture

Add `.reflect` to the tab enum and give Reflect its own `NavigationStack`. Keep live session state out of `ContentView` and out of `SpeechRecognitionViewModel`.

Suggested components:

- `ReflectHomeView`: empty/ready/completed states and entry point
- `ReflectionSessionView`: screen composition and user actions
- `ReflectionSessionModel`: main-actor observable state machine for the active session
- `SonioxRealtimeSTTClient`: URLSession WebSocket transport, token finalization, reconnects
- `SonioxRealtimeTTSClient`: text streaming, PCM decoding, cancellation, character timing
- `ReflectionAudioController`: AVAudioSession, protected turn recording, playback, route changes
- `ReflectionGuideClient`: Lore backend response requests
- `ReflectionFinalizer`: atomic source commit and biography job creation

`ReflectionSessionModel` owns the live flow because it spans multiple asynchronous services and must survive view updates. Services are explicitly injected into the model. The user’s Start reflection action begins the flow exactly once; view lifecycle tasks are reserved for relaunch recovery. The durable persistence/finalization work remains in a runner so it can recover after app relaunch.

Suggested state machine:

```text
idle
  -> authorizing
  -> connecting
  -> loreSpeaking
  -> listening
  -> finalizingUserTurn
  -> requestingGuideTurn
  -> loreSpeaking

Any active state -> pausedForInterruption -> reconnecting -> prior state
Any active state -> ending -> committingSource -> generatingEntry -> completed
Any active state -> failedRecoverably | failedTerminally
```

There must be exactly one owner for microphone capture and one owner for speaker playback. Notes recording and Reflect cannot run simultaneously.

## Privacy, consent, and safety

Before release:

- update onboarding and App Store privacy copy to identify Soniox for real-time transcription and speech generation;
- explain that finalized conversation text is sent to Fireworks to choose follow-up questions and create the grounded entry;
- verify in writing that Soniox real-time STT and TTS input/output content is not persistently retained or used for training;
- keep audio, transcripts, prompts, generated speech text, and provider payloads out of Vercel and Neon logs;
- store only content-free request IDs, model aliases, duration, token usage, latency, and error categories;
- use built-in voices only; voice cloning is out of scope because it creates a persistent biometric-like voice asset and additional consent obligations;
- include an obvious end control and stop microphone access immediately when the session ends or the app becomes inactive.

Reflect should respond safely to distress but must not present itself as a therapist or emergency service. Safety copy and escalation behavior require a separate reviewed policy before production; they must not be improvised solely in the generation prompt.

## Provider constraints and operating targets

Current public Soniox documentation should be treated as a release input, not as a substitute for Lore’s own tests:

- Real-time STT defaults to 10 concurrent sessions and 100 starts per minute; request production capacity before rollout.
- Real-time TTS defaults to 3 concurrent streams, with up to 5 streams per WebSocket connection and a 2-minute cap per TTS stream. Lore’s short questions should remain far below that duration.
- STT audio must be sent at real-time or near-real-time cadence, including recovery replays.
- Soniox documents approximately $0.12 per hour for real-time STT and $0.70 per generated hour for TTS. Fireworks dialogue and finalization remain additional costs.
- Set a project-level Soniox budget and attribute usage with pseudonymous, content-free session references.

TTS v2 was released on 2026-08-11 and is therefore new. Its quality, latency, pronunciation, interruption behavior, and failure rate must be tested on physical iPhones before production adoption.

## Delivery plan

### Phase 0 — Decisions and provider readiness

- Approve the Reflect name, icon, tab position, opening copy, and controlled turn-taking interaction.
- Select a built-in Soniox voice using blind listening tests.
- Confirm Soniox real-time retention, training, DPA, regional processing, and required concurrency increase.
- Define the distress/safety behavior and a product cap for session length.
- Add Soniox cost budgets and a non-production project.

Exit criterion: product decisions and provider privacy/capacity gates are documented.

### Phase 1 — Contracts and persistence

- Add versioned reflection session, turn, credential, guide-response, and finalization contracts.
- Add `ReflectionSession` and `ReflectionTurn` to the split SwiftData/CloudKit model configuration.
- Add source-kind metadata without breaking existing Notes records.
- Implement the rule that only user turn IDs are evidence eligible.
- Add migration, deletion, reconciliation, and CloudKit tests.

Exit criterion: fixtures can persist, reload, migrate, and delete a reflection with exact source provenance.

### Phase 2 — Backend boundary

- Add Soniox configuration and temporary-key adapter.
- Implement `/v1/reflections/session-credentials` with App Attest authorization, quotas, and safe logs.
- Implement the structured guide-turn endpoint using Fireworks.
- Implement finalization validation and deterministic leases.
- Add provider mocks, malformed-response tests, retry classification, and no-content logging tests.

Exit criterion: backend contract tests prove scoped credentials and reject assistant-authored evidence.

### Phase 3 — iOS real-time foundation

- Implement STT and TTS WebSocket clients with cancellation and reconnect behavior.
- Implement raw audio capture, protected per-turn recovery files, PCM playback, route changes, and audio-session coordination.
- Build the session state machine independently of final UI styling.
- Verify on speaker, receiver, wired headphones, Bluetooth, interruption, phone call, background, and network transition scenarios.

Exit criterion: a physical iPhone completes a multi-turn synthetic session without losing a finalized user turn.

### Phase 4 — Reflect experience

- Add the fourth tab and its independent `NavigationStack`.
- Build Reflect home, live session, recovery, completion, and source-review states.
- Reuse Lore’s orb language with distinct listening/speaking behavior.
- Add VoiceOver, Dynamic Type, Reduce Motion, haptics, and explicit accessibility values for every state.
- Add previews and UI tests for all non-network states.

Exit criterion: the interaction is understandable without exposing provider or orchestration jargon.

### Phase 5 — Biography integration

- Freeze and atomically commit user turns as the authoritative source artifact.
- Run third-person grounded finalization.
- Insert the result through the existing Biography artifact/fragment path.
- Link Biography detail back to the private source conversation.
- Make retry, duplicate submission, deletion, and correction idempotent.

Exit criterion: ending one reflection produces exactly one Biography entry, and every sentence traces only to user speech.

### Phase 6 — Evaluation and rollout

- Run a synthetic provider canary and a no-content logs/database audit.
- Conduct a Lore-specific STT set covering names, dates, accents, noisy rooms, multilingual switching, pauses, and short confirmations.
- Measure time to final user turn, time to first audio, end-to-end turn latency, disconnect recovery rate, and cost per reflection.
- Start behind a server-controlled internal feature flag, then TestFlight, then a small production cohort.
- Keep Notes and Biography fully usable if Reflect or Soniox is unavailable.

Exit criterion: quality, privacy, reliability, accessibility, and cost thresholds pass on physical devices.

## Agent-ready work packages

After this plan and the contracts are approved, work can be divided as follows:

| Work package | Scope | Can begin |
| --- | --- | --- |
| Product/UI | Reflect views, tab integration, state copy, accessibility, previews | After Phase 0 decisions and state enum are fixed |
| iOS speech transport | Soniox STT/TTS clients, temporary credentials, token/audio streaming | After credential and provider contracts are fixed |
| iOS audio lifecycle | AVAudioSession, protected turn files, playback, interruptions, recovery | After audio formats and turn lifecycle are fixed |
| Backend | Soniox key minting, Fireworks guide endpoint, finalizer, leases, safe logs | After request/response contracts are fixed |
| Persistence/Biography | SwiftData models, migrations, source commit, Biography integration | After evidence rules and model schema are fixed |
| Verification | Contract tests, mock WebSockets, UI tests, physical-device matrix, privacy audit | Begins with fixtures; completes after integration |

The contract/evidence work must land first. UI, transport, backend, and persistence can then proceed in parallel with explicit file ownership. Integration and physical-device verification follow after those branches converge.

## Acceptance criteria

The feature is ready only when all of the following are true:

- The fourth tab is labeled Reflect and is understandable without an “AI chat” explanation.
- A user can complete a natural multi-turn session on a physical iPhone.
- Provisional STT text never becomes authoritative source text.
- A disconnect or app interruption never deletes the only copy of an uncommitted user turn.
- Lore’s synthesized speech is never captured as user evidence.
- Ending a reflection produces at most one result for the same session and idempotency key.
- The Biography entry is third person.
- Every title and sentence cites at least one finalized user source segment.
- No title or sentence cites an assistant turn.
- The source conversation remains privately auditable and correctable.
- Raw audio is deleted only after transcript commit.
- Soniox and Fireworks credentials never ship as long-lived secrets in the app.
- Vercel logs, Neon rows, analytics, and crash reports contain no conversation content.
- Notes and Biography continue to work when Reflect is offline, rate-limited, or disabled.
- VoiceOver, Dynamic Type, Reduce Motion, audio-route changes, and interruption recovery pass on supported iPhones.

## Implemented decisions

The MVP currently follows these decisions; revise them before release if needed:

1. **Name and icon:** Reflect + `bubble.left.and.text.bubble.right`.
2. **Tab order:** Notes, Reflect, Biography, Settings.
3. **Interaction:** controlled turn-taking with tap-to-interrupt for v1; automatic barge-in later.
4. **Opening prompt:** “What felt worth remembering about today?”
5. **Session bounds:** target 5–8 minutes, maximum 20 minutes.
6. **Persistence:** retain the private source dialogue for audit, but show only grounded prose in Biography.
7. **Writing:** Reflect always creates third-person prose.
8. **Voice:** one built-in Soniox voice for v1; no voice cloning.
9. **Credentials:** allow short-lived, single-use Soniox session keys on the iPhone while keeping the long-lived key server-only.
10. **LLM delivery:** validated short responses first; token-streamed LLM responses later.

## References

- [Soniox real-time STT](https://soniox.com/docs/stt/rt/real-time-transcription)
- [Soniox STT WebSocket API](https://soniox.com/docs/api-reference/stt/websocket-api)
- [Soniox direct streaming and temporary keys](https://soniox.com/docs/guides/direct-stream)
- [Soniox real-time TTS](https://soniox.com/docs/tts/rt/real-time-generation)
- [Soniox TTS WebSocket API](https://soniox.com/docs/api-reference/tts/websocket-api)
- [Soniox TTS limits](https://soniox.com/docs/tts/rt/limits-and-quotas)
- [Soniox TTS models and changelog](https://soniox.com/docs/tts/models)
- [Soniox security and privacy](https://soniox.com/docs/security-and-privacy)
- [Lore inference strategy](./inference-strategy.md)
- [Lore architecture](./architecture.md)
- [Lore product vision](./vision.md)
