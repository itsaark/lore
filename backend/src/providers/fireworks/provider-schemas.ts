import { z } from "zod";
import {
  DailyEntryGenerationResponseSchema,
  GroundedJournalEntrySchema
} from "../../contracts/daily-entry.js";
import { z as reflectionZ } from "zod";

const DailyEntryContentSchema = DailyEntryGenerationResponseSchema.omit({
  schema_version: true,
  prompt_version: true,
  job_id: true,
  request_id: true,
  provenance: true
});

export const FireworksDailyEntryOutputSchema = z.object({
  status: z.enum(["completed", "invalid_input", "refused"]),
  entry: GroundedJournalEntrySchema.nullable(),
  memory_candidates: DailyEntryContentSchema.shape.memory_candidates,
  uncertainties: DailyEntryContentSchema.shape.uncertainties,
  sensitive_omissions: DailyEntryContentSchema.shape.sensitive_omissions,
  quality_flags: DailyEntryContentSchema.shape.quality_flags,
  follow_up_questions: DailyEntryContentSchema.shape.follow_up_questions,
  refusal_reason: z.string().min(1).max(500).nullable()
}).strict();

export const FireworksDailyEntryJsonSchema = z.toJSONSchema(FireworksDailyEntryOutputSchema, {
  target: "draft-7",
  reused: "ref"
});

export const FireworksChatCompletionSchema = z.object({
  id: z.string().min(1),
  model: z.string().min(1),
  choices: z.array(z.object({
    index: z.number().int(),
    message: z.object({
      role: z.string(),
      content: z.string().nullable()
    }).passthrough(),
    finish_reason: z.string().nullable()
  }).passthrough()).length(1)
}).passthrough();

export const FireworksReflectionGuideOutputSchema = reflectionZ.object({
  spoken_text: reflectionZ.string().trim().min(1).max(500),
  should_offer_finish: reflectionZ.boolean()
}).strict();

export const FireworksReflectionGuideJsonSchema = reflectionZ.toJSONSchema(
  FireworksReflectionGuideOutputSchema,
  { target: "draft-7", reused: "ref" }
);

export type FireworksDailyEntryOutput = z.infer<typeof FireworksDailyEntryOutputSchema>;
