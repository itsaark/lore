import { z } from "zod";
import { LoreApiError } from "./http/errors.js";

// This identifier describes the provider/model policy implemented by this
// release. It belongs in source control so provenance cannot drift because of
// a mistyped deployment setting.
export const PROVIDER_POLICY_VERSION = "direct-fireworks-groq-2026-08-04-v3";
export const APP_ATTEST_TEAM_IDENTIFIER = "6PP52WCRHS";
export const APP_ATTEST_BUNDLE_IDENTIFIER = "cascadianpines.lore";

const FireworksEnvironmentSchema = z.object({
  FIREWORKS_API_KEY: z.string().min(1)
}).passthrough();

const GroqEnvironmentSchema = z.object({
  GROQ_API_KEY: z.string().min(1)
}).passthrough();

const AppAttestEnvironmentSchema = z.object({
  LORE_SESSION_SIGNING_SECRET: z.string().min(32),
  LORE_AUTH_STATE_HMAC_SECRET: z.string().min(32),
  LORE_AUTH_RECEIPT_ENCRYPTION_KEY: z.string().refine((value) => {
    try { return Buffer.from(value, "base64").byteLength === 32; } catch { return false; }
  }),
  DATABASE_URL: z.string().url().startsWith("postgres")
}).passthrough();

const MaintenanceEnvironmentSchema = z.object({
  CRON_SECRET: z.string().min(32).max(512),
  DATABASE_URL: z.string().url().startsWith("postgres")
}).passthrough();

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
  allowedAttestationEnvironments: ReadonlySet<"development" | "production">;
  environment: "development" | "production";
  allowedValidationCategories: ReadonlySet<number>;
  sessionSigningSecret: string;
  stateHmacSecret: string;
  receiptEncryptionKey: Buffer;
  databaseUrl: string;
  sessionTtlSeconds: number;
  challengeTtlSeconds: number;
  processingLeaseTtlSeconds: number;
};

export type MaintenanceRuntimeConfig = {
  cronSecret: string;
  databaseUrl: string;
  batchSize: number;
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
    policyVersion: PROVIDER_POLICY_VERSION,
    baseUrl: "https://api.fireworks.ai/inference/v1",
    dailyEntryModel: "accounts/fireworks/models/deepseek-v4-flash"
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
    policyVersion: PROVIDER_POLICY_VERSION,
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
  return {
    teamIdentifier: APP_ATTEST_TEAM_IDENTIFIER,
    bundleIdentifier: APP_ATTEST_BUNDLE_IDENTIFIER,
    // Development App Attest is accepted for physical-device builds signed by
    // this Apple account. Simulator requests still cannot produce an attestation.
    allowedAttestationEnvironments: new Set(["development", "production"]),
    environment: "production",
    // Apple validation categories: 1 = Development, 2 = TestFlight, 4 = App Store.
    allowedValidationCategories: new Set([1, 2, 4]),
    sessionSigningSecret: parsed.data.LORE_SESSION_SIGNING_SECRET,
    stateHmacSecret: parsed.data.LORE_AUTH_STATE_HMAC_SECRET,
    receiptEncryptionKey: Buffer.from(parsed.data.LORE_AUTH_RECEIPT_ENCRYPTION_KEY, "base64"),
    databaseUrl: parsed.data.DATABASE_URL,
    sessionTtlSeconds: 600,
    challengeTtlSeconds: 300,
    processingLeaseTtlSeconds: 90
  };
}

export function loadMaintenanceRuntimeConfig(
  environment: NodeJS.ProcessEnv = process.env
): MaintenanceRuntimeConfig {
  const parsed = MaintenanceEnvironmentSchema.safeParse(environment);
  if (!parsed.success) {
    throw new LoreApiError("auth_unavailable", 503, true);
  }
  return {
    cronSecret: parsed.data.CRON_SECRET,
    databaseUrl: parsed.data.DATABASE_URL,
    batchSize: 500
  };
}
