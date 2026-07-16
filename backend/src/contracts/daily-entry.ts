import { z } from "zod";
import {
  API_SCHEMA_VERSION,
  ProcessingProvenanceSchema,
  RetentionPolicySchema,
  UuidSchema
} from "./common.js";
import { TranscriptSourceSegmentSchema } from "./transcription.js";

export const DAILY_ENTRY_PROMPT_VERSION = "grounded-journal-v1" as const;

const JournalPerspectiveSchema = z.enum(["first_person", "third_person"]);
const JournalTenseSchema = z.enum(["past", "present"]);

export const DailyEntryGenerationRequestSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  prompt_version: z.literal(DAILY_ENTRY_PROMPT_VERSION),
  job_id: UuidSchema,
  note_id: UuidSchema,
  transcript_artifact_id: UuidSchema,
  transcript_version_id: UuidSchema,
  captured_local_date: z.iso.date(),
  language_code: z.string().min(2).max(35),
  subject: z.object({
    display_name: z.string().min(1).max(120),
    pronouns: z.array(z.string().min(1).max(30)).max(8)
  }).strict(),
  render_configuration: z.object({
    perspective: JournalPerspectiveSchema,
    tense: JournalTenseSchema,
    tone: z.string().min(1).max(80),
    target_words: z.number().int().min(40).max(1_000)
  }).strict(),
  source_segments: z.array(TranscriptSourceSegmentSchema).min(1).max(1_000),
  accepted_prior_facts: z.array(z.object({
    id: z.string().min(1).max(200),
    statement: z.string().min(1).max(2_000),
    status: z.string().min(1).max(80),
    source_references: z.array(z.string().min(1).max(200)).max(100)
  }).strict()).max(500),
  retention_policy: RetentionPolicySchema
}).strict();

export const GroundedJournalEntrySchema = z.object({
  title: z.string().min(1).max(160),
  title_source_references: z.array(z.string().min(1).max(200)).min(1),
  perspective: JournalPerspectiveSchema,
  sentences: z.array(z.object({
    text: z.string().min(1).max(2_000),
    source_references: z.array(z.string().min(1).max(200)).min(1),
    fact_references: z.array(z.string().min(1).max(200)),
    preserves_uncertainty: z.boolean()
  }).strict()).min(1).max(100)
}).strict();

const JournalMemoryCandidateSchema = z.object({
  id: z.string().min(1).max(200),
  kind: z.enum(["person_alias", "relationship", "life_event", "place", "date", "theme", "preference", "correction", "other"]),
  operation: z.enum(["add", "confirm", "correct", "supersede", "flag_conflict"]),
  claim: z.string().min(1).max(2_000),
  confidence: z.enum(["low", "medium", "high"]),
  source_references: z.array(z.string().min(1).max(200)).min(1),
  related_fact_ids: z.array(z.string().min(1).max(200)),
  requires_user_review: z.boolean()
}).strict();

export const DailyEntryGenerationResponseSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  prompt_version: z.literal(DAILY_ENTRY_PROMPT_VERSION),
  job_id: UuidSchema,
  request_id: z.string().min(1).max(200),
  entry: GroundedJournalEntrySchema,
  memory_candidates: z.array(JournalMemoryCandidateSchema),
  uncertainties: z.array(z.object({
    description: z.string().min(1).max(2_000),
    source_references: z.array(z.string().min(1).max(200)).min(1),
    suggested_question: z.string().min(1).max(500).nullable()
  }).strict()),
  sensitive_omissions: z.array(z.object({
    category: z.string().min(1).max(100),
    source_references: z.array(z.string().min(1).max(200)).min(1)
  }).strict()),
  quality_flags: z.array(z.string().min(1).max(200)),
  follow_up_questions: z.array(z.object({
    question: z.string().min(1).max(500),
    reason: z.string().min(1).max(500),
    source_references: z.array(z.string().min(1).max(200)).min(1)
  }).strict()),
  provenance: ProcessingProvenanceSchema
}).strict();

export type DailyEntryGenerationRequest = z.infer<typeof DailyEntryGenerationRequestSchema>;
export type DailyEntryGenerationResponse = z.infer<typeof DailyEntryGenerationResponseSchema>;
