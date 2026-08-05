import { describe, expect, it } from "vitest";
import {
  APP_ATTEST_BUNDLE_IDENTIFIER,
  APP_ATTEST_TEAM_IDENTIFIER,
  loadAppAttestRuntimeConfig,
  loadFireworksRuntimeConfig,
  loadGroqRuntimeConfig,
  loadMaintenanceRuntimeConfig
} from "../src/config.js";

const authEnvironment = {
  LORE_SESSION_SIGNING_SECRET: "independent-session-secret-at-least-32-characters",
  LORE_AUTH_STATE_HMAC_SECRET: "independent-state-secret-at-least-32-characters",
  LORE_AUTH_RECEIPT_ENCRYPTION_KEY: Buffer.alloc(32, 7).toString("base64"),
  DATABASE_URL: "postgresql://test.invalid/lore"
};

const maintenanceEnvironment = {
  CRON_SECRET: "one-high-entropy-server-secret-at-least-32-characters",
  DATABASE_URL: "postgresql://test.invalid/lore"
};

describe("minimal production configuration", () => {
  it("loads each provider from only its API key", () => {
    const fireworks = loadFireworksRuntimeConfig({ FIREWORKS_API_KEY: "fireworks-test" });
    expect(fireworks.apiKey).toBe("fireworks-test");
    expect(fireworks.dailyEntryModel).toBe("accounts/fireworks/models/gpt-oss-120b");
    expect(loadGroqRuntimeConfig({ GROQ_API_KEY: "groq-test" }).apiKey)
      .toBe("groq-test");
  });

  it("keeps public Apple identity and operating bounds in source", () => {
    const config = loadAppAttestRuntimeConfig(authEnvironment);
    expect(config.teamIdentifier).toBe(APP_ATTEST_TEAM_IDENTIFIER);
    expect(config.bundleIdentifier).toBe(APP_ATTEST_BUNDLE_IDENTIFIER);
    expect(config.allowedAttestationEnvironments).toEqual(new Set(["development", "production"]));
    expect(config.allowedValidationCategories).toEqual(new Set([1, 2, 4]));
    expect(config.challengeTtlSeconds).toBe(300);
    expect(config.sessionTtlSeconds).toBe(600);
    expect(config.processingLeaseTtlSeconds).toBe(90);
  });

  it("loads independent authentication secrets without exposing them in source", () => {
    const config = loadAppAttestRuntimeConfig(authEnvironment);
    expect(config.sessionSigningSecret).toBe(authEnvironment.LORE_SESSION_SIGNING_SECRET);
    expect(config.stateHmacSecret).toBe(authEnvironment.LORE_AUTH_STATE_HMAC_SECRET);
    expect(config.receiptEncryptionKey).toEqual(Buffer.alloc(32, 7));
  });

  it("uses the same server secret for authorized bounded cleanup", () => {
    expect(loadMaintenanceRuntimeConfig(maintenanceEnvironment)).toEqual({
      cronSecret: maintenanceEnvironment.CRON_SECRET,
      databaseUrl: maintenanceEnvironment.DATABASE_URL,
      batchSize: 500
    });
  });
});
