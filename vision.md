# Lore Product Vision

Last updated: 2026-08-04

## The product

Lore is a private, voice-first journal that helps a person capture their life without stopping to organize it. The user opens the recording screen, speaks freely, and leaves with two durable artifacts on their iPhone:

1. the source transcript, kept as the factual record of what they said; and
2. a short, grounded journal entry written from that transcript.

Over time, those source records can support a living biography, corrected names and timelines, personal insights, and guided follow-up questions. The source transcript remains authoritative even as every derived view evolves.

## Current product direction

Lore has one processing path:

- audio transcription runs remotely through Lore's API and Groq;
- journal writing runs remotely through Lore's API and Fireworks;
- completed transcripts and derived writing are stored on the iPhone;
- the Lore API does not intentionally persist audio, transcripts, prompts, or generated prose;
- recorded audio is deleted from the iPhone only after the transcript and its provenance have been committed successfully.

There is no processing-mode picker, hardware classification, model download, or network-route choice in the current app. Wi-Fi and cellular use the same product behavior. If the network is unavailable, Lore keeps the protected recording in a visible retryable state instead of losing it.

## The core experience

### Record

The main screen is deliberately minimal and focused. Recording should begin with one subtle, unmistakable action near the bottom of the screen. Shape and motion communicate idle, recording, and processing states without a loud red control, icon, or persistent explanatory text.

### Read the source

The transcript view shows the immutable source artifact and its processing status. Corrections create new transcript versions with provenance; they do not silently overwrite history.

### Read the story

The journal view turns each completed source transcript into a concise, grounded entry. The writing may use the user's preferred perspective and tone, but it must not invent facts. A biography view can later assemble accepted entries across time while preserving links back to their sources.

## Privacy promise

Lore's durable personal archive lives on the user's iPhone. Provider credentials stay on the Lore server. The server validates and forwards bounded synchronous requests, returns the result, and retains only content-free security metadata needed to prevent replay and paid-inference abuse.

Remote processing requires one concise permission during onboarding. It identifies Groq for transcription and Fireworks for journal writing, explains that recordings and transcript text are sent for those purposes, and states where the finished story is stored. This disclosure appears once as part of setup rather than as a recurring technical choice.

"No persistent retention" is the accurate engineering promise. Lore must not claim that plaintext disappears from every provider's volatile memory at the exact instant a response returns unless the provider supplies that guarantee. Release approval therefore requires verified Groq zero-data-retention settings and acceptance of Fireworks' documented open-model data handling and bounded volatile cache behavior.

## Product principles

- **Capture first.** Speaking must feel faster than typing or organizing.
- **Source before synthesis.** Preserve the transcript before creating prose.
- **Ground every claim.** Derived writing must point back to source artifacts.
- **Never delete on hope.** Audio is removed only after the transcript commit succeeds.
- **Keep infrastructure invisible.** Provider, routing, and retry complexity should not become user-facing configuration.
- **Make failures recoverable.** Offline and upstream failures become durable jobs with clear retry behavior.
- **Keep providers replaceable.** App-facing contracts use stable model aliases and versioned schemas rather than vendor-specific payloads.

## MVP scope

The first complete release is successful when a person can:

1. finish the short onboarding flow and grant one processing permission;
2. record a voice note on a supported physical iPhone over Wi-Fi or cellular;
3. receive an accurate Groq transcript through the Lore API;
4. see that transcript committed locally before the captured audio is deleted;
5. receive a grounded Fireworks journal entry and read it in Lore;
6. close or restart the app during processing without losing the job;
7. retry safely after a connection or provider failure without duplicate artifacts; and
8. delete or export their local archive through a deliberate product flow.

## Not in the MVP

- user-selectable compute or privacy modes;
- downloadable inference assets;
- a general-purpose chatbot;
- cross-device sync or a cloud biography store;
- automatic factual merging without source links;
- silent audio deletion before a verified transcript exists.

## Near-term sequence

1. Prove physical-device App Attest enrollment against Production.
2. Run a synthetic end-to-end transcription and journal-generation canary.
3. Verify restart recovery, retry, cancellation, and commit-driven audio deletion.
4. Finish the transcript and journal reading experiences.
5. Add correction and provenance workflows for names, dates, and timelines.
6. Build biography assembly and interactive follow-up only after the capture pipeline is trustworthy.
