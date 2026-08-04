# Lore End-to-End Delivery Plan

Last updated: 2026-08-04

## End goal

A person can install Lore on a signed physical iPhone, grant one processing permission, record a note, and receive both a locally stored source transcript and a grounded journal entry. Audio is deleted from the phone only after the transcript commit succeeds. Lore's backend and database persist no user content.

## Fixed product requirements

- All transcription and journal generation use the Lore Processing API.
- Groq is the transcription provider; Fireworks is the daily-entry provider.
- Wi-Fi and cellular follow the same route.
- There is no compute-mode picker, device-capability routing, downloadable model, or provider choice in the app.
- The iPhone is the canonical durable store.
- Remote permission is requested once with a concise provider/purpose disclosure.
- The app remains recoverable across network loss, provider failure, cancellation, and process termination.

## Current status

### Implemented

- [x] Production API routes and versioned provider-neutral contracts
- [x] Direct Groq transcription adapter
- [x] Direct Fireworks structured daily-entry adapter
- [x] Strict request/response validation and content-free logging
- [x] iOS HTTPS client and remote service wiring
- [x] App Attest client/server contracts and anonymous session flow
- [x] Neon schemas for App Attest, rate limits, processing leases, and cleanup
- [x] Local Story, transcript artifact/version, ProcessingJob, daily-entry result, and biography-fragment persistence
- [x] Commit-driven audio deletion
- [x] Daily-entry retry and restart recovery
- [x] Complete daily-entry result persistence
- [x] Remote-only routing on Wi-Fi and cellular
- [x] One processing permission; no mode or model settings
- [x] Mocked iOS and backend tests

### Not yet proven in Production

- [ ] Production Neon instance exists and migrations `001`–`003` are applied
- [ ] All seven Production secrets are present and valid
- [ ] App Attest capability and signed entitlements work on the owner's physical device
- [ ] Groq organization ZDR is verified for Audio Transcriptions
- [ ] Fireworks open-model ZDR and volatile-cache behavior are approved
- [ ] Synthetic audio completes the real iPhone → Vercel → Groq → iPhone flow
- [ ] The resulting transcript completes the real iPhone → Vercel → Fireworks → iPhone flow
- [ ] Logs and Neon rows are audited and contain no user content
- [ ] Retry, restart, cancellation, and duplicate submission are exercised on a physical phone

## Workstream 1: Production infrastructure

### Requirements

1. The Vercel project imports this GitHub repository, uses `backend` as Root Directory, and deploys only `main` to Production.
2. A Production-only Neon integration injects pooled `DATABASE_URL`.
3. Migrations are applied in order:
   - `001_app_attest_auth.sql`
   - `002_processing_leases.sql`
   - `003_security_metadata_cleanup.sql`
4. Exactly these Production variables exist:
   - `FIREWORKS_API_KEY`
   - `GROQ_API_KEY`
   - `DATABASE_URL`
   - `CRON_SECRET`
   - `LORE_SESSION_SIGNING_SECRET`
   - `LORE_AUTH_STATE_HMAC_SECRET`
   - `LORE_AUTH_RECEIPT_ENCRYPTION_KEY`
5. `GET /v1/health` returns `200`; processing routes reject missing authorization before a provider call.

### Verification

- `npm run typecheck` passes.
- `npm test` passes.
- Vercel Production deployment is sourced from the latest `main` commit.
- The cleanup cron can execute with `CRON_SECRET` and cannot be invoked with an invalid secret.
- Database inspection shows only the columns defined in migrations `001`–`003`.

### Done when

The Production API is healthy, authentication state is transactionally durable, and no provider call can occur without an authorized, validated, leased request.

## Workstream 2: Provider privacy gates

### Requirements

1. Verify Groq ZDR in the organization serving `GROQ_API_KEY` and record the review date outside source control.
2. Confirm the selected endpoint/model is covered and no File or Batch API is used.
3. Review Fireworks' current open-model data-handling terms.
4. Explicitly accept or mitigate its documented volatile prompt-cache lifetime before real-user text is enabled.
5. Confirm neither provider trains on Lore request content under the selected configuration.

