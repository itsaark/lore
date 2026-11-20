import { z } from "zod";
import {
  API_SCHEMA_VERSION,
  ProcessingProvenanceSchema,
  RetentionPolicySchema,
  UuidSchema
} from "./common.js";
import { TranscriptSourceSegmentSchema } from "./transcription.js";

/** The version new clients send. v1 stays accepted for older builds and in-flight jobs. */
export const DAILY_ENTRY_PROMPT_VERSION = "grounded-journal-v2" as const;
export const DAILY_ENTRY_PROMPT_VERSIONS = ["grounded-journal-v1", "grounded-journal-v2"] as const;
export const DailyEntryPromptVersionSchema = z.enum(DAILY_ENTRY_PROMPT_VERSIONS);
export type DailyEntryPromptVersion = z.infer<typeof DailyEntryPromptVersionSchema>;

const JournalPerspectiveSchema = z.enum(["first_person", "third_person"]);
const JournalTenseSchema = z.enum(["past", "present"]);

const RememberedTimeSchema = z.discriminatedUnion("precision", [
  z.object({
    precision: z.enum(["week", "month", "year", "span"]),
    start_date: z.iso.date(),
    end_date: z.iso.date()
  }).strict().refine(({ start_date, end_date }) => end_date >= start_date, {
    path: ["end_date"],
    message: "End date must be on or after start date"
  }),
  z.object({ precision: z.literal("as_spoken") }).strict()
]);

export const DailyEntryGenerationRequestSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  prompt_version: DailyEntryPromptVersionSchema,
  job_id: UuidSchema,
  note_id: UuidSchema,
  transcript_artifact_id: UuidSchema,
  transcript_version_id: UuidSchema,
  captured_local_date: z.iso.date(),
  remembered_time: RememberedTimeSchema.optional(),
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
}).strict().refine(
  ({ captured_local_date, remembered_time }) =>
    !remembered_time || remembered_time.precision === "as_spoken" || remembered_time.start_date <= captured_local_date,
  { path: ["remembered_time", "start_date"], message: "Start date must be on or before capture date" }
);

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
  prompt_version: DailyEntryPromptVersionSchema,
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

// MARK: - Model Lab (development builds only)

/** Prompt versions the DEBUG Model Lab may compare. Production stays on v1. */
export const DAILY_ENTRY_LAB_PROMPT_VERSIONS = DAILY_ENTRY_PROMPT_VERSIONS;
export const DailyEntryLabPromptVersionSchema = DailyEntryPromptVersionSchema;
export type DailyEntryLabPromptVersion = z.infer<typeof DailyEntryLabPromptVersionSchema>;

export const DAILY_ENTRY_LAB_MODEL_ALIASES = [
  "gpt-oss-120b",
  "deepseek-v4-flash",
  "deepseek-v4p1-flash",
  "glm-5p3",
  "glm-5p3-flash",
  "minimax-m3"
] as const;
export const DailyEntryLabModelAliasSchema = z.enum(DAILY_ENTRY_LAB_MODEL_ALIASES);
export type DailyEntryLabModelAlias = z.infer<typeof DailyEntryLabModelAliasSchema>;

export const DailyEntryLabRequestSchema = DailyEntryGenerationRequestSchema.safeExtend({
  prompt_version: DailyEntryLabPromptVersionSchema,
  lab_model: DailyEntryLabModelAliasSchema
}).strict();

export const DailyEntryLabResponseSchema = DailyEntryGenerationResponseSchema.extend({
  prompt_version: DailyEntryLabPromptVersionSchema,
  lab_model: DailyEntryLabModelAliasSchema,
  usage: z.object({
    prompt_tokens: z.number().int().min(0).nullable(),
    completion_tokens: z.number().int().min(0).nullable()
  }).strict()
}).strict();

export type DailyEntryLabRequest = z.infer<typeof DailyEntryLabRequestSchema>;
export type DailyEntryLabResponse = z.infer<typeof DailyEntryLabResponseSchema>;
