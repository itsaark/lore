import { describe, expect, it, vi } from "vitest";
import { handleReflectionFinalize } from "../api/v1/reflections/finalize.js";
import { handleReflectionSessionCredentials } from "../api/v1/reflections/session-credentials.js";
import { handleReflectionGuide } from "../api/v1/reflections/respond.js";
import { issueSessionToken } from "../src/auth/session-token.js";
import { MemoryAuthStateStore, type AppAttestKeyRecord } from "../src/auth/state-store.js";
import {
  ReflectionFinalizationRequestSchema,
  ReflectionGuideRequestSchema
} from "../src/contracts/reflection.js";
import type { AppAttestRuntimeConfig } from "../src/config.js";

const baseTime = new Date("2026-08-14T20:00:00.000Z");
const keyRef = "b".repeat(64);
const sessionId = "f8a383e5-8830-41e4-a92f-257fa295d41b";
const userTurnId = "6343dc64-1e69-41ae-ac52-6e9f65a7bc2e";
const loreTurnId = "82b6e4bb-fe09-4d9f-b0ec-42ee851f7efc";
const jobId = "5f3acbd5-676e-4cb3-83a4-150b09c735a9";
const environment = {
  FIREWORKS_API_KEY: "test-fireworks-key-never-use-live",
  SONIOX_API_KEY: "test-soniox-key-never-use-live",
  SONIOX_TTS_VOICE: "Adrian"
};

describe("reflection contracts", () => {
  it("rejects Lore turns marked as factual evidence", () => {
    const request = validGuideRequest();
    request.turns = [{
      id: loreTurnId,
      sequence: 0,
      role: "lore",
      text: "What happened next?",
      is_evidence_eligible: true
    }];
    expect(ReflectionGuideRequestSchema.safeParse(request).success).toBe(false);
  });

  it("rejects assistant turn IDs that overlap evidence turns", () => {
    const request = validFinalizeRequest();
    request.assistant_turns = [{ turn_id: userTurnId, sequence: 0, text: "What happened?" }];
    expect(ReflectionFinalizationRequestSchema.safeParse(request).success).toBe(false);
  });
});

