import { z } from "zod";
import { LoreApiError } from "./http/errors.js";

const PolicyEnvironmentSchema = z.object({
  LORE_PROVIDER_POLICY_VERSION: z.string().min(1).refine((value) => value !== "unverified"),
  LORE_REMOTE_PROCESSING_ENABLED: z.literal("true")
}).passthrough();

const FireworksEnvironmentSchema = PolicyEnvironmentSchema.extend({
  FIREWORKS_API_KEY: z.string().min(1),
  LORE_FIREWORKS_DATA_POLICY_VERIFIED: z.literal("true")
});

const GroqEnvironmentSchema = PolicyEnvironmentSchema.extend({
  GROQ_API_KEY: z.string().min(1),
  LORE_GROQ_ZDR_VERIFIED: z.literal("true")
});

export type FireworksRuntimeConfig = {
  apiKey: string;
  policyVersion: string;
  baseUrl: string;
  dailyEntryModel: string;
};

export type GroqRuntimeConfig = {
  apiKey: string;
  policyVersion: string;
  baseUrl: string;
  transcriptionModel: string;
};

export function loadFireworksRuntimeConfig(
  environment: NodeJS.ProcessEnv = process.env
): FireworksRuntimeConfig {
  const parsed = FireworksEnvironmentSchema.safeParse(environment);
  if (!parsed.success) {
    throw new LoreApiError("provider_policy_unverified", 503, false);
  }

  return {
    apiKey: parsed.data.FIREWORKS_API_KEY,
    policyVersion: parsed.data.LORE_PROVIDER_POLICY_VERSION,
    baseUrl: "https://api.fireworks.ai/inference/v1",
    dailyEntryModel: "accounts/fireworks/models/gpt-oss-120b"
  };
}

export function loadGroqRuntimeConfig(
  environment: NodeJS.ProcessEnv = process.env
): GroqRuntimeConfig {
  const parsed = GroqEnvironmentSchema.safeParse(environment);
  if (!parsed.success) {
    throw new LoreApiError("provider_policy_unverified", 503, false);
  }

  return {
    apiKey: parsed.data.GROQ_API_KEY,
    policyVersion: parsed.data.LORE_PROVIDER_POLICY_VERSION,
    baseUrl: "https://api.groq.com/openai/v1",
    transcriptionModel: "whisper-large-v3-turbo"
  };
}
