# Narrative Voice Plan: Writing Like a Biographer

Status: proposed. No step is implemented yet.
Date: 2026-11-14

## Goal

Lore's daily entries and biography should read like the work of narrative biographers such as David McCullough (*The Wright Brothers*, *John Adams*) and Walter Isaacson (*Steve Jobs*, *Leonardo da Vinci*). That means prose that is vivid, set in a real time and place, and built on specific detail, while remaining just as truthful as today's entries.

The daily note should already have this quality. Over time the biography gets the full treatment, with deeper research, chapter arcs, and a process closer to how a ghostwriter and editor work together.

## The central idea: research instead of invention

The current prompt (`grounded-journal-v1`) forbids scene details because a model left alone will invent them: "the smell of coffee", "a grey sky". McCullough's scenes are vivid and still true, because every detail comes from a record: weather logs, letters, newspapers, the diary of someone who was there.

Lore can do the same thing. The phone already captures when and where each note was recorded, plus the weather. A research step adds verifiable public context about that time and place. The writer may then set a scene, but only with details that come from one of two sources:

1. **What the person said** (transcript segments), which is the only evidence about their life, actions, feelings, and the people in it; and
2. **Researched context** (new "context items" with IDs), which is the only evidence about the world around them: weather, light, season, holidays, and public events.

Every sentence still cites its sources, and context items get their own IDs, so the existing validation extends naturally. Context may set the stage, but it can never be used to say anything about the person they didn't say themselves. "The first frost of the year had settled over Portland" is allowed if the weather record supports it. "She felt the cold as she walked to work" is not, unless she said so.

## The craft, written as rules the model can follow

Naming authors in the prompt tends to produce imitation and clichés. The prompt instead describes the craft they share:

- **Open on something concrete.** Start with a moment, place, or image from the source, not a summary.
- **Use the telling detail.** One precise, specific detail beats three general ones. Use the person's own unusual words and particulars.
- **Let people speak.** Quote short phrases the person actually said when they carry voice or feeling.
- **Place the day in its world.** Lightly connect the personal moment to time, place, and season, using cited context only.
- **Understate.** Use plain, confident sentences, with no adjective pile-ups and no dramatic or therapeutic framing. Let significance come from arrangement, not from commentary.
- **Find the thread.** End on what the day seems to matter for, but only when the person said why it mattered. Otherwise end on the image.
- **Respect uncertainty.** Keep "she thinks it was 1987" as uncertain as it was said. That honesty is part of the biographer's voice.

## Privacy rules for research

Research is the first feature that looks up information *about the user's circumstances*. It follows these rules:

1. **No user content in any lookup, ever.** Queries contain only a coarsened place and a date: city or metro area, never coordinates or a street. They never include transcript text, names, or topics from the note.
2. **On-device first.** Weather (WeatherKit, already captured), sunrise, sunset, moon phase, season, and public holidays are computed or fetched on the phone. Nothing about them reaches Lore's servers.
3. **Public events are shared, not personal.** The phone asks the Lore API for the *public daily digest* for a metro area and date, for example notable local and world events and an unusual weather event. That digest is the same for everyone who asks, so the server can cache it as public data. The cache key is (metro, date) only. Requests are not logged against a session or installation, the cache never records who asked, and nothing from the note is sent.
4. **Selection happens with the note, not with the search.** Choosing which context items are relevant happens inside the normal, request-ephemeral writing call, alongside the transcript. Research and the writing call are never combined into a query that reveals note content to a search provider.
5. **Topic-specific research (for example "the 1998 ice storm" mentioned in a story) is deferred.** If it is ever added, it requires a separate design review. Queries would need to be generic, run through a provider with zero data retention, and be approved or visible to the user.
6. **Visible to the user.** Context sentences can be shown subtly differently, and tapping shows the source ("Weather: NOAA / WeatherKit"). This also feeds the planned "what left your phone" receipt.

## Steps

Each step ships on its own, behind its own prompt version, and is judged against the previous one before it replaces it.

### Step 0: the Journal section of the Lab

All model and prompt evaluation lives in **one place**: the existing DEBUG-only Transcription Lab (Settings → Developer). It becomes the **Model Lab**, with two sections, Transcription (as today) and Journal (new). Nothing about evaluation is spread through the rest of the app.

Being DEBUG-only also keeps it out of TestFlight and App Store builds, which are Release builds, so there is nothing to strip out before launch. If the founder later wants to run it on a TestFlight build, it would need an internal-only gate instead. That is deliberately out of scope for now.

The Journal section:

- **Inputs:**
  - Lab clips that already have a corrected reference transcript;
  - pasted text;
  - existing notes chosen from the journal.

  The set should cover mundane days, emotional days, childhood memories told today, uncertain dates, and several people. The target is 30 to 50 inputs.
