import { z } from "zod";
import { DAY_SCENE_MAX_CHARACTERS } from "../../contracts/day-illustration.js";
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

const FACT_ARRAY_PROPERTIES = new Set(["fact_references", "related_fact_ids"]);

/**
 * The chapter writer works from finished days, never from accepted facts, so
 * any fact id a chapter cites would be invented. Derived from the daily-entry
 * writer schema without changing it: both fact-reference arrays are capped at
 * zero items, so a chapter completion cannot carry fact ids.
 */
export const FireworksStoryChapterJsonSchema: Record<string, unknown> = withoutFactArrays(
  FireworksDailyEntryJsonSchema
);

/** Deep-copies a JSON schema, capping the fact-array properties at zero items. */
function withoutFactArrays(value: object): Record<string, unknown> {
  const copy: Record<string, unknown> = {};
  for (const [key, property] of Object.entries(value)) {
    if (Array.isArray(property)) {
      copy[key] = property.map(copyFragment);
    } else if (isSchemaObject(property)) {
      copy[key] = FACT_ARRAY_PROPERTIES.has(key) && property.type === "array"
        ? { ...property, maxItems: 0 }
        : withoutFactArrays(property);
    } else {
      copy[key] = property;
    }
  }
  return copy;
}

/** Copies a nested schema fragment: objects recurse, arrays copy per item, primitives pass through. */
function copyFragment(value: unknown): unknown {
  if (typeof value !== "object" || value === null) return value;
  return Array.isArray(value) ? value.map(copyFragment) : withoutFactArrays(value);
}

function isSchemaObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export const FireworksDaySceneOutputSchema = z.object({
  scene: z.string().trim().min(40)
}).strict();

export const FireworksDaySceneJsonSchema = z.toJSONSchema(
  FireworksDaySceneOutputSchema.extend({
    scene: FireworksDaySceneOutputSchema.shape.scene.max(DAY_SCENE_MAX_CHARACTERS)
  }),
  { target: "draft-7" }
);

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
