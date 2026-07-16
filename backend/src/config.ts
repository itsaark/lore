import { z } from "zod";
import { LoreApiError } from "./http/errors.js";

const EnvironmentSchema = z.object({
  GROQ_API_KEY: z.string().min(1),
  LORE_GROQ_ZDR_VERIFIED: z.literal("true"),
  LORE_PROVIDER_POLICY_VERSION: z.string().min(1).refine((value) => value !== "unverified"),
  LORE_REMOTE_PROCESSING_ENABLED: z.literal("true")
}).passthrough();

export type GroqRuntimeConfig = {
  apiKey: string;
  policyVersion: string;
  baseUrl: string;
  transcriptionModel: string;
  dailyEntryModel: string;
};

export function loadGroqRuntimeConfig(environment: NodeJS.ProcessEnv = process.env): GroqRuntimeConfig {
  const parsed = EnvironmentSchema.safeParse(environment);
  if (!parsed.success) {
    throw new LoreApiError("provider_policy_unverified", 503, false);
  }

  return {
    apiKey: parsed.data.GROQ_API_KEY,
    policyVersion: parsed.data.LORE_PROVIDER_POLICY_VERSION,
    baseUrl: "https://api.groq.com/openai/v1",
    transcriptionModel: "whisper-large-v3-turbo",
    dailyEntryModel: "openai/gpt-oss-120b"
  };
}
