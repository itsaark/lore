import { describe, expect, it, vi } from "vitest";
import { handleDailyEntry } from "../api/v1/daily-entries.js";
import { handleTranscription } from "../api/v1/transcriptions.js";
import { issueSessionToken } from "../src/auth/session-token.js";
import { MemoryAuthStateStore, type AppAttestKeyRecord } from "../src/auth/state-store.js";
import { PROVIDER_POLICY_VERSION, type AppAttestRuntimeConfig } from "../src/config.js";

const baseTime = new Date("2026-08-03T20:00:00.000Z");
const keyRef = "a".repeat(64);
const environment = {
  FIREWORKS_API_KEY: "test-fireworks-key-never-use-live",
  GROQ_API_KEY: "test-groq-key-never-use-live"
};

describe("processing routes", () => {
  it("rejects transcription before provider invocation when unauthorized", async () => {
    const provider = vi.fn<typeof fetch>();
    const response = await handleTranscription(new Request("https://lore.invalid/v1/transcriptions", {
      method: "POST",
      body: new FormData()
    }), { environment, fetch: provider });

    expect(response.status).toBe(401);
    expect(provider).not.toHaveBeenCalled();
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "unauthorized", retryable: false }
    });
  });

  it("accepts a bounded multipart transcription request", async () => {
    const harness = await authenticatedHarness();
    const provider = vi.fn<typeof fetch>(async () => Response.json({
      text: "Synthetic transcript.",
      language: "en",
      segments: [{ id: 0, start: 0, end: 2.5, text: "Synthetic transcript." }]
    }, { headers: { "x-request-id": "req_audio_route" } }));
    const form = new FormData();
    form.append("audio", new File(["audio"], "note.m4a", { type: "audio/m4a" }));
    form.append("schema_version", "1.0");
    form.append("job_id", "9f170d1f-8e71-4a12-a861-2ca5f9f52ed2");
    form.append("idempotency_key", "transcription:note-1:revision-1:chunk-0");
    form.append("chunk_id", "chunk-0");
    form.append("chunk_index", "0");
    form.append("chunk_count", "1");
    form.append("start_milliseconds", "0");
    form.append("duration_milliseconds", "2500");
    form.append("language_code", "en-US");
    form.append("vocabulary_hints", "[]");
    form.append("retention_policy", JSON.stringify({ mode: "request_ephemeral", maximum_retention_seconds: 0 }));

    const response = await handleTranscription(new Request("https://lore.invalid/v1/transcriptions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${harness.token}`,
        "Idempotency-Key": "transcription:note-1:revision-1:chunk-0"
      },
      body: form
    }), { environment, fetch: provider, auth: harness.auth });

    expect(response.status).toBe(200);
    expect(provider).toHaveBeenCalledOnce();
    await expect(response.json()).resolves.toMatchObject({
      transcript: "Synthetic transcript.",
      request_id: expect.any(String),
      provenance: {
        provider_id: "groq",
        provider_request_id: "req_audio_route",
        model_policy_version: PROVIDER_POLICY_VERSION
      }
    });
  });

  it("fails closed before upload when the Groq credential is absent", async () => {
    const harness = await authenticatedHarness();
    const provider = vi.fn<typeof fetch>();
    const form = new FormData();
    form.append("audio", new File(["audio"], "note.m4a", { type: "audio/m4a" }));
    form.append("schema_version", "1.0");
    form.append("job_id", "9f170d1f-8e71-4a12-a861-2ca5f9f52ed2");
    form.append("idempotency_key", "transcription:note-1:revision-1:chunk-0");
    form.append("chunk_id", "chunk-0");
    form.append("chunk_index", "0");
    form.append("chunk_count", "1");
    form.append("start_milliseconds", "0");
    form.append("duration_milliseconds", "2500");
    form.append("language_code", "en-US");
    form.append("vocabulary_hints", "[]");
    form.append("retention_policy", JSON.stringify({ mode: "request_ephemeral", maximum_retention_seconds: 0 }));

    const response = await handleTranscription(new Request("https://lore.invalid/v1/transcriptions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${harness.token}`,
        "Idempotency-Key": "transcription:note-1:revision-1:chunk-0"
      },
      body: form
    }), {
      environment: { FIREWORKS_API_KEY: environment.FIREWORKS_API_KEY },
      fetch: provider,
      auth: harness.auth
    });

    expect(response.status).toBe(503);
    expect(provider).not.toHaveBeenCalled();
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "provider_policy_unverified", retryable: false }
    });
  });

  it("fails closed before generation when the Fireworks credential is absent", async () => {
    const harness = await authenticatedHarness();
    const provider = vi.fn<typeof fetch>();
    const response = await handleDailyEntry(new Request("https://lore.invalid/v1/daily-entries", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${harness.token}`,
        "Content-Type": "application/json",
        "Idempotency-Key": "daily-entry:5f3acbd5-676e-4cb3-83a4-150b09c735a9"
      },
      body: JSON.stringify(validDailyRequest())
    }), {
      environment: { GROQ_API_KEY: environment.GROQ_API_KEY },
      fetch: provider,
      auth: harness.auth
    });

    expect(response.status).toBe(503);
    expect(provider).not.toHaveBeenCalled();
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "provider_policy_unverified" }
    });
  });

  it("calls Fireworks directly with its server-side API key", async () => {
    const harness = await authenticatedHarness();
    const provider = vi.fn<typeof fetch>(async (_input, init) => {
      expect(init?.headers).toMatchObject({ Authorization: "Bearer test-fireworks-key-never-use-live" });
      return Response.json({
        id: "chatcmpl_route_1",
        model: "accounts/fireworks/models/gpt-oss-120b",
        choices: [{
          index: 0,
          finish_reason: "stop",
          message: {
            role: "assistant",
            content: JSON.stringify({
              status: "completed",
              entry: {
                title: "Synthetic day",
                title_source_references: ["s1"],
                perspective: "third_person",
                sentences: [{
                  text: "Maya recorded a synthetic note.",
                  source_references: ["s1"],
                  fact_references: [],
                  preserves_uncertainty: false
                }]
              },
              memory_candidates: [],
              uncertainties: [],
              sensitive_omissions: [],
              quality_flags: [],
              follow_up_questions: [],
              refusal_reason: null
            })
          }
        }]
      });
    });
    const response = await handleDailyEntry(new Request("https://lore.invalid/v1/daily-entries", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${harness.token}`,
        "Content-Type": "application/json",
        "Idempotency-Key": "daily-entry:5f3acbd5-676e-4cb3-83a4-150b09c735a9"
      },
      body: JSON.stringify(validDailyRequest())
    }), {
      environment,
      fetch: provider,
      auth: harness.auth
    });

    expect(response.status).toBe(200);
    expect(provider).toHaveBeenCalledOnce();
  });

  it("returns a stable invalid-request error for malformed JSON", async () => {
    const harness = await authenticatedHarness();
    const provider = vi.fn<typeof fetch>();
    const response = await handleDailyEntry(new Request("https://lore.invalid/v1/daily-entries", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${harness.token}`,
        "Content-Type": "application/json"
      },
      body: "{not-json"
    }), { environment, fetch: provider, auth: harness.auth });

    expect(response.status).toBe(400);
    expect(provider).not.toHaveBeenCalled();
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "invalid_request", retryable: false }
    });
  });
});

async function authenticatedHarness() {
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
    keyIdHash: "d".repeat(64),
    publicKeyPem: "synthetic-public-key",
    receiptCiphertext: "synthetic-encrypted-receipt",
    environment: "production",
    validationCategory: 4,
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
    allowedValidationCategories: new Set([2, 4]),
    sessionSigningSecret: "session-signing-secret-at-least-32-bytes",
    stateHmacSecret: "state-reference-secret-at-least-32-bytes",
    receiptEncryptionKey: Buffer.alloc(32, 7),
    databaseUrl: "postgresql://test.invalid/lore",
    sessionTtlSeconds: 600,
    challengeTtlSeconds: 300,
    processingLeaseTtlSeconds: 90
  };
}

function validDailyRequest(): Record<string, unknown> {
  return {
    schema_version: "1.0",
    prompt_version: "grounded-journal-v1",
    job_id: "5f3acbd5-676e-4cb3-83a4-150b09c735a9",
    note_id: "f8a383e5-8830-41e4-a92f-257fa295d41b",
    transcript_artifact_id: "6343dc64-1e69-41ae-ac52-6e9f65a7bc2e",
    transcript_version_id: "82b6e4bb-fe09-4d9f-b0ec-42ee851f7efc",
    captured_local_date: "2026-07-16",
    language_code: "en-US",
    subject: { display_name: "Maya", pronouns: [] },
    render_configuration: { perspective: "third_person", tense: "past", tone: "warm_restrained", target_words: 130 },
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
