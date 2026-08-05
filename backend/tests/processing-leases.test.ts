import { describe, expect, it, vi } from "vitest";
import { handleDailyEntry } from "../api/v1/daily-entries.js";
import { handleTranscription } from "../api/v1/transcriptions.js";
import { processingClaimReference } from "../src/auth/processing-lease.js";
import { issueSessionToken } from "../src/auth/session-token.js";
import {
  MemoryAuthStateStore,
  type AppAttestKeyRecord
} from "../src/auth/state-store.js";
import type { AppAttestRuntimeConfig } from "../src/config.js";

const baseTime = new Date("2026-08-03T20:00:00.000Z");
const keyRef = "a".repeat(64);
const environment = {
  FIREWORKS_API_KEY: "test-fireworks-key-never-use-live",
  GROQ_API_KEY: "test-groq-key-never-use-live"
};

describe("durable processing leases", () => {
  it("allows one Memory-store winner, permits expiry takeover, and rejects stale release", async () => {
    const store = new MemoryAuthStateStore();
    const first = await store.acquireProcessingLease({
      claimRef: "b".repeat(64),
      leaseToken: "first-opaque-token-1234567890",
      now: baseTime,
      expiresAt: new Date(baseTime.getTime() + 10_000)
    });
    const duplicate = await store.acquireProcessingLease({
      claimRef: "b".repeat(64),
      leaseToken: "duplicate-token-1234567890",
      now: new Date(baseTime.getTime() + 1_000),
      expiresAt: new Date(baseTime.getTime() + 11_000)
    });
    const takeover = await store.acquireProcessingLease({
      claimRef: "b".repeat(64),
      leaseToken: "takeover-token-1234567890",
      now: new Date(baseTime.getTime() + 10_000),
      expiresAt: new Date(baseTime.getTime() + 20_000)
    });

    expect(first.status).toBe("acquired");
    expect(duplicate.status).toBe("active");
    expect(takeover.status).toBe("acquired");
    await expect(store.releaseProcessingLease({
      claimRef: "b".repeat(64),
      leaseToken: "first-opaque-token-1234567890"
    })).resolves.toBe(false);
    await expect(store.acquireProcessingLease({
      claimRef: "b".repeat(64),
      leaseToken: "third-token-12345678901234",
      now: new Date(baseTime.getTime() + 11_000),
      expiresAt: new Date(baseTime.getTime() + 21_000)
    })).resolves.toMatchObject({ status: "active" });
  });

  it("HMAC-scopes claims by installation and task without exposing raw identity", () => {
    const common = {
      secret: "state-reference-secret-at-least-32-bytes",
      installationRef: keyRef,
      task: "daily_entry" as const,
      taskId: "5f3acbd5-676e-4cb3-83a4-150b09c735a9",
      idempotencyKey: "daily-entry:5f3acbd5-676e-4cb3-83a4-150b09c735a9"
    };
    const claim = processingClaimReference(common);

    expect(claim).toMatch(/^[a-f0-9]{64}$/);
    expect(claim).not.toContain(common.installationRef);
    expect(claim).not.toContain(common.idempotencyKey);
    expect(processingClaimReference({ ...common, task: "transcription" })).not.toBe(claim);
    expect(processingClaimReference({ ...common, installationRef: "c".repeat(64) })).not.toBe(claim);
  });

  it("returns one stable retryable 409 for a concurrent daily-entry duplicate", async () => {
    const harness = await authenticatedHarness();
    let unblockProvider: (() => void) | undefined;
    const providerGate = new Promise<void>((resolve) => { unblockProvider = resolve; });
    const provider = vi.fn<typeof fetch>(async () => {
      await providerGate;
      return fireworksResponse();
    });
    const first = handleDailyEntry(dailyRequest(harness.token), {
      environment,
      fetch: provider,
      auth: { config: harness.config, store: harness.store, now: baseTime }
    });
    await vi.waitFor(() => expect(provider).toHaveBeenCalledOnce());

    const duplicate = await handleDailyEntry(dailyRequest(harness.token), {
      environment,
      fetch: provider,
      auth: { config: harness.config, store: harness.store, now: baseTime }
    });

    expect(duplicate.status).toBe(409);
    expect(duplicate.headers.get("Retry-After")).toBe("90");
    await expect(duplicate.json()).resolves.toMatchObject({
      error: { code: "processing_in_progress", retryable: true },
      retry_after_seconds: 90
    });
    expect(provider).toHaveBeenCalledOnce();

    unblockProvider?.();
    expect((await first).status).toBe(200);
  });

  it("blocks an active transcription claim before Groq invocation", async () => {
    const harness = await authenticatedHarness();
    const idempotencyKey = "transcription:note-1:revision-1:chunk-0";
    const claimRef = processingClaimReference({
      secret: harness.config.stateHmacSecret,
      installationRef: keyRef,
      task: "transcription",
      taskId: "9f170d1f-8e71-4a12-a861-2ca5f9f52ed2:chunk-0",
      idempotencyKey
    });
    await harness.store.acquireProcessingLease({
      claimRef,
      leaseToken: "existing-transcription-token",
      now: baseTime,
      expiresAt: new Date(baseTime.getTime() + 45_000)
    });
    const provider = vi.fn<typeof fetch>();

    const response = await handleTranscription(transcriptionRequest(harness.token, idempotencyKey), {
      environment,
      fetch: provider,
      auth: { config: harness.config, store: harness.store, now: baseTime }
    });

    expect(response.status).toBe(409);
    expect(response.headers.get("Retry-After")).toBe("45");
    expect(provider).not.toHaveBeenCalled();
  });

  it("rejects mismatched transcription idempotency headers before provider invocation", async () => {
    const harness = await authenticatedHarness();
    const provider = vi.fn<typeof fetch>();
    const response = await handleTranscription(
      transcriptionRequest(harness.token, "different-idempotency-key"),
      {
        environment,
        fetch: provider,
        auth: { config: harness.config, store: harness.store, now: baseTime }
      }
    );

    expect(response.status).toBe(400);
    expect(provider).not.toHaveBeenCalled();
  });

  it("rejects a daily-entry header not scoped to job_id before provider invocation", async () => {
    const harness = await authenticatedHarness();
    const provider = vi.fn<typeof fetch>();
    const request = dailyRequest(harness.token, "daily-entry:wrong-job-id");
    const response = await handleDailyEntry(request, {
      environment,
      fetch: provider,
      auth: { config: harness.config, store: harness.store, now: baseTime }
    });

    expect(response.status).toBe(400);
    expect(provider).not.toHaveBeenCalled();
  });

  it("fails closed with zero provider calls when lease acquisition fails", async () => {
    const store = new FailingLeaseStore();
    const harness = await authenticatedHarness(store);
    const provider = vi.fn<typeof fetch>();
    const response = await handleDailyEntry(dailyRequest(harness.token), {
      environment,
      fetch: provider,
      auth: { config: harness.config, store, now: baseTime }
    });

    expect(response.status).toBe(503);
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "auth_unavailable", retryable: true }
    });
    expect(provider).not.toHaveBeenCalled();
  });

  it("releases the lease in finally when the provider fails", async () => {
    const harness = await authenticatedHarness();
    const provider = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(new Response("temporarily unavailable", { status: 503 }))
      .mockResolvedValueOnce(fireworksResponse());
    const dependencies = {
      environment,
      fetch: provider,
      auth: { config: harness.config, store: harness.store, now: baseTime }
    };

    const failed = await handleDailyEntry(dailyRequest(harness.token), dependencies);
    const retried = await handleDailyEntry(dailyRequest(harness.token), dependencies);

    expect(failed.status).toBe(503);
    expect(retried.status).toBe(200);
    expect(provider).toHaveBeenCalledTimes(2);
  });
});

