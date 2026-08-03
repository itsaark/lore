import { z } from "zod";

export const API_SCHEMA_VERSION = "1.0" as const;
export const RETENTION_POLICY_VERSION = "request-ephemeral-v1" as const;

export const ProcessingProviderIdSchema = z.enum([
  "fireworks",
  "groq",
  "deepgram",
  "google",
  "openai",
  "self_hosted"
]);

export const UuidSchema = z.string().uuid();
export const IsoDateSchema = z.iso.datetime({ offset: true });

export const RetentionPolicySchema = z.object({
  mode: z.literal("request_ephemeral"),
  maximum_retention_seconds: z.literal(0)
}).strict();

export const RetentionAttestationSchema = z.object({
  mode: z.literal("request_ephemeral"),
  maximum_retention_seconds: z.literal(0),
  policy_version: z.string().min(1).max(80),
  attested_at: IsoDateSchema
}).strict();

export const ProcessingProvenanceSchema = z.object({
  provider_id: ProcessingProviderIdSchema,
  model_alias: z.string().min(1).max(80),
  model_id: z.string().min(1).max(120),
  model_policy_version: z.string().min(1).max(80),
  provider_request_id: z.string().min(1).max(200).nullable(),
  processed_at: IsoDateSchema,
  processing_duration_milliseconds: z.number().int().min(0),
  retention_attestation: RetentionAttestationSchema
}).strict();

export const ApiErrorCodeSchema = z.enum([
  "unauthorized",
  "consent_required",
  "unsupported_schema",
  "invalid_request",
  "payload_too_large",
  "unsupported_audio",
  "provider_rate_limited",
  "provider_unavailable",
  "provider_policy_unverified",
  "invalid_provider_response",
  "empty_transcript",
  "request_cancelled",
  "internal_error"
]);

export const ApiErrorResponseSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  request_id: z.string().min(1).max(200),
  error: z.object({
    code: ApiErrorCodeSchema,
    message: z.string().min(1).max(300),
    retryable: z.boolean()
  }).strict(),
  retry_after_seconds: z.number().int().positive().nullable()
}).strict();

export type ApiErrorCode = z.infer<typeof ApiErrorCodeSchema>;
export type ApiErrorResponse = z.infer<typeof ApiErrorResponseSchema>;
export type ProcessingProvenance = z.infer<typeof ProcessingProvenanceSchema>;
