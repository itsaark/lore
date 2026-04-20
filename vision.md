# Lore Vision

Last updated: 2026-04-17

## Product Thesis

Lore is a private biographer for one person.

The user speaks naturally about daily life, old memories, relationships, turning points, and reflections. Lore turns those spoken fragments into a durable, chronological life story written in warm third-person biography prose.

The app is not a voice memo app and not a generic journal. Voice is the input. The biography is the product.

## Core Promise

Speak what happened. Lore remembers what matters.

Lore should feel like a quiet, trusted biographer that gradually understands the user's life without sending personal material to a third-party AI service. The app can use Apple system services such as WeatherKit when the user grants permission, but personal speech, transcripts, extracted memories, and generated prose stay local to the device.

## Target User

The first target user is a single person who wants to build a personal biography over time through journaling and therapy-style reflection.

They may speak about:

- what happened today
- how they felt about something
- childhood memories
- family history
- career moments
- places they lived
- people who shaped them
- losses, wins, regrets, beliefs, and turning points

Stories will not arrive chronologically. A user may record today's reflection in the morning and then talk about a childhood memory at night. Lore must store stories by capture date while also extracting the actual life-event date or time period when it can.

## Initial Experience

The first version should be one-way capture:

1. The user opens Lore.
2. They answer a daily prompt or speak freely.
3. Apple on-device speech recognition creates a transcript.
4. Lore stores temporary audio, raw transcript, metadata, and generated biography prose locally.
5. A local Ternary Bonsai model rewrites the entry into third-person biography prose.
6. Lore extracts people, places, themes, and life events into a local memory graph.
7. The user sees Stories chronologically by capture date first.

No live transcript is required while recording. The recording experience should stay calm and immersive.

## Long-Term Experience

Lore should eventually become two-way.

It should know enough about the user's life to ask thoughtful follow-up questions:

- "You mentioned your father again. Should we capture that story properly?"
- "Was this before or after you moved to Seattle?"
- "What did that moment change for you?"

The app should not become a generic chatbot. It should behave like a patient interviewer and editor whose job is to help the user preserve a coherent life story.

## Narrative Strategy

Default prose style:

Warm, literary, third-person, chronological biography prose. Honest but not clinical. Reflective without sounding dramatic.

The style can become customizable later. The memory graph and source stories should remain stable while the model rewrites chapters in different styles locally.

## Memory Strategy

Lore needs a biographical temporal memory graph, not generic agent memory.

The graph should support non-linear storytelling. The user records stories in any order, and the system stores:

- when the story was captured
- when the remembered event happened, if known
- who was involved
- where it happened
- what themes it relates to
- which biography fragments or chapters it supports
- confidence and provenance back to the source story

The graph must preserve uncertainty. If a user says "this was probably around 2012," the app should store that as an approximate time period, not pretend it knows the exact date.

## Retention Policy

Default retention:

- Audio: delete after 7 days.
- Raw transcripts: keep for 120 days by default.
- Polished story prose: keep until the user deletes it.
- Extracted facts, people, places, events, themes, and biography fragments: keep until the user deletes them.

The user should eventually be able to change transcript retention in settings.

## Privacy Position

Lore is local-first.

Allowed:

- Apple Speech with on-device recognition required.
- Apple WeatherKit with user permission.
- Apple location services with user permission.
- Downloading local model files after explicit user action.

Not allowed in the core product:

- Sending personal speech or transcripts to cloud LLM APIs.
- Storing user biography data on a server.
- Requiring an account for the private local archive.

## Model Strategy

Use MLX Swift with downloadable local Ternary Bonsai models.

Initial model tiers:

- Standard: Ternary Bonsai 4B for iPhone 14+ as the default.
- Best Writing: Ternary Bonsai 8B for capable newer devices.
- Lightweight: Ternary Bonsai 1.7B for lower storage, fast extraction, or fallback tasks.

The app should not bundle large models in the App Store binary. Users download the model after install from a local AI setup screen.

Model access should be centralized behind a local generation service so the product can change model tiers later without rewriting capture, storage, and biography logic.

## Business Model

Lore will be sold as:

- Monthly subscription: approximately $10/month.
- Lifetime purchase: approximately $250 one-time payment for all features for life.

The paid product should unlock the local biography engine, model-powered story processing, memory graph, chapter generation, and future two-way interviewer features.

## Near-Term Priorities

1. Rename the product language from Recordings to Stories.
2. Add onboarding for name, hometown, and birth year.
3. Move persistence from UserDefaults to SwiftData.
4. Store audio assets with 7-day deletion.
5. Store raw transcripts with 120-day retention.
6. Add metadata capture for time, location, and WeatherKit.
7. Add Ternary Bonsai 4B download and local generation.
8. Generate biography prose automatically after each story.
9. Extract life events, people, places, and themes into the local memory graph.
10. Show Stories chronologically first, while preserving enough metadata to later organize by life chronology, chapters, and themes.

## Non-Goals

- Building a cloud journaling product.
- Building a generic AI assistant.
- Building social sharing in the first version.
- Requiring live transcription during recording.
- Treating capture order as life chronology.
