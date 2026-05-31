# Lore Architecture

Last updated: 2026-04-19

## Architectural Principles

Lore is a local-first iOS app. The architecture should protect user trust, support years of non-linear storytelling, and keep the local model replaceable.

Principles:

- Personal speech, transcripts, generated prose, and memory graph data stay local.
- Capture order is not the same as life chronology.
- Every generated fact must be traceable back to a source story.
- The system should preserve uncertainty instead of inventing exact dates.
- MLX and Ternary Bonsai are central, but app features should call them through a clean generation service.
- SwiftData should own app data; temporary audio should live in the file system with metadata in SwiftData.

## High-Level Pipeline

```text
Record audio
  -> on-device Apple Speech transcript
  -> Story saved in SwiftData
  -> metadata attached: capture time, location, weather, prompt
  -> local model writes third-person biography prose
  -> local model extracts memory graph candidates
  -> graph merge resolves entities, events, relationships, and uncertainty
  -> timeline and biography fragments update
```

The pipeline should run after recording stops. It does not need to be live.

## Core Modules

### CaptureService

Owns audio recording and audio file creation.

Responsibilities:

- Start and stop recording.
- Write audio to local file storage.
- Emit audio levels for the recording glow.
- Create `AudioAsset` records with `createdAt` and `expiresAt`.

### SpeechTranscriptionService

Owns Apple Speech integration.

Responsibilities:

- Require on-device speech recognition.
- Check `supportsOnDeviceRecognition`.
- Refuse cloud fallback.
- Produce raw transcript text.

### StoryStore

SwiftData-backed persistence boundary.

Responsibilities:

- Save stories, prompts, metadata, generated prose, graph records, and biography fragments.
- Expose query methods for chronological story views.
- Support future life-chronology and chapter/theme views.

### MetadataService

Captures contextual metadata with permission.

Responsibilities:

- Capture date and local time.
- Capture location when allowed.
- Fetch WeatherKit conditions when allowed.
- Store metadata snapshots, not live dependencies.

### ModelManager

Owns local model lifecycle.

Responsibilities:

- Download selected Ternary Bonsai model after user consent.
- Verify files and available storage.
- Load/unload MLX models.
- Choose model tier by device capability and user setting.

Initial tiers:

- `Ternary-Bonsai-4B-mlx-2bit` as default.
- `Ternary-Bonsai-8B-mlx-2bit` as best writing option.
- `Ternary-Bonsai-1.7B-mlx-2bit` as lightweight fallback.

### GenerationService

Single app-facing boundary for local LLM tasks.

Responsibilities:

- `writeBiographyProse(from:)`
- `extractMemoryGraph(from:)`
- `generateDailyPrompt(context:)`
- `rewriteChapter(_:style:)`
- `summarizeStory(_:)`

Feature code should not call MLX directly.

### MemoryGraphService

Owns graph extraction, merge, and retrieval.

Responsibilities:

- Convert model-extracted candidates into durable graph records.
- Merge duplicate people, places, themes, and events.
- Preserve confidence, provenance, and temporal uncertainty.
- Retrieve graph context for biography writing.

### BiographyEngine

Owns narrative assembly.

Responsibilities:

- Create biography fragments from stories.
- Maintain a chronological timeline.
- Later, assemble chapter-based or theme-based biography views.
- Link every generated fragment to supporting stories and facts.

### RetentionService

Owns local cleanup.

Responsibilities:

- Delete audio files after 7 days.
- Delete raw transcripts after the configured retention window, default 120 days.
- Keep generated biography prose and graph facts unless the user deletes them.
- Run on app launch and via background maintenance when possible.

## Data Model

### UserProfile

- `id`
- `name`
- `hometown`
- `birthYear`
- `createdAt`
- `updatedAt`
- future: preferred writing style, pronouns, important life eras

### Story

Represents one user capture session.

- `id`
- `captureDate`
- `rawTranscript`
- `rawTranscriptExpiresAt`
- `biographyProse`
- `title`
- `promptId`
- `audioAssetId`
- `metadataId`
- `processingStatus`
- `createdAt`
- `updatedAt`

