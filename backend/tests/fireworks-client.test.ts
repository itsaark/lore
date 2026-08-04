import { describe, expect, it, vi } from "vitest";
import type { FireworksRuntimeConfig } from "../src/config.js";
import type { DailyEntryGenerationRequest } from "../src/contracts/daily-entry.js";
import { LoreApiError } from "../src/http/errors.js";
import { FireworksClient } from "../src/providers/fireworks/client.js";
import { FireworksDailyEntryJsonSchema } from "../src/providers/fireworks/provider-schemas.js";

const config: FireworksRuntimeConfig = {
  apiKey: "test-key-never-use-live",
  policyVersion: "test-policy-v1",
  baseUrl: "https://api.fireworks.test/inference/v1",
  dailyEntryModel: "accounts/fireworks/models/gpt-oss-120b"
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

describe("FireworksClient", () => {
  it("builds a strict provider schema with required fields on every object", () => {
    assertStrictObjects(FireworksDailyEntryJsonSchema);
  });

  it("calls Fireworks Chat Completions with strict GPT-OSS JSON Schema", async () => {
    const fetchMock = vi.fn<typeof fetch>(async (input, init) => {
      expect(input).toBe("https://api.fireworks.test/inference/v1/chat/completions");
      expect(init?.headers).toEqual({
        Authorization: "Bearer test-key-never-use-live",
        "Content-Type": "application/json"
      });
      const body = JSON.parse(String(init?.body));
      expect(body.model).toBe("accounts/fireworks/models/gpt-oss-120b");
      expect(body.response_format).toEqual({
        type: "json_schema",
        json_schema: {
          name: "lore_daily_entry",
          schema: FireworksDailyEntryJsonSchema
        }
      });
      expect(body.prompt_cache_isolation_key).toBe("req_lore_2");
      expect(body.messages[1].content).toContain("<lore_source_data>");
      expect(body).not.toHaveProperty("store");
      expect(body).not.toHaveProperty("providerOptions");

      return Response.json(validCompletion(), { headers: { "x-request-id": "req_fireworks_1" } });
    });
    const client = new FireworksClient({
      config,
      fetch: fetchMock,
      now: () => new Date("2026-07-16T12:00:00.000Z")
    });

    const response = await client.generateDailyEntry("req_lore_2", dailyRequest);

    expect(response.entry.title).toBe("A return home");
    expect(response.provenance).toMatchObject({
      provider_id: "fireworks",
      model_alias: "daily-entry-v1",
      model_id: "accounts/fireworks/models/gpt-oss-120b",
      provider_request_id: "req_fireworks_1"
    });
  });

  it("rejects a model response containing an unknown source reference", async () => {
    const completion = validCompletion();
    completion.choices[0]!.message.content = JSON.stringify({
      ...validOutput(),
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
      }
    });
    const client = new FireworksClient({
      config,
      fetch: vi.fn<typeof fetch>(async () => Response.json(completion))
    });

    await expect(client.generateDailyEntry("req_lore_3", dailyRequest))
      .rejects.toMatchObject({ code: "invalid_provider_response", retryable: false });
  });

  it("maps provider failures without exposing the provider response body", async () => {
    const client = new FireworksClient({
      config,
      fetch: vi.fn<typeof fetch>(async () => new Response(
        JSON.stringify({ error: { message: "sensitive provider detail" } }),
        { status: 429, headers: { "retry-after": "7" } }
      ))
    });

    let caught: unknown;
    try {
      await client.generateDailyEntry("req_lore_4", dailyRequest);
    } catch (error) {
      caught = error;
    }
    expect(caught).toBeInstanceOf(LoreApiError);
    expect(caught).toMatchObject({ code: "provider_rate_limited", retryAfterSeconds: 7 });
    expect((caught as Error).message).not.toContain("sensitive provider detail");
  });
});

function validCompletion() {
  return {
    id: "chatcmpl_1",
    model: "accounts/fireworks/models/gpt-oss-120b",
    choices: [{
      index: 0,
      finish_reason: "stop",
      message: { role: "assistant", content: JSON.stringify(validOutput()) }
    }]
  };
}

function validOutput(): Record<string, unknown> {
  return {
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
  };
}

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
