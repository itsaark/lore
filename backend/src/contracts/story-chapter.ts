import { z } from "zod";
import { GroundedJournalEntrySchema } from "./daily-entry.js";
import {
  API_SCHEMA_VERSION,
  ProcessingProvenanceSchema,
  RetentionPolicySchema,
  UuidSchema
} from "./common.js";

export const STORY_CHAPTER_PROMPT_VERSION = "story-chapter-v1" as const;

/**
 * One finished day, as the person's own journal already tells it. A chapter is
 * written from these entries, never from raw transcripts.
 */
export const StoryChapterSourceDaySchema = z.object({
  /** Stable reference the writer cites, e.g. the day's key. */
  id: z.string().min(1).max(200),
  day_key: z.iso.date(),
  title: z.string().max(200),
  prose: z.string().min(1).max(20_000)
}).strict();

export const StoryChapterGenerationRequestSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  prompt_version: z.literal(STORY_CHAPTER_PROMPT_VERSION),
  job_id: UuidSchema,
  /** The calendar month this chapter covers, "YYYY-MM". */
  chapter_key: z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/),
  language_code: z.string().min(2).max(35),
  subject: z.object({
    display_name: z.string().min(1).max(120),
    pronouns: z.array(z.string().min(1).max(30)).max(8)
  }).strict(),
  render_configuration: z.object({
    perspective: z.enum(["first_person", "third_person"]),
    tense: z.enum(["past", "present"]),
    tone: z.string().min(1).max(80),
    target_words: z.number().int().min(80).max(2_000)
  }).strict(),
  source_days: z.array(StoryChapterSourceDaySchema).min(1).max(62),
  retention_policy: RetentionPolicySchema
}).strict();

export const StoryChapterGenerationResponseSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  prompt_version: z.literal(STORY_CHAPTER_PROMPT_VERSION),
  job_id: UuidSchema,
  request_id: z.string().min(1).max(200),
  /** Title plus sentences; each sentence cites the source day ids it draws on. */
  entry: GroundedJournalEntrySchema,
  provenance: ProcessingProvenanceSchema
}).strict();

export type StoryChapterGenerationRequest = z.infer<typeof StoryChapterGenerationRequestSchema>;
export type StoryChapterGenerationResponse = z.infer<typeof StoryChapterGenerationResponseSchema>;