class FailingLeaseStore extends MemoryAuthStateStore {
  override async acquireProcessingLease(): Promise<never> {
    throw new Error("synthetic database outage");
  }
}

async function authenticatedHarness(store = new MemoryAuthStateStore()) {
  const config = testConfig();
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
    validationCategory: null,
    bundleVersion: null,
    counter: 0,
    createdAt: baseTime,
    updatedAt: baseTime
  };
  await store.registerKeyWithChallenge({
    challenge: { id: challengeId, challengeHash: "challenge-hash", purpose: "attestation", now: baseTime },
    key
  });
  const token = issueSessionToken(keyRef, config, baseTime).token;
  return { config, store, token };
}

function testConfig(): AppAttestRuntimeConfig {
  return {
    teamIdentifier: "ABCDE12345",
    bundleIdentifier: "cascadianpines.lore",
    allowedAttestationEnvironments: new Set(["development", "production"]),
    environment: "production",
    allowedValidationCategories: new Set([4]),
    sessionSigningSecret: "session-signing-secret-at-least-32-bytes",
    stateHmacSecret: "state-reference-secret-at-least-32-bytes",
    receiptEncryptionKey: Buffer.alloc(32, 7),
    databaseUrl: "postgresql://test.invalid/lore",
    sessionTtlSeconds: 600,
    challengeTtlSeconds: 300,
    processingLeaseTtlSeconds: 90
  };
}

function dailyRequest(token: string, idempotencyKey = "daily-entry:5f3acbd5-676e-4cb3-83a4-150b09c735a9"): Request {
  return new Request("https://lore.invalid/v1/daily-entries", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "Idempotency-Key": idempotencyKey
    },
    body: JSON.stringify(validDailyRequest())
  });
}

function transcriptionRequest(token: string, headerIdempotencyKey: string): Request {
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
  return new Request("https://lore.invalid/v1/transcriptions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Idempotency-Key": headerIdempotencyKey
    },
    body: form
  });
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

function fireworksResponse(): Response {
  return Response.json({
    id: "chatcmpl_lease_test",
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
}
