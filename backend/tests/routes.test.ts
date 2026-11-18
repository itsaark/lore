import { describe, expect, it, vi } from "vitest";
import { handleDailyEntry } from "../api/v1/daily-entries.js";
import { handleDayIllustration } from "../api/v1/day-illustrations.js";
import { handleStoryChapter } from "../api/v1/story-chapters.js";
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

  it("accepts Swift daily-entry JSON with omitted nullable segment metadata", async () => {
    const harness = await authenticatedHarness();
    const requestBody = validDailyRequest();
    const [segment] = requestBody.source_segments as Array<Record<string, unknown>>;
    if (!segment) throw new Error("fixture must include one segment");
    delete segment.confidence;
    delete segment.speaker_label;

    const provider = vi.fn<typeof fetch>(async (_input, init) => {
      const body = JSON.parse(String(init?.body)) as {
        messages: Array<{ role: string; content: string }>;
      };
      const sourcePayload = body.messages.find((message) => message.role === "user")?.content;
      expect(sourcePayload).toContain('"confidence":null');
      expect(sourcePayload).toContain('"speaker_label":null');
      return Response.json({
        id: "chatcmpl_route_omitted_metadata",
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
      body: JSON.stringify(requestBody)
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

  it("writes a month chapter from finished days and cites day ids", async () => {
    const harness = await authenticatedHarness();
    const provider = vi.fn<typeof fetch>(async (_input, init) => {
      const body = JSON.parse(String(init?.body));
      expect(body.messages[0].content).toContain("one chapter of a person's autobiography");
      expect(body.messages[0].content).toContain("Do not stamp sentences with calendar dates");
      expect(body.messages[1].content).toContain("<lore_chapter_data>");
      expect(body.messages[1].content).toContain("2026-07-02");
      return Response.json({
        id: "chatcmpl_chapter_1",
        model: "accounts/fireworks/models/gpt-oss-120b",
        choices: [{
          index: 0,
          finish_reason: "stop",
          message: {
            role: "assistant",
            content: JSON.stringify({
              status: "completed",
              entry: {
                title: "A month by the water",
                title_source_references: ["2026-07-01", "2026-07-02"],
                perspective: "third_person",
                sentences: [
                  { text: "Maya began July at the harbor.", source_references: ["2026-07-01"], fact_references: [], preserves_uncertainty: false },
                  { text: "By the second day the market had her attention.", source_references: ["2026-07-02"], fact_references: [], preserves_uncertainty: false }
                ]
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
    const response = await handleStoryChapter(new Request("https://lore.invalid/v1/story-chapters", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${harness.token}`,
        "Content-Type": "application/json",
        "Idempotency-Key": "story-chapter:5f3acbd5-676e-4cb3-83a4-150b09c735a9"
      },
      body: JSON.stringify(validChapterRequest())
    }), { environment, fetch: provider, auth: harness.auth });

    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body).toMatchObject({
      prompt_version: "story-chapter-v1",
      job_id: "5f3acbd5-676e-4cb3-83a4-150b09c735a9",
      entry: { title: "A month by the water" }
    });
    expect(body).not.toHaveProperty("memory_candidates");
  });

  it("rejects a chapter whose idempotency key does not match its job", async () => {
    const harness = await authenticatedHarness();
    const provider = vi.fn<typeof fetch>();
    const response = await handleStoryChapter(new Request("https://lore.invalid/v1/story-chapters", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${harness.token}`,
        "Content-Type": "application/json",
        "Idempotency-Key": "story-chapter:00000000-0000-4000-8000-000000000000"
      },
      body: JSON.stringify(validChapterRequest())
    }), { environment, fetch: provider, auth: harness.auth });

    expect(response.status).toBe(400);
    expect(provider).not.toHaveBeenCalled();
  });

  it("rejects an unauthenticated chapter request before the provider", async () => {
    const provider = vi.fn<typeof fetch>();
    const response = await handleStoryChapter(new Request("https://lore.invalid/v1/story-chapters", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(validChapterRequest())
    }), { environment, fetch: provider });

    expect(response.status).toBe(401);
    expect(provider).not.toHaveBeenCalled();
  });
});

describe("day illustrations", () => {
  it("sends only the scene and style prompt to OpenAI and returns both provenances", async () => {
    const harness = await authenticatedHarness();
    const acquireLease = vi.spyOn(harness.auth.store, "acquireProcessingLease");
    const releaseLease = vi.spyOn(harness.auth.store, "releaseProcessingLease");
    const provider = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(daySceneCompletion(dayScene))
      .mockResolvedValueOnce(Response.json({ data: [{ b64_json: "/9j/2Q==" }] }, {
        headers: { "x-request-id": "image-request" }
      }));
    const request = validDayIllustrationRequest();
    const response = await handleDayIllustration(dayIllustrationRequest(harness.token, { body: request }), {
      environment: dayIllustrationEnvironment,
      fetch: provider,
      auth: harness.auth
    });

    expect(provider).toHaveBeenCalledTimes(2);
    const [sceneUrl, sceneInit] = provider.mock.calls[0]!;
    expect(sceneUrl).toBe("https://api.fireworks.ai/inference/v1/chat/completions");
    const sceneRequest = JSON.parse(String(sceneInit?.body));
    expect(JSON.parse(sceneRequest.messages[1].content)).toEqual({ title: request.title, prose: request.prose });
    expect(sceneRequest.response_format).toMatchObject({
      type: "json_schema",
      json_schema: {
        schema: { properties: { scene: { minLength: 40, maxLength: 800 } }, additionalProperties: false }
      }
    });

    const [imageUrl, imageInit] = provider.mock.calls[1]!;
    expect(imageUrl).toBe("https://api.openai.com/v1/images/generations");
    const imageRequestBody = String(imageInit?.body);
    expect(JSON.parse(imageRequestBody)).toEqual({
      model: "gpt-image-2.6-flare",
      prompt: `An original oil painting in the manner of Claude Monet's late Impressionism: loose, broken
brushstrokes, visible impasto, soft edges, shimmering reflected light, atmosphere over detail,
a luminous palette of lilac, sea-green, rose, pale gold and blue-grey. Composed with the quiet
interiority of a Virginia Woolf novel: a single held moment, light moving across a room, a window,
a garden or the sea, a feeling more than an event. No text, letters, numbers, signatures,
watermarks, logos, or frames. No recognisable faces. Portrait canvas.\n\nScene: ${dayScene}`,
      size: "1024x1536",
      quality: "medium",
      complexity: "low",
      moderation: "auto",
      output_format: "jpeg",
      output_compression: 80,
      n: 1
    });
    for (const privateValue of [request.title, request.prose, request.day_key, request.job_id, "illustration-request"]) {
      expect(imageRequestBody).not.toContain(privateValue);
    }
    expect(acquireLease).toHaveBeenCalledWith(expect.objectContaining({
      now: baseTime,
      expiresAt: new Date(baseTime.getTime() + 180_000)
    }));
    expect(releaseLease).toHaveBeenCalledOnce();
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    await expect(response.json()).resolves.toMatchObject({
      schema_version: "1.0",
      prompt_version: "day-illustration-v1",
      job_id: request.job_id,
      request_id: "illustration-request",
      image: { media_type: "image/jpeg", data_base64: "/9j/2Q==", pixel_width: 1024, pixel_height: 1536 },
      scene: { description: dayScene },
      scene_provenance: {
        provider_id: "fireworks", model_alias: "day-scene-v1", provider_request_id: "scene-request"
      },
      provenance: {
        provider_id: "openai", model_alias: "day-illustration-v1", provider_request_id: "image-request",
        model_id: "gpt-image-2.6-flare", model_policy_version: PROVIDER_POLICY_VERSION
      }
    });
  });

  it.each([
    ["a mismatched idempotency key", { idempotencyKey: "day-illustration:00000000-0000-4000-8000-000000000000" }],
    ["an unknown body field", { body: { ...validDayIllustrationRequest(), subject: "Unexpected" } }]
  ])("rejects %s before calling either provider", async (_reason, options) => {
    const harness = await authenticatedHarness();
    const provider = vi.fn<typeof fetch>();
    const response = await handleDayIllustration(dayIllustrationRequest(harness.token, options), {
      environment: dayIllustrationEnvironment,
      fetch: provider,
      auth: harness.auth
    });

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toMatchObject({ error: { code: "invalid_request", retryable: false } });
    expect(provider).not.toHaveBeenCalled();
  });

  it("enforces the byte limit without a Content-Length header", async () => {
    const harness = await authenticatedHarness();
    const provider = vi.fn<typeof fetch>();
    const response = await handleDayIllustration(dayIllustrationRequest(harness.token, {
      body: { ...validDayIllustrationRequest(), prose: "é".repeat(100_000) }
    }), { environment: dayIllustrationEnvironment, fetch: provider, auth: harness.auth });

    expect(response.status).toBe(413);
    expect(provider).not.toHaveBeenCalled();
  });

  it("returns a non-retryable 422 for OpenAI moderation and releases the lease", async () => {
    const harness = await authenticatedHarness();
    const releaseLease = vi.spyOn(harness.auth.store, "releaseProcessingLease");
    const provider = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(daySceneCompletion(dayScene))
      .mockResolvedValueOnce(Response.json({
        error: { code: "content_policy_violation", message: "Provider-only diagnostic" }
      }, { status: 400 }));
    const response = await handleDayIllustration(dayIllustrationRequest(harness.token), {
      environment: dayIllustrationEnvironment,
      fetch: provider,
      auth: harness.auth
    });

    expect(response.status).toBe(422);
    const body = await response.json();
    expect(body).toMatchObject({ error: { code: "invalid_provider_response", retryable: false } });
    expect(JSON.stringify(body)).not.toContain("Provider-only diagnostic");
    expect(releaseLease).toHaveBeenCalledOnce();
  });

  it("rejects digits in the scene before calling OpenAI", async () => {
    const harness = await authenticatedHarness();
    const provider = vi.fn<typeof fetch>().mockResolvedValueOnce(daySceneCompletion(`${dayScene} It is 6 PM.`));
    const response = await handleDayIllustration(dayIllustrationRequest(harness.token), {
      environment: dayIllustrationEnvironment,
      fetch: provider,
      auth: harness.auth
    });

    expect(response.status).toBe(422);
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "invalid_provider_response", retryable: false }
    });
    expect(provider).toHaveBeenCalledOnce();
  });

  it("checks OpenAI configuration before submitting private journal content", async () => {
    const harness = await authenticatedHarness();
    const provider = vi.fn<typeof fetch>();
    const response = await handleDayIllustration(dayIllustrationRequest(harness.token), {
      environment,
      fetch: provider,
      auth: harness.auth
    });

    expect(response.status).toBe(503);
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "provider_policy_unverified", retryable: false }
    });
    expect(provider).not.toHaveBeenCalled();
  });

  it("uses the Fireworks fallback and bounds the scene before sending it to OpenAI", async () => {
    const harness = await authenticatedHarness();
    const longScene = dayScene + " Soft gold.".repeat(80);
    const provider = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(null, { status: 503 }))
      .mockResolvedValueOnce(daySceneCompletion(longScene))
      .mockResolvedValueOnce(Response.json({ data: [{ b64_json: "/9j/2Q==" }] }));
    const response = await handleDayIllustration(dayIllustrationRequest(harness.token), {
      environment: dayIllustrationEnvironment,
      fetch: provider,
      auth: harness.auth
    });

    expect(response.status).toBe(200);
    expect(provider).toHaveBeenCalledTimes(3);
    expect(JSON.parse(String(provider.mock.calls[1]![1]?.body)).model).toBe("accounts/fireworks/models/gpt-oss-120b");
    const description = longScene.slice(0, 800).trimEnd();
    expect(JSON.parse(String(provider.mock.calls[2]![1]?.body)).prompt.endsWith(`\n\nScene: ${description}`)).toBe(true);
    await expect(response.json()).resolves.toMatchObject({ scene: { description } });
  });

  it.each([
    ["rate limit", () => Promise.resolve(new Response(null, { status: 429 })), 429, "provider_rate_limited"],
    ["server error", () => Promise.resolve(new Response(null, { status: 500 })), 503, "provider_unavailable"],
    ["timeout", () => Promise.reject(new DOMException("Timed out", "TimeoutError")), 503, "provider_unavailable"]
  ])("treats an OpenAI %s as retryable", async (_reason, generate, status, code) => {
    const harness = await authenticatedHarness();
    const provider = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(daySceneCompletion(dayScene))
      .mockImplementationOnce(generate);
    const response = await handleDayIllustration(dayIllustrationRequest(harness.token), {
      environment: dayIllustrationEnvironment,
      fetch: provider,
      auth: harness.auth
    });

    expect(response.status).toBe(status);
    await expect(response.json()).resolves.toMatchObject({ error: { code, retryable: true } });
  });
});

const dayIllustrationEnvironment = { ...environment, OPENAI_API_KEY: "mock-only" };
const dayIllustrationJobId = "5F3ACBD5-676E-4CB3-83A4-150B09C735A9";
const dayScene = "Lilac light falls on a blue-grey cup at dusk. Pale gold flickers on a rain-wet window.";

function validDayIllustrationRequest() {
  return {
    schema_version: "1.0",
    prompt_version: "day-illustration-v1",
    job_id: dayIllustrationJobId,
    day_key: "2026-11-17",
    language_code: "en_US",
    title: "Visiting Maya at the harbor",
    prose: "Maya and I watched the boats come in at the harbor.",
    retention_policy: { mode: "request_ephemeral", maximum_retention_seconds: 0 }
  };
}

function dayIllustrationRequest(token: string, options: { body?: unknown; idempotencyKey?: string } = {}) {
  return new Request("https://lore.invalid/v1/day-illustrations", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "Idempotency-Key": options.idempotencyKey ?? `day-illustration:${dayIllustrationJobId.toLowerCase()}`,
      "X-Request-ID": "illustration-request"
    },
    body: JSON.stringify(options.body ?? validDayIllustrationRequest())
  });
}

function daySceneCompletion(scene: string) {
  return Response.json({
    id: "scene-request",
    model: "accounts/fireworks/models/gpt-oss-120b",
    choices: [{
      index: 0,
      finish_reason: "stop",
      message: { role: "assistant", content: JSON.stringify({ scene }) }
    }]
  });
}

function validChapterRequest(): Record<string, unknown> {
  return {
    schema_version: "1.0",
    prompt_version: "story-chapter-v1",
    job_id: "5f3acbd5-676e-4cb3-83a4-150b09c735a9",
    chapter_key: "2026-07",
    language_code: "en-US",
    subject: { display_name: "Maya", pronouns: [] },
    render_configuration: { perspective: "third_person", tense: "past", tone: "warm_restrained", target_words: 300 },
    source_days: [
      { id: "2026-07-01", day_key: "2026-07-01", title: "The harbor", prose: "Maya walked the harbor at dawn." },
      { id: "2026-07-02", day_key: "2026-07-02", title: "The market", prose: "She spent the morning at the market." }
    ],
    retention_policy: { mode: "request_ephemeral", maximum_retention_seconds: 0 }
  };
}

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
