import { describe, expect, it, vi } from "vitest";
import type { GroqRuntimeConfig } from "../src/config.js";
import type { TranscriptionMetadata } from "../src/contracts/transcription.js";
import { LoreApiError } from "../src/http/errors.js";
import { GroqClient } from "../src/providers/groq/client.js";

const config: GroqRuntimeConfig = {
  apiKey: "test-key-never-use-live",
  policyVersion: "test-policy-v1",
  baseUrl: "https://api.groq.test/openai/v1",
  transcriptionModel: "whisper-large-v3-turbo"
};

const metadata: TranscriptionMetadata = {
  schema_version: "1.0",
  job_id: "9f170d1f-8e71-4a12-a861-2ca5f9f52ed2",
  idempotency_key: "transcription:note-1:revision-1:chunk-0",
  chunk_id: "chunk-0",
  chunk_index: 0,
  chunk_count: 1,
  start_milliseconds: 5_000,
  duration_milliseconds: 12_000,
  language_code: "en-US",
  vocabulary_hints: ["Hyderabad"],
  retention_policy: { mode: "request_ephemeral", maximum_retention_seconds: 0 }
};

describe("GroqClient", () => {
  it("posts verbose Whisper audio with language and bounded vocabulary context", async () => {
    const fetchMock = vi.fn<typeof fetch>(async (input, init) => {
      expect(input).toBe("https://api.groq.test/openai/v1/audio/transcriptions");
      expect(init?.headers).toEqual({ Authorization: "Bearer test-key-never-use-live" });
      const form = init?.body as FormData;
      expect(form.get("model")).toBe("whisper-large-v3-turbo");
      expect(form.get("response_format")).toBe("verbose_json");
      expect(form.get("timestamp_granularities[]")).toBe("segment");
      expect(form.get("temperature")).toBe("0");
      expect(form.get("language")).toBe("en");
      expect(form.get("prompt")).toContain("Hyderabad");
      return Response.json({
        text: "I went home.",
        language: "en",
        segments: [{ id: 0, start: 1.25, end: 3.5, text: " I went home." }],
        x_groq: { id: "req_groq_audio_1" }
      });
    });
    const client = new GroqClient({
      config,
      fetch: fetchMock,
      now: () => new Date("2026-07-16T12:00:00.000Z")
    });

    const response = await client.transcribe(
      "req_lore_1",
      metadata,
      { bytes: new Blob(["audio"], { type: "audio/m4a" }), filename: "note.m4a", mimeType: "audio/m4a" }
    );

    expect(response.segments[0]).toMatchObject({
      chunk_id: "chunk-0",
      start_milliseconds: 6_250,
      end_milliseconds: 8_500
    });
    expect(response.provenance).toMatchObject({
      provider_id: "groq",
      model_alias: "transcription-fallback-v1",
      model_id: "whisper-large-v3-turbo",
      provider_request_id: "req_groq_audio_1",
      retention_attestation: {
        mode: "request_ephemeral",
        maximum_retention_seconds: 0,
        policy_version: "request-ephemeral-v1"
      }
    });
  });

  it("bounds vocabulary prompts sent to Groq", async () => {
    const fetchMock = vi.fn<typeof fetch>(async (_input, init) => {
      const prompt = String((init?.body as FormData).get("prompt"));
      expect(Array.from(prompt).length).toBeLessThanOrEqual(221);
      return Response.json({ text: "Synthetic transcript." });
    });
    const client = new GroqClient({ config, fetch: fetchMock });
    await client.transcribe("req_lore_2", {
      ...metadata,
      vocabulary_hints: ["x".repeat(100), "y".repeat(100), "z".repeat(100)]
    }, { bytes: new Blob(["audio"]), filename: "note.m4a", mimeType: "audio/m4a" });
  });

  it("maps Groq rate limits without exposing the provider body", async () => {
    const client = new GroqClient({
      config,
      fetch: vi.fn<typeof fetch>(async () => new Response(
        JSON.stringify({ error: { message: "sensitive provider detail" } }),
        { status: 429, headers: { "retry-after": "7" } }
      ))
    });

    let caught: unknown;
    try {
      await client.transcribe(
        "req_lore_3",
        metadata,
        { bytes: new Blob(["audio"]), filename: "note.m4a", mimeType: "audio/m4a" }
      );
    } catch (error) {
      caught = error;
    }
    expect(caught).toBeInstanceOf(LoreApiError);
    expect(caught).toMatchObject({ code: "provider_rate_limited", retryAfterSeconds: 7 });
    expect((caught as Error).message).not.toContain("sensitive provider detail");
  });
});