- **Candidates:** a writer is a (model, prompt version) pair, such as DeepSeek V4 Flash with `grounded-journal-v1`, the same model with v2, or GLM 5.3 with v2. See "Writer candidates" below. Server candidates go through Lore's API as usual. The backend accepts a DEBUG-only candidate override only from development App Attest sessions.
- **Blind comparison:** outputs are shown as A, B, C in a shuffled order. The model name is revealed only after scoring.
- **Founder scoring:**
  - faithfulness from 1 to 5;
  - tap any sentence to mark it as unsupported or invented;
  - narrative quality from 1 to 5;
  - which output is preferred;
  - an optional note.
- **Automatic checks:** citation validity (as the backend already does), length, and a count of proper nouns not present in the source.
- **Claude scoring:** the Lab exports a `results.json` per input, like the transcription clips do. Claude can then score narrative quality and flag likely inventions against the source to give a second opinion. The founder's faithfulness score is the deciding one.
- Results roll up into the tracking table at the end of this doc.

### Step 1: biographer voice for the daily entry (prompt only)

- Write `grounded-journal-v2`, which keeps every faithfulness rule and adds the craft rules above. Scene details may come only from the person's own words. It also tells the model to prefer the person's short quotes and a concrete opening.
- Add a few non-copyrighted example passages written for Lore, showing the voice in a "before and after" form.
- Revisit the defaults: `tone: warm_restrained` may become `narrative_restrained`, and `targetWords` 130 may need to rise to about 180–220. Check this against the evaluation set.
- This needs a coordinated app and backend change, because the iOS client sends `prompt_version` (`RemoteProcessingProvider.swift`). The backend should accept both v1 and v2 during rollout.
- **Done when** the founder prefers v2 in a blind comparison on most of the set, with no drop in faithfulness.

### Step 2: context from the phone (time, place, weather, light)

- Add a `context_items[]` array to the daily-entry request. Each item has an `id`, a `kind` (weather, daylight, season, holiday, place), a `statement`, a `source`, and a `granularity`. Items are built on the device from data Lore already captures (`MetadataService`, WeatherKit) plus local calculations (sun, moon, holidays).
- The location in an item is coarsened to the city level.
- Sentences get `context_references`, and the validator rejects any context ID that wasn't sent. A sentence may not cite *only* context unless it is a scene-setting sentence that makes no claim about the person.
- No new servers or third parties are involved.
- **Done when** entries gain an occasional grounded sense of place and time, the faithfulness score holds, and the privacy tests show no change in what is sent.

### Step 3: the public daily digest (world context)

- Add a Lore API endpoint that returns a cached public digest for a (metro, date) pair: a handful of notable events with a source for each.
- Choose the provider by licensing and privacy terms. Options are a news or events API, Wikipedia's current-events portal, and public weather records. No content is logged.
- The digest items become `context_items` like those in step 2. The writer uses them rarely: only when an event plausibly touches the day ("the morning after the city's marathon"), and never by claiming the person took part unless they said so.
- **Done when** world context appears selectively and accurately, and an audit of logs and the cache shows they hold only (metro, date) keys.

### Step 4: the biography gets the full treatment

This builds on the layered memory design in `architecture.md` ("Biography memory and chapter assembly"). Chapter writing becomes a small editorial pipeline. Each role is a separate, bounded call with its own schema, not a free-roaming agent:

1. **Researcher:** gathers each chapter's period context (eras, places, public events across the chapter's years) using the same privacy rules, at the year and metro level.
2. **Writer:** drafts the chapter from period summaries, entity profiles, facts, quotes, and context, with every claim cited.
3. **Fact-checker:** independently checks each cited claim against its fact quote or context item, and flags any proper noun, date, or detail without support.
4. **Editor:** revises for craft (opening, pacing, telling details, chapter arc) without adding claims. Any change that adds a claim goes back through the fact-checker.

The stronger model handles chapters and the faster model handles daily entries, following the idea in Letta's *Sleep-time Compute*.

**Done when** chapters pass the fact-checker with zero unsupported claims and the founder would happily hand a chapter to family.

### Step 5: the ghostwriter relationship (later)

- **Interviewer:** Reflect asks the questions a biographer would ask to fill gaps in the biography ("What was the house on Elm Street like?"), using the uncertainties and gaps the biography pipeline finds.
- **Voice profile:** a learned style sheet of the person's own phrases and rhythms, so the prose sounds like their life told by a sympathetic writer, not a generic one.
- **Manuscript review:** the user can accept, reject, or annotate passages, and those edits feed back as corrections.

## Where the writing runs (decided 2026-11-14)

