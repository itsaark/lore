# Lore Product Vision

Last updated: 2026-09-04

## The product

Lore is a private, voice-first journal that helps a person capture their life without stopping to organize it. The iPhone app is the primary experience, and a companion Apple Watch app launches alongside it as a secondary, always-nearby way to capture a voice note. Whether a note begins on the iPhone or Apple Watch, the user speaks freely and receives two durable artifacts in the same Lore archive:

1. the source transcript, kept as the factual record of what they said; and
2. a short, grounded journal entry written from that transcript.

Over time, those source records can support a living biography, corrected names and timelines, personal insights, and guided follow-up questions. The source transcript remains authoritative even as every derived view evolves.

## Current product direction

Lore has one processing path:

- audio transcription runs remotely through Lore's API and Groq;
- journal writing runs remotely through Lore's API and Fireworks;
- voice notes can originate in the iPhone app or the companion Apple Watch app;
- Watch captures are transferred to the paired iPhone and enter the same transcription, journal, and biography pipeline as iPhone captures;
- completed transcripts and derived writing are stored on the iPhone;
- the Lore API does not intentionally persist audio, transcripts, prompts, or generated prose;
- the Watch retains a pending capture until the iPhone acknowledges a protected, durable import; and
- imported or iPhone-recorded audio is deleted from the iPhone only after the transcript and its provenance have been committed successfully.

The Apple Watch is an input surface, not a separate archive or processing mode. The iPhone remains the primary place to review, correct, organize, and delete notes, and it coordinates remote processing. There is no processing-mode picker, hardware classification, model download, or network-route choice in the current app. Wi-Fi and cellular use the same product behavior. If the Watch cannot reach its paired iPhone, or the iPhone cannot reach Lore's API, Lore keeps the protected recording in a visible retryable state instead of losing it.

## The core experience

### Record

The iPhone's main screen is deliberately minimal and focused. Recording should begin with one subtle, unmistakable action near the bottom of the screen. Shape and motion communicate idle, recording, and processing states without a loud red control, icon, or persistent explanatory text.

The Apple Watch app should make quick capture possible in a few seconds: open Lore, start speaking, stop, and see that the note is saved or waiting to sync. It should show only the state needed to trust the handoff—recording, saved on Watch, transferring, received by iPhone, or needs attention—without recreating the iPhone's reading and editing experience.

### Read the source

The transcript view shows the immutable source artifact and its processing status. Corrections create new transcript versions with provenance; they do not silently overwrite history.

### Read the story

The journal view turns each completed source transcript into a concise, grounded entry. The writing may use the user's preferred perspective and tone, but it must not invent facts. A biography view can later assemble accepted entries across time while preserving links back to their sources.

## Planned feature: private reading, export, and print

When a biography becomes too long to read comfortably on an iPhone, Lore should let the user move the reading experience to a nearby browser without uploading the biography or creating a cloud copy. The iPhone remains the source of truth and temporarily serves a read-only, responsive biography page to another device on the same local network.

The sharing flow should offer three distinct actions:

- **Read on another device:** Start an on-demand local-network reader, then show a QR code, local URL, temporary access code, expiration countdown, and explicit Stop Sharing control.
- **Print:** Open the native iOS print flow directly, with the browser reader also providing print-specific styling for users who print from the second device.
- **Export a copy:** Generate a PDF, EPUB, or self-contained HTML document for AirDrop, Files, and the system share sheet. Export is deliberately separate because it creates a durable copy that Lore can no longer revoke.

### Temporary reader behavior

- Start only after an explicit user action and request Local Network permission in context.
- Use a native, app-embedded listener and bundled reader assets; do not require Node.js, a hosted reader, or a biography backend.
- Accept only local-link/Wi-Fi connections and never expose the listener through Lore's Processing API.
- Protect each session with a cryptographically random URL token plus a separate short access code.
- Keep the token, access code, client sessions, and served biography in memory only.
- Rate-limit failed access-code attempts and allow at most a small, bounded number of concurrent readers.
- Expire automatically after a short user-visible window, proposed as 15 minutes with an option to extend while the app remains active.
- Stop immediately when the user taps Stop Sharing, leaves the sharing flow, the app becomes inactive or backgrounded, or the session expires.
- Provide a responsive long-form reader with adjustable type size, light/dark appearance, a table of contents, source navigation where appropriate, and print CSS.
- Clearly state that the phone must remain unlocked with Lore open and that guest, hotel, VPN, or client-isolated networks may block device-to-device access.

### Privacy and security boundary

The temporary reader is local and ephemeral, but a password over ordinary local HTTP is access control rather than end-to-end transport encryption. Lore should describe the feature as suitable for a trusted local network, not as equivalent to HTTPS. The unguessable URL token, separate access code, short expiration, attempt limits, local-link binding, memory-only state, and immediate teardown reduce exposure without asking the user to install or trust a local certificate.

The app must not misuse an iOS background mode to keep the server alive. It should use public Network framework APIs, provide `NSLocalNetworkUsageDescription`, declare any Bonjour service type it advertises, and shut the listener down predictably with the sharing screen's lifecycle. App Review notes should explain that no biography content is uploaded and give reviewers exact steps for testing the feature on two devices.

### Acceptance criteria

The feature is complete when a user can start a session on a physical iPhone, open the biography from a second device on the same Wi-Fi network, authenticate, read and print it, and revoke access immediately. Tests must also prove that an invalid code is throttled, an expired or stopped URL no longer returns biography content, backgrounding Lore closes the listener, no biography content enters application logs or remote requests, and exported files are created only after a separate explicit action.