describe("reflection routes", () => {
  it("mints separate single-use Soniox STT and TTS keys", async () => {
    const harness = await authenticatedHarness();
    const provider = vi.fn<typeof fetch>(async (_input, init) => {
      expect(init?.headers).toMatchObject({ Authorization: "Bearer test-soniox-key-never-use-live" });
      const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
      expect(body).toMatchObject({
        single_use: true,
        max_session_duration_seconds: 1_200,
        client_reference_id: `reflection:${sessionId}`
      });
      const usage = String(body.usage_type);
      return Response.json({
        api_key: usage === "tts_rt" ? "temp:tts" : "temp:stt",
        expires_at: "2026-08-14T20:05:00.000Z"
      }, { status: 201 });
    });

    const response = await handleReflectionSessionCredentials(new Request(
      "https://lore.invalid/v1/reflections/session-credentials",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${harness.token}`,
          "Content-Type": "application/json",
          "Idempotency-Key": `reflection-credentials:${sessionId}`
        },
        body: JSON.stringify({ schema_version: "1.0", session_id: sessionId, language_code: "en-US" })
      }
    ), { environment, fetch: provider, auth: harness.auth });

    expect(response.status).toBe(200);
    expect(provider).toHaveBeenCalledTimes(2);
    const usages = provider.mock.calls.map((call) => JSON.parse(String(call[1]?.body)).usage_type);
    expect(usages).toEqual(expect.arrayContaining(["transcribe_websocket", "tts_rt"]));
    await expect(response.json()).resolves.toMatchObject({
      session_id: sessionId,
      stt: { temporary_api_key: "temp:stt", sample_rate: 16_000, num_channels: 1 },
      tts: { temporary_api_key: "temp:tts", sample_rate: 24_000, voice: "Adrian" },
      maximum_session_duration_seconds: 1_200
    });
  });

  it("generates one bounded guide question from finalized turns", async () => {
    const harness = await authenticatedHarness();
    const provider = vi.fn<typeof fetch>(async (_input, init) => {
      const providerBody = JSON.parse(String(init?.body)) as { messages: Array<{ content: string }> };
      expect(providerBody.messages[1]?.content).toContain("A walk by the river felt peaceful.");
      return Response.json({
        id: "chatcmpl_reflect_guide",
        model: "accounts/fireworks/models/gpt-oss-120b",
        choices: [{
          index: 0,
          finish_reason: "stop",
          message: {
            role: "assistant",
            content: JSON.stringify({
              spoken_text: "What made that walk feel especially peaceful?",
              should_offer_finish: false
            })
          }
        }]
      });
    });
    const requestBody = validGuideRequest();
    const response = await handleReflectionGuide(new Request(
      "https://lore.invalid/v1/reflections/respond",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${harness.token}`,
          "Content-Type": "application/json",
          "Idempotency-Key": `reflection-response:${sessionId}:${userTurnId}`
        },
        body: JSON.stringify(requestBody)
      }
    ), { environment, fetch: provider, auth: harness.auth });

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      session_id: sessionId,
      spoken_text: "What made that walk feel especially peaceful?",
      should_offer_finish: false,
      provenance: { model_alias: "reflection-guide-v1" }
    });
  });

  it("finalizes only user source segments into a third-person entry", async () => {
    const harness = await authenticatedHarness();
    const provider = vi.fn<typeof fetch>(async (_input, init) => {
      const providerBody = JSON.parse(String(init?.body)) as { messages: Array<{ content: string }> };
      expect(providerBody.messages[1]?.content).toContain("assistant_turns");
      return Response.json({
        id: "chatcmpl_reflect_entry",
        model: "accounts/fireworks/models/gpt-oss-120b",
        choices: [{
          index: 0,
          finish_reason: "stop",
          message: {
            role: "assistant",
            content: JSON.stringify({
              status: "completed",
              entry: {
                title: "A peaceful walk",
                title_source_references: ["s1"],
                perspective: "third_person",
                sentences: [{
                  text: "Maya found a walk by the river peaceful.",
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

    const response = await handleReflectionFinalize(new Request(
      "https://lore.invalid/v1/reflections/finalize",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${harness.token}`,
          "Content-Type": "application/json",
          "Idempotency-Key": `reflection-finalize:${jobId}`
        },
        body: JSON.stringify(validFinalizeRequest())
      }
    ), { environment, fetch: provider, auth: harness.auth });

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      job_id: jobId,
      entry: { perspective: "third_person", title_source_references: ["s1"] },
      provenance: { model_alias: "reflection-entry-v1" }
    });
  });
});

function validGuideRequest(): any {
  return {
    schema_version: "1.0",
    prompt_version: "reflection-guide-v1",
    session_id: sessionId,
    language_code: "en-US",
    subject: { display_name: "Maya", pronouns: ["she", "her"] },
    turns: [{
      id: userTurnId,
      sequence: 0,
      role: "user",
      text: "A walk by the river felt peaceful.",
      is_evidence_eligible: true
    }],
    accepted_prior_facts: [],
    retention_policy: { mode: "request_ephemeral", maximum_retention_seconds: 0 }
  };
}

function validFinalizeRequest(): any {
  return {
    schema_version: "1.0",
    prompt_version: "reflection-entry-v1",
    session_id: sessionId,
    entry_request: {
      schema_version: "1.0",
      prompt_version: "grounded-journal-v1",
      job_id: jobId,
      note_id: sessionId,
      transcript_artifact_id: "9f170d1f-8e71-4a12-a861-2ca5f9f52ed2",
      transcript_version_id: "3b9cc686-e6bd-474e-99ac-85eeaf38b832",
      captured_local_date: "2026-08-14",
      language_code: "en-US",
      subject: { display_name: "Maya", pronouns: ["she", "her"] },
      render_configuration: {
        perspective: "third_person",
        tense: "past",
        tone: "warm_restrained",
        target_words: 130
      },
      source_segments: [{
        id: "s1",
        chunk_id: "turn-0",
        start_milliseconds: 0,
        end_milliseconds: 3_000,
        text: "A walk by the river felt peaceful.",
        confidence: 0.97,
        speaker_label: null
      }],
      accepted_prior_facts: [],
      retention_policy: { mode: "request_ephemeral", maximum_retention_seconds: 0 }
    },
    evidence_turns: [{ turn_id: userTurnId, source_segment_ids: ["s1"] }],
    assistant_turns: [{ turn_id: loreTurnId, sequence: 1, text: "What made it peaceful?" }]
  };
}

async function authenticatedHarness() {
  const config = testConfig();
  const store = new MemoryAuthStateStore();
  const challengeId = "6aa0cf7e-1fe7-479f-a896-11cd9d877c72";
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
