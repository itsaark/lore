import { z } from "zod";
import { API_SCHEMA_VERSION, IsoDateSchema, UuidSchema } from "./common.js";

const Base64Schema = z.string().min(1).max(262_144).regex(/^[A-Za-z0-9+/]+={0,2}$/);
const Base64UrlSchema = z.string().min(16).max(512).regex(/^[A-Za-z0-9_-]+$/);
export const AppAttestKeyIdSchema = z.string().min(40).max(100).regex(/^[A-Za-z0-9+/]+={0,2}$/).refine((value) => {
  try {
    const decoded = Buffer.from(value, "base64");
    return decoded.byteLength === 32 && decoded.toString("base64") === value;
  } catch {
    return false;
  }
}, "key_id must be a base64-encoded 32-byte App Attest key identifier");

export const ChallengePurposeSchema = z.enum(["attestation", "assertion"]);

export const ChallengeRequestSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  purpose: ChallengePurposeSchema,
  key_id: AppAttestKeyIdSchema.nullable()
}).strict().superRefine((value, context) => {
  if (value.purpose === "assertion" && !value.key_id) {
    context.addIssue({ code: "custom", path: ["key_id"], message: "key_id is required" });
  }
  if (value.purpose === "attestation" && value.key_id !== null) {
    context.addIssue({ code: "custom", path: ["key_id"], message: "key_id must be null" });
  }
});

export const ChallengeResponseSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  challenge_id: UuidSchema,
  challenge: Base64UrlSchema,
  purpose: ChallengePurposeSchema,
  expires_at: IsoDateSchema
}).strict();

export const AttestationRequestSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  challenge_id: UuidSchema,
  challenge: Base64UrlSchema,
  key_id: AppAttestKeyIdSchema,
  attestation_object: Base64Schema
}).strict();

export const AssertionClientDataSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  action: z.literal("create_session"),
  challenge_id: UuidSchema,
  challenge: Base64UrlSchema
}).strict();

export const SessionRequestSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  challenge_id: UuidSchema,
  challenge: Base64UrlSchema,
  key_id: AppAttestKeyIdSchema,
  assertion_object: Base64Schema,
  client_data: Base64Schema
}).strict();

export const SessionResponseSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  token_type: z.literal("Bearer"),
  session_token: z.string().min(40).max(4_096),
  expires_at: IsoDateSchema
}).strict();

export type ChallengePurpose = z.infer<typeof ChallengePurposeSchema>;
export type ChallengeRequest = z.infer<typeof ChallengeRequestSchema>;
export type ChallengeResponse = z.infer<typeof ChallengeResponseSchema>;
export type AttestationRequest = z.infer<typeof AttestationRequestSchema>;
export type AssertionClientData = z.infer<typeof AssertionClientDataSchema>;
export type SessionRequest = z.infer<typeof SessionRequestSchema>;
export type SessionResponse = z.infer<typeof SessionResponseSchema>;