### Verification

- Run provider canaries using synthetic content only.
- Inspect provider dashboards for stored files, batches, conversations, or request content; none should be created by Lore.
- Inspect Vercel logs and verify only allowlisted metadata appears.

### Done when

The privacy claim in the onboarding disclosure and App Store materials matches the providers' actual configuration and documented behavior.

## Workstream 3: Physical-device authentication

### Requirements

1. Enable App Attest for App ID `cascadianpines.lore`.
2. Ensure the signed Debug profile uses Apple's development App Attest environment and distribution profiles use production.
3. Install from Xcode on the owner's physical device and complete first-key attestation.
4. Obtain and reuse a short-lived Lore session; renew it with an assertion after expiry.
5. Verify reinstall/key-loss behavior creates a new valid key.

### Verification

- Invalid, expired, replayed, wrong-purpose, wrong-key, wrong-app, and non-increasing-counter attempts fail before provider invocation.
- Concurrent assertion or challenge consumption has one winner.
- App Attest identifiers and receipts never enter logs.

### Done when

A signed physical-device build can authorize Production processing without any provider or static API secret in the app.

## Workstream 4: Transcription lifecycle

### Requirements

1. Starting a capture creates a protected audio file and durable Story/job state.
2. Stopping submits the bounded file to Groq through Lore's API.
3. The app validates and atomically persists transcript artifact, immutable version, segment/provenance data, story state, and job success.
4. Only that successful commit triggers audio deletion.
5. Empty, invalid, offline, timeout, or server failures retain the audio and a retryable job.
6. Wi-Fi and cellular behave identically.

### Verification

- Kill the app while recording, uploading, and committing.
- Disable the network before and during upload.
- Force 401, 409, 429, provider 5xx, malformed response, and local save failure.
- Confirm audio is present until a transcript exists and absent afterward.
- Confirm one story produces one canonical transcript artifact despite retries.

### Done when

No tested interruption loses the only copy of a recording or produces a transcript without provenance.

## Workstream 5: Daily-entry lifecycle

### Requirements

1. A committed transcript creates one durable daily-entry job.
2. `DailyEntryJobRunner` resumes eligible jobs after launch and schedules bounded retries.
3. The Fireworks request contains only the bounded source package.
4. The response must pass schema and source-grounding validation.
5. Persistence installs the complete immutable result and biography fragment idempotently.
6. Cancellation prevents later automatic execution.

### Verification

- Kill the app before request, during request, and after response but before save.
- Exercise concurrent duplicates and an expired backend lease.
- Return an invented source ID, missing artifact, malformed JSON, and mismatched job ID; each must fail without partial prose persistence.
- Confirm retry eventually produces one result artifact.

### Done when

Every visible journal entry is traceable to a committed transcript and a complete validated generation result.

## Workstream 6: Onboarding and user experience

### Requirements

1. Onboarding asks only for the minimum profile information required by the current product.
2. One concise screen identifies Groq and Fireworks, the data sent, the processing purpose, server non-persistence, and device-resident result.
3. One CTA grants the permission and continues.
4. No routing, model, hardware, or network-choice UI appears in onboarding or Settings.
5. Recording status is conveyed through the minimal animated recording surface.

### Verification

- Fresh install completes without encountering a mode picker.
- An upgraded install with earlier permission fields migrates without another technical settings flow.
- VoiceOver labels and Dynamic Type remain usable.
- Revoking permission prevents new uploads; regranting uses the same single disclosure.

### Done when

A new user can understand the one material data-sharing choice without being asked to configure Lore's infrastructure.

## Final release gate

The MVP is end-to-end ready only when all of the following are true:

- iOS build and full tests pass;
- backend typecheck and full tests pass;
- latest `main` is deployed to Vercel Production;
- Neon migrations and cleanup are verified;
- provider privacy gates are recorded;
- physical-device App Attest works;
- synthetic transcription and journal generation succeed;
- commit-driven deletion and recovery scenarios pass; and
- Vercel logs and Neon contain no user content.

Until then, the implementation may be code-complete but should be described as awaiting Production canary verification.
