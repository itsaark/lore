import { z } from "zod";
import {
  API_SCHEMA_VERSION,
  ProcessingProvenanceSchema,
  RetentionPolicySchema,
  UuidSchema
} from "./common.js";

export const MEMORY_ANCHOR_PROMPT_VERSION = "memory-anchor-v1" as const;

export const MemoryAnchorRequestSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  prompt_version: z.literal(MEMORY_ANCHOR_PROMPT_VERSION),
  job_id: UuidSchema,
  captured_local_date: z.iso.date(),
  language_code: z.string().min(2).max(35),
  transcript: z.string().min(1).max(20_000),
  retention_policy: RetentionPolicySchema
}).strict();

const AnchorYearSchema = z.number().int().min(1900);
const AnchorYearsAgoSchema = z.number().int().min(1).max(100);
const AnchorAgeSchema = z.number().int().min(0).max(120);

export const MemoryAnchorSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("none") }).strict(),
  z.object({
    kind: z.literal("year"),
    start_year: AnchorYearSchema,
    end_year: AnchorYearSchema
  }).strict().refine(({ start_year, end_year }) => start_year <= end_year),
  z.object({
    kind: z.literal("years_ago"),
    min_years: AnchorYearsAgoSchema,
    max_years: AnchorYearsAgoSchema
  }).strict().refine(({ min_years, max_years }) => min_years <= max_years),
  z.object({
    kind: z.literal("age"),
    start_age: AnchorAgeSchema,
    end_age: AnchorAgeSchema
  }).strict().refine(({ start_age, end_age }) => start_age <= end_age),
  z.object({
    kind: z.literal("life_stage"),
    stage: z.enum(["early_childhood", "school_years", "teenage_years", "college_years", "first_jobs"])
  }).strict()
]);

export const MemoryAnchorResponseSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  prompt_version: z.literal(MEMORY_ANCHOR_PROMPT_VERSION),
  job_id: UuidSchema,
  request_id: z.string().min(1).max(200),
  anchor: MemoryAnchorSchema,
  provenance: ProcessingProvenanceSchema.extend({
    provider_id: z.literal("fireworks"),
    model_alias: z.literal(MEMORY_ANCHOR_PROMPT_VERSION)
  }).strict()
}).strict();

export type MemoryAnchorRequest = z.infer<typeof MemoryAnchorRequestSchema>;
export type MemoryAnchorResponse = z.infer<typeof MemoryAnchorResponseSchema>;