**Quality comes first.** Transcription is already on the device for English (commit `2fadab5`). Writing daily entries and the biography uses the best available models on the server, in the same request-ephemeral way as today. Writing moves onto the phone only when models and phones are good enough to match server quality in the Lab.

### Daily pipeline

```text
iPhone: on-device transcript (source of truth, never leaves except for this one request)
  + on-device context items (weather, daylight, season, holiday, city): step 2
  + public digest items for (metro, date) from Lore's shared cache: step 3
  + narrator profile and relevant accepted facts
  -> one bounded package to the Lore API (App Attest session)
Lore API (holds the package in memory only for this request):
  -> writer model drafts the entry with every sentence cited
  -> validator checks citations, proper nouns, and context-only sentences
  -> optional second pass: a checker call reviews faithfulness and returns flags
  -> returns entry + memory candidates + flags; nothing is written to disk, logs, or the database
iPhone: stores the entry in SwiftData and private CloudKit; the server holds nothing
```

This is the current contract with three additions: context items, an optional checker pass, and a stronger writer.

### Writer candidates (decided 2026-11-14: cheap open models on Fireworks only)

The founder's constraint is no expensive models. Writing stays on open-weight models served by **Fireworks**, which already passes Lore's provider gates. Fireworks' pricing page states "zero data retention by default" on serverless. No new provider is needed.

Prices are Fireworks Standard serverless, per million tokens, from its pricing page on 2026-11-14. Writing quality is EQ-Bench Creative Writing v3 Elo as reported by third-party trackers (llmlearner.com, Oct 2026). Those trackers disagree with each other, so treat the scores as indicative only. They measure fiction-style writing, **not faithfulness**.

| Candidate | Input / output price | Writing Elo (rank of 117) | Est. cost per daily entry* | Role |
| --- | --- | --- | --- | --- |
| GPT-OSS 120B (**production today**, since 2026-08-05) | $0.15 / $0.60 | 956 (#100) | about $0.001 | Baseline |
| DeepSeek V4 Flash | about $0.22 / $1.20 (reported) | 1559 (#50) | about $0.002 | Earlier production model |
| **GLM 5.3** | $1.40 / $4.40 | **2077 (#6)**. The top open model on this board after Kimi K3, and above several closed models | about $0.01 | **Main candidate for the biographer voice**, for daily entries and chapters |
| DeepSeek V4.1 Flash | $0.30 / $1.20 | 1540 (#53) | about $0.003 | Cheap fallback |
| GLM 5.3 Flash | $0.15 / $0.50 | not listed | about $0.001 | Cheapest option; Lab to check its quality |
| MiniMax M3 | $0.30 / $1.20 | not listed (M2.5 was 1362) | about $0.003 | Optional |
| *Excluded:* Kimi K3 | $3.00 / $15.00 | 2084 (#5) | about $0.03 | Barely better than GLM 5.3 at about three times the cost |

\*The estimate assumes about 3k input and 1.5k output tokens per entry. At one entry a day, GLM 5.3 costs about **$0.30 per user per month**.

Caveats to check in the Lab:

- High writing scores don't guarantee the model follows Lore's grounding rules. Letta's production-memory evaluation found GLM-5.2 weaker on memory hygiene and adherence, so faithfulness must be scored before switching.
- Fireworks keeps a bounded prompt or KV cache in volatile memory. Lore already sets `prompt_cache_isolation_key` per request. This is unchanged from today's accepted behaviour; see `inference-strategy.md`.
- Re-confirm the zero-data-retention setting for any newly chosen model, as for the current one.

### On-device writing (later)

Revisit when the Lab shows a local model matching the server writer:

- **Liquid LFM3-1.7B** (about 1 GB at 4-bit, built for extraction; LFM Open License, free under US$10M revenue). The most likely first local step is **fact extraction**, not prose.
- **Apple Foundation Models** (requires iPhone 15 Pro or later).
- Desert Ant Labs has no writing model. Its Redact model stays relevant for the deferred PII-redaction step.

Reading: *TrueBrief: Faithful Summarization through Small Language Models* (arXiv 2601.04212).

## Tracking

| Step | Prompt version | Status | Result |
| --- | --- | --- | --- |
| 0. Evaluation set | — | built: Model Lab → Journal writing (2026-11-14) | waiting for the founder's scores |
| 1. Biographer voice | `grounded-journal-v2` | prompt written; Lab-only, production still on v1 | |
| 2. On-device context | `grounded-journal-v3` | not started | |
| 3. Public digest | `grounded-journal-v4` | not started | |
| 4. Editorial pipeline | chapter prompts v1 | not started | |
| 5. Ghostwriter | — | not started | |
