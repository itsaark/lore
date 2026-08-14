import { z } from "zod";
import {
  API_SCHEMA_VERSION,
  IsoDateSchema,
  ProcessingProvenanceSchema,
  RetentionPolicySchema,
  UuidSchema
} from "./common.js";
import { DailyEntryGenerationRequestSchema } from "./daily-entry.js";

export const REFLECTION_GUIDE_PROMPT_VERSION = "reflection-guide-v1" as const;
export const REFLECTION_ENTRY_PROMPT_VERSION = "reflection-entry-v1" as const;
export const REFLECTION_MAX_SESSION_DURATION_SECONDS = 20 * 60;

const LanguageCodeSchema = z.string().min(2).max(35);

export const ReflectionSessionCredentialsRequestSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  session_id: UuidSchema,
  language_code: LanguageCodeSchema
}).strict();

const TemporaryCredentialSchema = z.object({
  temporary_api_key: z.string().min(1).max(512),
  expires_at: IsoDateSchema,
  websocket_url: z.string().url().startsWith("wss://"),
  model_alias: z.string().min(1).max(80),
  audio_format: z.literal("pcm_s16le"),
  sample_rate: z.number().int().positive()
}).strict();

export const ReflectionSessionCredentialsResponseSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  session_id: UuidSchema,
  stt: TemporaryCredentialSchema.extend({
    num_channels: z.literal(1)
  }).strict(),
  tts: TemporaryCredentialSchema.extend({
    voice: z.string().min(1).max(120)
  }).strict(),
  maximum_session_duration_seconds: z.literal(REFLECTION_MAX_SESSION_DURATION_SECONDS)
}).strict();

export const ReflectionTurnSchema = z.object({
  id: UuidSchema,
  sequence: z.number().int().min(0).max(200),
  role: z.enum(["user", "lore"]),
  text: z.string().trim().min(1).max(8_000),
  is_evidence_eligible: z.boolean()
}).strict().superRefine((turn, context) => {
  if (turn.is_evidence_eligible !== (turn.role === "user")) {
    context.addIssue({
      code: "custom",
      path: ["is_evidence_eligible"],
      message: "Only finalized user turns are evidence eligible"
    });
  }
});

const AcceptedPriorFactSchema = z.object({
  id: z.string().min(1).max(200),
  statement: z.string().min(1).max(2_000),
  status: z.string().min(1).max(80),
  source_references: z.array(z.string().min(1).max(200)).max(100)
}).strict();

export const ReflectionGuideRequestSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  prompt_version: z.literal(REFLECTION_GUIDE_PROMPT_VERSION),
  session_id: UuidSchema,
  language_code: LanguageCodeSchema,
  subject: z.object({
    display_name: z.string().min(1).max(120),
    pronouns: z.array(z.string().min(1).max(30)).max(8)
  }).strict(),
  turns: z.array(ReflectionTurnSchema).max(80),
  accepted_prior_facts: z.array(AcceptedPriorFactSchema).max(200),
  retention_policy: RetentionPolicySchema
}).strict().superRefine((request, context) => {
  const ids = new Set<string>();
  let previousSequence = -1;
  request.turns.forEach((turn, index) => {
    if (ids.has(turn.id)) {
      context.addIssue({ code: "custom", path: ["turns", index, "id"], message: "Turn IDs must be unique" });
    }
    ids.add(turn.id);
    if (turn.sequence <= previousSequence) {
      context.addIssue({ code: "custom", path: ["turns", index, "sequence"], message: "Turns must be strictly ordered" });
    }
    previousSequence = turn.sequence;
  });
});

export const ReflectionGuideResponseSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  prompt_version: z.literal(REFLECTION_GUIDE_PROMPT_VERSION),
  session_id: UuidSchema,
  request_id: z.string().min(1).max(200),
  spoken_text: z.string().trim().min(1).max(500),
  should_offer_finish: z.boolean(),
  provenance: ProcessingProvenanceSchema
}).strict();

const ReflectionEvidenceTurnSchema = z.object({
  turn_id: UuidSchema,
  source_segment_ids: z.array(z.string().min(1).max(200)).min(1).max(250)
}).strict();

const ReflectionAssistantTurnSchema = z.object({
  turn_id: UuidSchema,
  sequence: z.number().int().min(0).max(200),
  text: z.string().trim().min(1).max(2_000)
}).strict();

export const ReflectionFinalizationRequestSchema = z.object({
  schema_version: z.literal(API_SCHEMA_VERSION),
  prompt_version: z.literal(REFLECTION_ENTRY_PROMPT_VERSION),
  session_id: UuidSchema,
  entry_request: DailyEntryGenerationRequestSchema,
  evidence_turns: z.array(ReflectionEvidenceTurnSchema).min(1).max(80),
  assistant_turns: z.array(ReflectionAssistantTurnSchema).max(80)
}).strict().superRefine((request, context) => {
  if (request.entry_request.note_id !== request.session_id) {
    context.addIssue({ code: "custom", path: ["entry_request", "note_id"], message: "note_id must equal session_id" });
  }
  if (request.entry_request.render_configuration.perspective !== "third_person") {
    context.addIssue({
      code: "custom",
      path: ["entry_request", "render_configuration", "perspective"],
      message: "Reflections must render in third person"
    });
  }

  const sourceIds = new Set(request.entry_request.source_segments.map((segment) => segment.id));
  const claimedSourceIds = new Set<string>();
  const turnIds = new Set<string>();
  request.evidence_turns.forEach((turn, turnIndex) => {
    if (turnIds.has(turn.turn_id)) {
      context.addIssue({ code: "custom", path: ["evidence_turns", turnIndex, "turn_id"], message: "Turn IDs must be unique" });
    }
    turnIds.add(turn.turn_id);
    turn.source_segment_ids.forEach((sourceId, sourceIndex) => {
      if (!sourceIds.has(sourceId) || claimedSourceIds.has(sourceId)) {
        context.addIssue({
          code: "custom",
          path: ["evidence_turns", turnIndex, "source_segment_ids", sourceIndex],
          message: "Each submitted source segment must belong to exactly one user turn"
        });
      }
      claimedSourceIds.add(sourceId);
    });
  });
  if (claimedSourceIds.size !== sourceIds.size) {
    context.addIssue({ code: "custom", path: ["evidence_turns"], message: "Every source segment must map to a user turn" });
  }
  request.assistant_turns.forEach((turn, index) => {
    if (turnIds.has(turn.turn_id)) {
      context.addIssue({
        code: "custom",
        path: ["assistant_turns", index, "turn_id"],
        message: "Assistant turns cannot also be evidence turns"
      });
    }
    turnIds.add(turn.turn_id);
  });
});

export type ReflectionSessionCredentialsRequest = z.infer<typeof ReflectionSessionCredentialsRequestSchema>;
export type ReflectionSessionCredentialsResponse = z.infer<typeof ReflectionSessionCredentialsResponseSchema>;
export type ReflectionGuideRequest = z.infer<typeof ReflectionGuideRequestSchema>;
export type ReflectionGuideResponse = z.infer<typeof ReflectionGuideResponseSchema>;
export type ReflectionFinalizationRequest = z.infer<typeof ReflectionFinalizationRequestSchema>;
