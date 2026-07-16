import { z } from "zod";
import {
  DailyEntryGenerationResponseSchema,
  GroundedJournalEntrySchema
} from "../../contracts/daily-entry.js";

const DailyEntryContentSchema = DailyEntryGenerationResponseSchema.omit({
  schema_version: true,
  prompt_version: true,
  job_id: true,
  request_id: true,
  provenance: true
});

export const GroqDailyEntryOutputSchema = z.object({
  status: z.enum(["completed", "invalid_input", "refused"]),
  entry: GroundedJournalEntrySchema.nullable(),
  memory_candidates: DailyEntryContentSchema.shape.memory_candidates,
  uncertainties: DailyEntryContentSchema.shape.uncertainties,
  sensitive_omissions: DailyEntryContentSchema.shape.sensitive_omissions,
  quality_flags: DailyEntryContentSchema.shape.quality_flags,
  follow_up_questions: DailyEntryContentSchema.shape.follow_up_questions,
  refusal_reason: z.string().min(1).max(500).nullable()
}).strict();

export const GroqDailyEntryJsonSchema = z.toJSONSchema(GroqDailyEntryOutputSchema, {
  target: "draft-7",
  reused: "ref"
});

export const GroqChatCompletionSchema = z.object({
  id: z.string().min(1),
  model: z.string().min(1),
  choices: z.array(z.object({
    index: z.number().int(),
    message: z.object({
      role: z.string(),
      content: z.string().nullable()
    }).passthrough(),
    finish_reason: z.string().nullable()
  }).passthrough()).length(1),
  system_fingerprint: z.string().nullable().optional(),
  x_groq: z.object({ id: z.string().min(1) }).passthrough().optional()
}).passthrough();

export const GroqTranscriptionSchema = z.object({
  text: z.string(),
  language: z.string().nullable().optional(),
  duration: z.number().nonnegative().optional(),
  segments: z.array(z.object({
    id: z.union([z.number().int(), z.string()]).optional(),
    start: z.number().nonnegative(),
    end: z.number().nonnegative(),
    text: z.string(),
    avg_logprob: z.number().optional(),
    no_speech_prob: z.number().optional()
  }).passthrough()).optional(),
  x_groq: z.object({ id: z.string().min(1) }).passthrough().optional()
}).passthrough();

export type GroqDailyEntryOutput = z.infer<typeof GroqDailyEntryOutputSchema>;
