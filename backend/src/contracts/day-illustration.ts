import { z } from "zod";
import {
  API_SCHEMA_VERSION,
  ProcessingProvenanceSchema,
  RetentionPolicySchema,
  UuidSchema
} from "./common.js";

export const DAY_ILLUSTRATION_PROMPT_VERSION = "day-illustration-v1" as const;
export const DAY_SCENE_MODEL_ALIAS = "day-scene-v1" as const;
export const DAY_SCENE_MAX_CHARACTERS = 800;

export const DayIllustrationGenerationRequestSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  prompt_version: z.literal(DAY_ILLUSTRATION_PROMPT_VERSION),
  job_id: UuidSchema,
  day_key: z.iso.date(),
  language_code: z.string().min(2).max(35),
  title: z.string().max(200),
  prose: z.string().min(1).max(20_000),
  retention_policy: RetentionPolicySchema
}).strict();

export const DayIllustrationImageSchema = z.object({
  media_type: z.literal("image/jpeg"),
  data_base64: z.base64().min(1).max(2_500_000),
  pixel_width: z.literal(1024),
  pixel_height: z.literal(1536)
}).strict();

export const DayIllustrationGenerationResponseSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  prompt_version: z.literal(DAY_ILLUSTRATION_PROMPT_VERSION),
  job_id: UuidSchema,
  request_id: z.string().min(1).max(200),
  image: DayIllustrationImageSchema,
  scene: z.object({
    description: z.string().min(40).max(DAY_SCENE_MAX_CHARACTERS)
  }).strict(),
  scene_provenance: ProcessingProvenanceSchema.extend({
    provider_id: z.literal("fireworks"),
    model_alias: z.literal(DAY_SCENE_MODEL_ALIAS)
  }),
  provenance: ProcessingProvenanceSchema.extend({
    provider_id: z.literal("openai"),
    model_alias: z.literal(DAY_ILLUSTRATION_PROMPT_VERSION)
  })
}).strict();

export type DayIllustrationGenerationRequest = z.infer<typeof DayIllustrationGenerationRequestSchema>;