Important: `captureDate` is when the user told the story, not necessarily when the event happened.

### AudioAsset

- `id`
- `fileURL`
- `createdAt`
- `expiresAt`
- `duration`
- `isDeleted`

### StoryMetadata

- `id`
- `captureDate`
- `timezone`
- `locationName`
- `latitude`
- `longitude`
- `weatherSummary`
- `temperature`
- `weatherSource`
- `permissionSnapshot`

### LifeEvent

The backbone of the biography graph.

- `id`
- `title`
- `summary`
- `eventDateKind`: exact, approximate, range, unknown
- `eventStartDate`
- `eventEndDate`
- `approximateLabel`
- `confidence`
- `sourceStoryIds`
- `createdAt`
- `updatedAt`

Examples:

- "Moved to Seattle"
- "Met Priya"
- "Started first company"
- "Childhood summers in Hyderabad"

### Person

- `id`
- `displayName`
- `aliases`
- `relationshipToUser`
- `summary`
- `confidence`
- `sourceStoryIds`

### Place

- `id`
- `displayName`
- `placeKind`
- `locationHint`
- `summary`
- `sourceStoryIds`

### Theme

- `id`
- `name`
- `summary`
- `sourceStoryIds`

Examples:

- ambition
- grief
- family duty
- migration
- reinvention

### MemoryFact

Represents a source-grounded claim.

- `id`
- `subjectId`
- `predicate`
- `objectId`
- `text`
- `validFrom`
- `validTo`
- `timeCertainty`
- `confidence`
- `sourceStoryId`
- `sourceTextSpan`
- `createdAt`
- `supersededByFactId`

Examples:

- `user lived_in Hyderabad during childhood`
- `user moved_to Seattle around 2018`
- `father encouraged user to study engineering`

### BiographyFragment

- `id`
- `storyId`
- `lifeEventIds`
- `chapterId`
- `prose`
- `style`
- `modelName`
- `modelVersion`
- `createdAt`
- `updatedAt`

### BiographyChapter

- `id`
- `title`
- `chapterKind`: chronological, theme, relationship, place
- `orderIndex`
- `prose`
- `supportingFragmentIds`
- `createdAt`
- `updatedAt`

## Retrieval Strategy

Use hybrid local retrieval:

- Chronology for timeline views.
- Full-text search for names and exact phrases.
- Embeddings for fuzzy recall.
- Graph traversal for relationships and life events.

The first implementation can store embeddings locally and run brute-force cosine search because the expected data size is small. Later, move to a local vector index if needed.

## Handling Non-Linear Storytelling

Users will not tell their life in order. The architecture must separate:

- `captureDate`: when the story was recorded.
- `eventDate`: when the remembered event happened.
- `eventDateKind`: exact, approximate, range, unknown.
- `approximateLabel`: "childhood", "college years", "around 2012", "before moving to Seattle".

The Stories screen can start as capture-date chronological. The Life timeline should use event dates and approximate periods when available.

## Business Model Support

The app should support:

- Monthly subscription, approximately $10/month.
- Lifetime unlock, approximately $250 one-time purchase.

Entitlement checks should gate premium features, not local data access. If a subscription lapses, the user's existing local stories and biography should remain readable. Premium gating should apply to ongoing model-powered processing, new chapter generation, advanced memory views, and future two-way interviewer features.

## First Implementation Slice

1. [x] Add SwiftData models for `UserProfile`, `Story`, `AudioAsset`, `StoryMetadata`, and `BiographyFragment`.
2. [x] Rename UI language from Recordings to Stories.
3. [x] Add onboarding for name, hometown, and birth year.
4. [x] Add audio asset lifecycle and 7-day deletion.
5. [x] Add 120-day raw transcript retention metadata.
6. [x] Add local model download shell for Ternary Bonsai 4B.
7. [x] Add `GenerationService` abstraction.
8. [x] Implement transcript-to-biography-prose generation with real local MLX inference.
9. [ ] Add initial graph candidate extraction for people, places, themes, and life events.
10. [ ] Display chronological Stories with generated biography prose from the real local model.
