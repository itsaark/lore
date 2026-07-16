import { z } from "zod";
import {
  API_SCHEMA_VERSION,
  ProcessingProvenanceSchema,
  RetentionPolicySchema,
  UuidSchema
} from "./common.js";

export const MAX_AUDIO_CHUNK_BYTES = 3_250_000;
export const MAX_MULTIPART_BODY_BYTES = 3_500_000;
export const MAX_VOCABULARY_HINTS = 100;

export const TranscriptionMetadataSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  job_id: UuidSchema,
  idempotency_key: z.string().min(8).max(200),
  chunk_id: z.string().min(1).max(100),
  chunk_index: z.coerce.number().int().min(0),
  chunk_count: z.coerce.number().int().min(1).max(10_000),
  start_milliseconds: z.coerce.number().int().min(0),
  duration_milliseconds: z.coerce.number().int().positive().max(3_600_000),
  language_code: z.string().min(2).max(35).nullable(),
  vocabulary_hints: z.array(z.string().min(1).max(100)).max(MAX_VOCABULARY_HINTS),
  retention_policy: RetentionPolicySchema
}).strict().superRefine((value, context) => {
  if (value.chunk_index >= value.chunk_count) {
    context.addIssue({
      code: "custom",
      path: ["chunk_index"],
      message: "chunk_index must be less than chunk_count"
    });
  }
});

export const TranscriptSourceSegmentSchema = z.object({
  id: z.string().min(1).max(200),
  chunk_id: z.string().min(1).max(100),
  start_milliseconds: z.number().int().min(0),
  end_milliseconds: z.number().int().min(0),
  text: z.string().min(1),
  confidence: z.number().min(0).max(1).nullable(),
  speaker_label: z.string().min(1).max(100).nullable()
}).strict().superRefine((value, context) => {
  if (value.end_milliseconds < value.start_milliseconds) {
    context.addIssue({
      code: "custom",
      path: ["end_milliseconds"],
      message: "end_milliseconds must not precede start_milliseconds"
    });
  }
});

export const RemoteTranscriptionResponseSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  job_id: UuidSchema,
  request_id: z.string().min(1).max(200),
  chunk: z.object({
    id: z.string().min(1).max(100),
    index: z.number().int().min(0),
    count: z.number().int().min(1),
    start_milliseconds: z.number().int().min(0),
    duration_milliseconds: z.number().int().positive()
  }).strict(),
  transcript: z.string().min(1),
  language_code: z.string().min(2).max(35).nullable(),
  segments: z.array(TranscriptSourceSegmentSchema),
  provenance: ProcessingProvenanceSchema
}).strict();

export type TranscriptionMetadata = z.infer<typeof TranscriptionMetadataSchema>;
export type RemoteTranscriptionResponse = z.infer<typeof RemoteTranscriptionResponseSchema>;
