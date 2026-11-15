import type { DailyEntryLabModelAlias } from "../../contracts/daily-entry.js";

/**
 * Cheap open-weight writers the DEBUG Model Lab may compare. Every entry runs
 * on Fireworks serverless, which is zero data retention by default. IDs follow
 * Fireworks' model-page paths; a wrong ID surfaces as a provider error in the
 * Lab rather than reaching production.
 */
export type LabModelSpec = {
  modelId: string;
  /** Sent only to models known to accept `reasoning_effort`. */
  reasoningEffort: "low" | null;
};

export const LAB_MODELS: Record<DailyEntryLabModelAlias, LabModelSpec> = {
  "gpt-oss-120b": { modelId: "accounts/fireworks/models/gpt-oss-120b", reasoningEffort: "low" },
  "deepseek-v4-flash": { modelId: "accounts/fireworks/models/deepseek-v4-flash", reasoningEffort: "low" },
  "deepseek-v4p1-flash": { modelId: "accounts/deepseek-ai/models/deepseek-v4p1-flash", reasoningEffort: "low" },
  "glm-5p3": { modelId: "accounts/fireworks/models/glm-5p3", reasoningEffort: null },
  "glm-5p3-flash": { modelId: "accounts/fireworks/models/glm-5p3-flash", reasoningEffort: null },
  "minimax-m3": { modelId: "accounts/fireworks/models/minimax-m3", reasoningEffort: null }
};
