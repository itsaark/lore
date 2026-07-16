import { describe, expect, it, vi } from "vitest";
import type { GroqRuntimeConfig } from "../src/config.js";
import { type DailyEntryGenerationRequest } from "../src/contracts/daily-entry.js";
import type { TranscriptionMetadata } from "../src/contracts/transcription.js";
import { LoreApiError } from "../src/http/errors.js";
import { GroqClient } from "../src/providers/groq/client.js";
import { GroqDailyEntryJsonSchema } from "../src/providers/groq/provider-schemas.js";

const config: GroqRuntimeConfig = {
  apiKey: "test-key-never-use-live",
  policyVersion: "test-policy-v1",
  baseUrl: "https://api.groq.test/openai/v1",
  transcriptionModel: "whisper-large-v3-turbo",
  dailyEntryModel: "openai/gpt-oss-120b"
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

const dailyRequest: DailyEntryGenerationRequest = {
  schema_version: "1.0",
  prompt_version: "grounded-journal-v1",
  job_id: "5f3acbd5-676e-4cb3-83a4-150b09c735a9",
  note_id: "f8a383e5-8830-41e4-a92f-257fa295d41b",
  transcript_artifact_id: "6343dc64-1e69-41ae-ac52-6e9f65a7bc2e",
  transcript_version_id: "82b6e4bb-fe09-4d9f-b0ec-42ee851f7efc",
  captured_local_date: "2026-07-16",
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
    chunk_id: "chunk-0",
    start_milliseconds: 0,
    end_milliseconds: 8_200,
    text: "Synthetic journal fixture.",
    confidence: null,
    speaker_label: null
  }],
  accepted_prior_facts: [],
  retention_policy: { mode: "request_ephemeral", maximum_retention_seconds: 0 }
};

describe("GroqClient", () => {
  it("builds a strict provider schema with required fields on every object", () => {
    assertStrictObjects(GroqDailyEntryJsonSchema);
  });

  it("maps verbose Whisper segments to absolute source timestamps", async () => {
    const fetchMock = vi.fn<typeof fetch>(async (_input, init) => {
      expect(init?.headers).toEqual({ Authorization: "Bearer test-key-never-use-live" });
      const form = init?.body as FormData;
      expect(form.get("model")).toBe("whisper-large-v3-turbo");
      expect(form.get("response_format")).toBe("verbose_json");
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

    expect(response.request_id).toBe("req_lore_1");
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
      model_policy_version: "test-policy-v1",
      retention_attestation: {
        mode: "request_ephemeral",
        maximum_retention_seconds: 0,
        policy_version: "request-ephemeral-v1"
      }
    });
  });

  it("requests strict GPT-OSS JSON Schema and validates source references", async () => {
    const fetchMock = vi.fn<typeof fetch>(async (_input, init) => {
      const body = JSON.parse(String(init?.body));
      expect(body.model).toBe("openai/gpt-oss-120b");
      expect(body.response_format.type).toBe("json_schema");
      expect(body.response_format.json_schema.strict).toBe(true);
      expect(body.stream).toBe(false);
      expect(body.max_completion_tokens).toBe(4_096);
      expect(body.messages[1].content).toContain("<lore_source_data>");

      return Response.json({
        id: "chatcmpl_1",
        model: "openai/gpt-oss-120b",
        choices: [{
          index: 0,
          finish_reason: "stop",
          message: {
            role: "assistant",
            content: JSON.stringify({
              status: "completed",
              entry: {
                title: "A return home",
                title_source_references: ["s1"],
                perspective: "third_person",
                sentences: [{
                  text: "Maya returned home.",
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
        }],
        x_groq: { id: "req_groq_chat_1" }
      });
    });
    const client = new GroqClient({
      config,
      fetch: fetchMock,
      now: () => new Date("2026-07-16T12:00:00.000Z")
    });

    const response = await client.generateDailyEntry("req_lore_2", dailyRequest);

    expect(response.entry.title).toBe("A return home");
    expect(response.prompt_version).toBe("grounded-journal-v1");
    expect(response.provenance.provider_request_id).toBe("req_groq_chat_1");
  });

  it("rejects a model response containing an unknown source reference", async () => {
    const fetchMock = vi.fn<typeof fetch>(async () => Response.json({
      id: "chatcmpl_2",
      model: "openai/gpt-oss-120b",
      choices: [{
        index: 0,
        finish_reason: "stop",
        message: {
          role: "assistant",
          content: JSON.stringify({
            status: "completed",
            entry: {
              title: "Unsupported",
              title_source_references: ["invented-source"],
              perspective: "third_person",
              sentences: [{
                text: "An unsupported claim.",
                source_references: ["invented-source"],
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
    }));
    const client = new GroqClient({ config, fetch: fetchMock });

    await expect(client.generateDailyEntry("req_lore_3", dailyRequest))
      .rejects.toMatchObject({ code: "invalid_provider_response", retryable: false });
  });

  it("maps Groq rate limits without exposing the provider body", async () => {
    const fetchMock = vi.fn<typeof fetch>(async () => new Response(
      JSON.stringify({ error: { message: "sensitive provider detail", type: "rate_limit" } }),
      { status: 429, headers: { "retry-after": "7", "content-type": "application/json" } }
    ));
    const client = new GroqClient({ config, fetch: fetchMock });

    let caught: unknown;
    try {
      await client.transcribe(
        "req_lore_4",
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

function assertStrictObjects(value: unknown): void {
  if (Array.isArray(value)) {
    value.forEach(assertStrictObjects);
    return;
  }
  if (typeof value !== "object" || value === null) return;

  const object = value as Record<string, unknown>;
  if (object.type === "object" && typeof object.properties === "object" && object.properties !== null) {
    expect(object.additionalProperties).toBe(false);
    const propertyNames = Object.keys(object.properties as Record<string, unknown>).sort();
    expect([...(object.required as string[] | undefined ?? [])].sort()).toEqual(propertyNames);
  }
  Object.values(object).forEach(assertStrictObjects);
}
