import { describe, expect, it, vi } from "vitest";
import { handleLabDailyEntry } from "../api/v1/lab/daily-entries.js";
import { issueSessionToken } from "../src/auth/session-token.js";
import { MemoryAuthStateStore, type AppAttestKeyRecord } from "../src/auth/state-store.js";
import type { AppAttestRuntimeConfig } from "../src/config.js";

const baseTime = new Date("2026-11-14T20:00:00.000Z");
const keyRef = "b".repeat(64);
const jobId = "5f3acbd5-676e-4cb3-83a4-150b09c735a9";
const environment = {
  FIREWORKS_API_KEY: "test-fireworks-key-never-use-live",
  GROQ_API_KEY: "test-groq-key-never-use-live"
};

describe("Model Lab daily-entry route", () => {
  it("rejects production App Attest keys before any provider call", async () => {
    const harness = await authenticatedHarness("production");
    const provider = vi.fn<typeof fetch>();

    const response = await handleLabDailyEntry(labRequest(harness.token, labBody()), {
      environment,
      fetch: provider,
      auth: harness.auth
    });

    expect(response.status).toBe(403);
    expect(provider).not.toHaveBeenCalled();
  });

  it("runs an allowlisted model with the v2 biographer prompt for development keys", async () => {
    const harness = await authenticatedHarness("development");
    const provider = vi.fn<typeof fetch>(async (_input, init) => {
      const body = JSON.parse(String(init?.body)) as {
        model: string;
        reasoning_effort?: string;
        messages: Array<{ role: string; content: string }>;
      };
      expect(body.model).toBe("accounts/fireworks/models/glm-5p3");
      expect(body.reasoning_effort).toBeUndefined();
      expect(body.messages[0]?.content).toContain("private biographer");
      return Response.json({
        id: "chatcmpl_lab",
        model: "accounts/fireworks/models/glm-5p3",
        usage: { prompt_tokens: 1_200, completion_tokens: 300 },
        choices: [{
          index: 0,
          finish_reason: "stop",
          message: { role: "assistant", content: JSON.stringify(completedOutput()) }
        }]
      });
    });

    const response = await handleLabDailyEntry(labRequest(harness.token, labBody()), {
      environment,
      fetch: provider,
      auth: harness.auth
    });

    expect(response.status).toBe(200);
    expect(provider).toHaveBeenCalledOnce();
    await expect(response.json()).resolves.toMatchObject({
      prompt_version: "grounded-journal-v2",
      lab_model: "glm-5p3",
      usage: { prompt_tokens: 1_200, completion_tokens: 300 },
      provenance: { model_alias: "lab-glm-5p3" }
    });
  });

  it("rejects a model outside the allowlist", async () => {
    const harness = await authenticatedHarness("development");
    const provider = vi.fn<typeof fetch>();
    const body = { ...labBody(), lab_model: "kimi-k3" };

    const response = await handleLabDailyEntry(labRequest(harness.token, body), {
      environment,
      fetch: provider,
      auth: harness.auth
    });

    expect(response.status).toBe(400);
    expect(provider).not.toHaveBeenCalled();
  });

  it("rejects a citation the request never contained", async () => {
    const harness = await authenticatedHarness("development");
    const output = completedOutput();
    output.entry.sentences[0]!.source_references = ["s9"];
    const provider = vi.fn<typeof fetch>(async () => Response.json({
      id: "chatcmpl_lab_bad",
      model: "accounts/fireworks/models/glm-5p3",
      choices: [{
        index: 0,
        finish_reason: "stop",
        message: { role: "assistant", content: JSON.stringify(output) }
      }]
    }));

    const response = await handleLabDailyEntry(labRequest(harness.token, labBody()), {
      environment,
      fetch: provider,
      auth: harness.auth
    });

    expect(response.status).toBe(502);
  });
});

function labRequest(token: string, body: Record<string, unknown>): Request {
  return new Request("https://lore.invalid/v1/lab/daily-entries", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "Idempotency-Key": `lab-daily-entry:${jobId}`
    },
    body: JSON.stringify(body)
  });
}

function labBody(): Record<string, unknown> {
  return {
    schema_version: "1.0",
    prompt_version: "grounded-journal-v2",
    lab_model: "glm-5p3",
    job_id: jobId,
    note_id: "f8a383e5-8830-41e4-a92f-257fa295d41b",
    transcript_artifact_id: "6343dc64-1e69-41ae-ac52-6e9f65a7bc2e",
    transcript_version_id: "82b6e4bb-fe09-4d9f-b0ec-42ee851f7efc",
    captured_local_date: "2026-11-14",
    language_code: "en-US",
    subject: { display_name: "Maya", pronouns: [] },
    render_configuration: { perspective: "third_person", tense: "past", tone: "narrative_restrained", target_words: 200 },
    source_segments: [{
      id: "s1",
      chunk_id: "chunk-0",
      start_milliseconds: 0,
      end_milliseconds: 2500,
      text: "Synthetic transcript.",
      confidence: null,
      speaker_label: null
    }],
    accepted_prior_facts: [],
    retention_policy: { mode: "request_ephemeral", maximum_retention_seconds: 0 }
  };
}

function completedOutput() {
  return {
    status: "completed",
    entry: {
      title: "Synthetic day",
      title_source_references: ["s1"],
      perspective: "third_person",
      sentences: [{
        text: "Maya recorded a synthetic note.",
        source_references: ["s1"],
        fact_references: [] as string[],
        preserves_uncertainty: false
      }]
    },
    memory_candidates: [],
    uncertainties: [],
    sensitive_omissions: [],
    quality_flags: [],
    follow_up_questions: [],
    refusal_reason: null
  };
}

async function authenticatedHarness(keyEnvironment: "development" | "production") {
  const config = testConfig();
  const store = new MemoryAuthStateStore();
  const challengeId = "3b9cc686-e6bd-474e-99ac-85eeaf38b832";
  await store.putChallenge({
    id: challengeId,
    challengeHash: "challenge-hash",
    purpose: "attestation",
    keyRef: null,
    expiresAt: new Date(baseTime.getTime() + 300_000)
  });
  const key: AppAttestKeyRecord = {
    keyRef,
    keyIdHash: "e".repeat(64),
    publicKeyPem: "synthetic-public-key",
    receiptCiphertext: "synthetic-encrypted-receipt",
    environment: keyEnvironment,
    validationCategory: keyEnvironment === "development" ? 3 : 4,
    bundleVersion: "1",
    counter: 0,
    createdAt: baseTime,
    updatedAt: baseTime
  };
  await store.registerKeyWithChallenge({
    challenge: { id: challengeId, challengeHash: "challenge-hash", purpose: "attestation", now: baseTime },
    key
  });
  const token = issueSessionToken(keyRef, config, baseTime).token;
  return { token, auth: { config, store, now: baseTime } };
}

function testConfig(): AppAttestRuntimeConfig {
  return {
    teamIdentifier: "ABCDE12345",
    bundleIdentifier: "cascadianpines.lore",
    allowedAttestationEnvironments: new Set(["development", "production"]),
    environment: "production",
    allowedValidationCategories: new Set([2, 3, 4]),
    sessionSigningSecret: "session-signing-secret-at-least-32-bytes",
    stateHmacSecret: "state-reference-secret-at-least-32-bytes",
    receiptEncryptionKey: Buffer.alloc(32, 7),
    databaseUrl: "postgresql://test.invalid/lore",
    sessionTtlSeconds: 600,
    challengeTtlSeconds: 300,
    processingLeaseTtlSeconds: 90
  };
}