## Future feature: printed books

Status: future idea, not scheduled. It builds on the export flow above and the biography assembly in `architecture.md`.

A journal or biography is most valuable as something a family can hold and hand down. Lore should make it easy to turn the archive into a printed book without locking the user into one printer.

### Path 1: print-ready export to any publisher

The user picks what to include and how it should look, and Lore produces open, standard files they own and can take to any print-on-demand service, local print shop, or bookbinder.

- **Contents:** the whole biography, chosen chapters, or journal entries for a date range, with optional photos (one per day, matching the calendar design) and a dedication page.
- **Layout:** a few trim-size presets in common print-on-demand sizes (for example 6×9 in and 8.5×11 in), book typography, a table of contents, page numbers, and running headers.
- **Files:** an interior PDF and a separate cover PDF. The PDFs use embedded fonts, correct bleed and margins, and print-resolution images, and target PDF/X where practical. A reading copy in EPUB can also be exported.
- **Cover:** the cover is a single sheet for the back, spine, and front. Spine width depends on page count and paper stock, so Lore calculates it from the final interior PDF.
- **Privacy:** rendering happens on the iPhone. Nothing is uploaded, and the file leaves Lore only through the share sheet, AirDrop, or Files, following the same explicit-export rule as above.

### Path 2: order a printed book from inside Lore

This is a partnership with a print-on-demand provider, so a user can order a hardcover or paperback without leaving the app. The founder's first choice is Barnes & Noble, whose custom-book printing is very affordable.

Open questions to settle before committing:

- Confirm whether Barnes & Noble offers a partner program or ordering API that lets an app submit a book for personal (non-retail) printing on the user's behalf. If it doesn't, evaluate providers that do publish a print API, such as Lulu, and compare price, quality, shipping regions, and data handling.
- Decide whether Lore takes a margin, passes cost through, or offers printing as a premium benefit.
- Decide how payment works (in-app purchase rules versus physical-goods checkout).

Privacy boundary: ordering a print is the one flow that necessarily sends the book's contents to a third party. It must therefore be:

- a separate, explicit action with a clear disclosure naming the printer and what is sent;
- direct from the iPhone to the provider, or passed through Lore's API without retention, under the same no-persistence rules as inference;
- limited to the generated print files, never the raw archive or audio; and
- clear about the printer's own retention policy, which Lore cannot control.

### Done when

- A user can produce a print-ready PDF that a standard print-on-demand service accepts without layout errors.
- With a partner, a user can order a copy from the app and receive it.
- No book content is uploaded by the export path, and the order path sends only the print files after explicit confirmation.

## Privacy promise

Lore's durable personal archive lives on the user's iPhone and in the user's private CloudKit database. The Apple Watch holds only captures that are being recorded or are waiting for confirmed transfer to the paired iPhone. Provider credentials stay on the Lore server. The server validates and forwards bounded synchronous requests, returns the result, and retains only content-free security metadata needed to prevent replay and paid-inference abuse.

Remote processing requires one concise confirmation during onboarding. It identifies Groq for transcription and Fireworks AI for journal writing, explains that recordings and transcript text are sent for those purposes, and states where the finished story is stored. This disclosure appears once in a contextual confirmation rather than as a recurring card in the product interface.

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

The first complete release ships the iPhone and Apple Watch apps together and is successful when a person can:

1. finish the short onboarding flow and grant one processing permission;
2. record a voice note on a supported physical iPhone over Wi-Fi or cellular;
3. record a voice note on a supported Apple Watch even when the paired iPhone is temporarily unreachable;
4. see the Watch note sync into the same iPhone note history with its capture source preserved;
5. receive an accurate Groq transcript through the Lore API regardless of capture device;
6. see that transcript committed locally before the iPhone's processing copy of the captured audio is deleted;
7. receive a grounded Fireworks journal entry and read it in Lore;
8. close or restart either app during capture handoff or processing without losing the note;
9. retry safely after a Watch transfer, connection, or provider failure without duplicate artifacts; and
10. delete or export their local archive through a deliberate product flow.

## Not in the MVP

- user-selectable compute or privacy modes;
- downloadable inference assets;
- a general-purpose chatbot;
- general cross-device archive sync beyond private CloudKit records and the paired Watch-to-iPhone capture handoff;
- transcript editing, biography reading, or full archive management on Apple Watch;
- automatic factual merging without source links;
- silent audio deletion before a verified transcript exists.
- printed-book export or ordering.

## Near-term sequence

1. Prove physical-device App Attest enrollment against Production.
2. Run a synthetic end-to-end transcription and journal-generation canary.
3. Verify restart recovery, retry, cancellation, and commit-driven audio deletion.
4. Add the companion watchOS target, protected capture, durable Watch-to-iPhone transfer, capture-source provenance, and duplicate-safe import.
5. Validate offline Watch capture, delayed transfer, relaunch recovery, and paired-device behavior on physical devices.
6. Finish the transcript and journal reading experiences.
7. Add correction and provenance workflows for names, dates, and timelines.
8. Build biography assembly and interactive follow-up only after the capture pipeline is trustworthy.
9. Add private biography reading, native printing/export, and the temporary local-network reader after the biography experience is stable.
10. Later: print-ready book export, then an in-app printed-book order through a print partner (see Future feature: printed books).
