import { z } from "zod";
import { LoreApiError } from "./http/errors.js";

const PolicyEnvironmentSchema = z.object({
  LORE_PROVIDER_POLICY_VERSION: z.string().min(1).refine((value) => value !== "unverified"),
  LORE_REMOTE_PROCESSING_ENABLED: z.literal("true")
}).passthrough();

const FireworksEnvironmentSchema = PolicyEnvironmentSchema.extend({
  FIREWORKS_API_KEY: z.string().min(1)
});

const GroqEnvironmentSchema = PolicyEnvironmentSchema.extend({
  GROQ_API_KEY: z.string().min(1),
  LORE_GROQ_ZDR_VERIFIED: z.literal("true")
});

const AppAttestEnvironmentSchema = z.object({
  LORE_APP_ATTEST_TEAM_ID: z.string().regex(/^[A-Z0-9]{10}$/),
  LORE_APP_ATTEST_BUNDLE_ID: z.string().min(3).max(255).regex(/^[A-Za-z0-9.-]+$/),
  LORE_APP_ATTEST_ENVIRONMENT: z.enum(["development", "production"]),
  LORE_APP_ATTEST_ALLOWED_BUNDLE_VERSIONS: z.string().min(1),
  LORE_APP_ATTEST_ALLOWED_VALIDATION_CATEGORIES: z.string().min(1),
  LORE_SESSION_SIGNING_SECRET: z.string().min(32),
  LORE_AUTH_STATE_HMAC_SECRET: z.string().min(32),
  LORE_AUTH_RECEIPT_ENCRYPTION_KEY: z.string().refine((value) => {
    try { return Buffer.from(value, "base64").byteLength === 32; } catch { return false; }
  }),
  LORE_AUTH_DATABASE_URL: z.string().url().startsWith("postgres"),
  VERCEL_ENV: z.enum(["development", "preview", "production"]).optional()
}).passthrough().superRefine((value, context) => {
  if (value.VERCEL_ENV === "production" && value.LORE_APP_ATTEST_ENVIRONMENT !== "production") {
    context.addIssue({ code: "custom", path: ["LORE_APP_ATTEST_ENVIRONMENT"], message: "production requires production App Attest" });
  }
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

export type AppAttestRuntimeConfig = {
  teamIdentifier: string;
  bundleIdentifier: string;
  environment: "development" | "production";
  allowedBundleVersions: ReadonlySet<string>;
  allowedValidationCategories: ReadonlySet<number>;
  sessionSigningSecret: string;
  stateHmacSecret: string;
  receiptEncryptionKey: Buffer;
  databaseUrl: string;
  sessionTtlSeconds: number;
  challengeTtlSeconds: number;
  processingLeaseTtlSeconds: number;
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

export function loadAppAttestRuntimeConfig(
  environment: NodeJS.ProcessEnv = process.env
): AppAttestRuntimeConfig {
  const parsed = AppAttestEnvironmentSchema.safeParse(environment);
  if (!parsed.success) {
    throw new LoreApiError("auth_unavailable", 503, true);
  }
  const bundleVersions = new Set(
    parsed.data.LORE_APP_ATTEST_ALLOWED_BUNDLE_VERSIONS.split(",").map((value) => value.trim()).filter(Boolean)
  );
  const validationCategories = new Set(
    parsed.data.LORE_APP_ATTEST_ALLOWED_VALIDATION_CATEGORIES.split(",").map(Number).filter(Number.isInteger)
  );
  if (bundleVersions.size === 0 || validationCategories.size === 0) {
    throw new LoreApiError("auth_unavailable", 503, true);
  }

  return {
    teamIdentifier: parsed.data.LORE_APP_ATTEST_TEAM_ID,
    bundleIdentifier: parsed.data.LORE_APP_ATTEST_BUNDLE_ID,
    environment: parsed.data.LORE_APP_ATTEST_ENVIRONMENT,
    allowedBundleVersions: bundleVersions,
    allowedValidationCategories: validationCategories,
    sessionSigningSecret: parsed.data.LORE_SESSION_SIGNING_SECRET,
    stateHmacSecret: parsed.data.LORE_AUTH_STATE_HMAC_SECRET,
    receiptEncryptionKey: Buffer.from(parsed.data.LORE_AUTH_RECEIPT_ENCRYPTION_KEY, "base64"),
    databaseUrl: parsed.data.LORE_AUTH_DATABASE_URL,
    sessionTtlSeconds: boundedInteger(environment.LORE_SESSION_TTL_SECONDS, 60, 900, 600),
    challengeTtlSeconds: boundedInteger(environment.LORE_APP_ATTEST_CHALLENGE_TTL_SECONDS, 60, 300, 300),
    processingLeaseTtlSeconds: boundedInteger(environment.LORE_PROCESSING_LEASE_TTL_SECONDS, 60, 300, 90)
  };
}

function boundedInteger(raw: string | undefined, minimum: number, maximum: number, fallback: number): number {
  if (raw === undefined) return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < minimum || value > maximum) {
    throw new LoreApiError("auth_unavailable", 503, true);
  }
  return value;
}
