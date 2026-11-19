import { describe, expect, it, vi } from "vitest";
import type { FireworksRuntimeConfig } from "../src/config.js";
import { DAILY_ENTRY_PROMPT_VERSIONS, type DailyEntryGenerationRequest } from "../src/contracts/daily-entry.js";
import type { StoryChapterGenerationRequest } from "../src/contracts/story-chapter.js";
import { LoreApiError } from "../src/http/errors.js";
import { FireworksClient } from "../src/providers/fireworks/client.js";
import {
  FireworksDailyEntryJsonSchema,
  FireworksStoryChapterJsonSchema
} from "../src/providers/fireworks/provider-schemas.js";

const config: FireworksRuntimeConfig = {
  apiKey: "test-key-never-use-live",
  policyVersion: "test-policy-v1",
  baseUrl: "https://api.fireworks.test/inference/v1",
  dailyEntryModel: "accounts/fireworks/models/gpt-oss-120b",
  dailyEntryFallbackModel: "accounts/fireworks/models/fallback-writer",
  reflectionGuideModel: "accounts/fireworks/models/gpt-oss-120b"
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

describe("FireworksClient writer fallback", () => {
  const v2Request: DailyEntryGenerationRequest = { ...dailyRequest, prompt_version: "grounded-journal-v2" };

  it("writes with the primary model and the v2 biographer prompt", async () => {
    const fetchMock = vi.fn<typeof fetch>(async (_input, init) => {
      const body = JSON.parse(String(init?.body));
      expect(body.model).toBe("accounts/fireworks/models/gpt-oss-120b");
      expect(body.reasoning_effort).toBe("low");
      expect(body.messages[0].content).toContain("private biographer");
      return Response.json(validCompletion());
    });
    const client = new FireworksClient({ config, fetch: fetchMock });

    const response = await client.generateDailyEntry("req_v2", v2Request);

    expect(response.prompt_version).toBe("grounded-journal-v2");
    expect(fetchMock).toHaveBeenCalledOnce();
  });

  it("falls back to the second writer, same prompt, when the primary is unavailable", async () => {
    const models: string[] = [];
    const fetchMock = vi.fn<typeof fetch>(async (_input, init) => {
      const body = JSON.parse(String(init?.body));
      models.push(body.model);
      expect(body.messages[0].content).toContain("private biographer");
      if (models.length === 1) return new Response("model not found", { status: 404 });
      return Response.json({ ...validCompletion(), model: "accounts/fireworks/models/fallback-writer" });
    });
    const client = new FireworksClient({ config, fetch: fetchMock });

    const response = await client.generateDailyEntry("req_fallback", v2Request);

    expect(models).toEqual([
      "accounts/fireworks/models/gpt-oss-120b",
      "accounts/fireworks/models/fallback-writer"
    ]);
    expect(response.provenance.model_id).toBe("accounts/fireworks/models/fallback-writer");
  });

  it("does not fall back on a rate limit", async () => {
    const fetchMock = vi.fn<typeof fetch>(async () => new Response("slow down", { status: 429 }));
    const client = new FireworksClient({ config, fetch: fetchMock });

    await expect(client.generateDailyEntry("req_rate", v2Request)).rejects.toMatchObject({ code: "provider_rate_limited" });
    expect(fetchMock).toHaveBeenCalledOnce();
  });

  it("keeps answering v1 requests from older builds with the v1 prompt", async () => {
    const fetchMock = vi.fn<typeof fetch>(async (_input, init) => {
      const body = JSON.parse(String(init?.body));
      expect(body.messages[0].content).toContain("private biographical journal writer");
      return Response.json(validCompletion());
    });
    const client = new FireworksClient({ config, fetch: fetchMock });

    const response = await client.generateDailyEntry("req_v1", dailyRequest);

    expect(response.prompt_version).toBe("grounded-journal-v1");
  });
});

describe("FireworksClient daily-entry prompts", () => {
  it.each(DAILY_ENTRY_PROMPT_VERSIONS)("keeps the %s prompts byte-identical without remembered_time", async (promptVersion) => {
    const fetchMock = vi.fn<typeof fetch>(async () => Response.json(validCompletion()));
    const client = new FireworksClient({ config, fetch: fetchMock });

    await client.generateDailyEntry("req_day_prompt", { ...dailyRequest, prompt_version: promptVersion });

    expect(fetchMock).toHaveBeenCalledOnce();
    const { messages } = JSON.parse(String(fetchMock.mock.calls[0]?.[1]?.body));
    // Encode line endings and whitespace inside each message as part of the snapshot.
    expect(JSON.stringify(messages, null, 2)).toMatchSnapshot();
  });

  describe.each(DAILY_ENTRY_PROMPT_VERSIONS)("%s with remembered_time", (promptVersion) => {
    it.each([
      ["week", "2003-11-16", "2003-11-22", "the week of 16 November 2003"],
      ["month", "2003-11-01", "2003-11-30", "November 2003"],
      ["year", "2003-01-01", "2003-12-31", "2003"],
      ["span", "2008-01-01", "2011-12-31", "between 2008 and 2011"],
      ["span", "2008-02-01", "2008-04-30", "2008"]
    ] as const)("formats %s (%s through %s) as %s", async (precision, startDate, endDate, phrase) => {
      const fetchMock = vi.fn<typeof fetch>(async () => Response.json(validCompletion()));
      const client = new FireworksClient({ config, fetch: fetchMock });

      await client.generateDailyEntry("req_memory_prompt", {
        ...dailyRequest,
        prompt_version: promptVersion,
        remembered_time: { precision, start_date: startDate, end_date: endDate },
        render_configuration: { ...dailyRequest.render_configuration, tense: "present" }
      });

      expect(fetchMock).toHaveBeenCalledOnce();
      const { messages } = JSON.parse(String(fetchMock.mock.calls[0]?.[1]?.body));
      const prompt = messages[1].content;
      expect(prompt).toContain(`The notes were spoken on 2026-07-16. The period they recall is ${phrase}.`);
      expect(prompt).toContain("in the past tense");
      expect(prompt).toContain("Do not invent a specific day, month, or season more precise than the remembered period.");
      expect(prompt).toContain("Leave the day of recording out of the entry. Give the memory a title drawn from the events recalled.");
      expect(prompt).toContain('"tense":"past"');
      expect(prompt).toContain("Every sentence cites the segment IDs it draws on");
      expect(prompt).not.toContain("ONE coherent entry for the whole day");
    });
  });
});

describe("FireworksClient multi-note days", () => {
  const segment = (id: string, text: string) => ({
    id,
    chunk_id: `chunk-${id}`,
    start_milliseconds: 0,
    end_milliseconds: 5_000,
    text,
    confidence: null,
    speaker_label: null
  });
  const output = () => {
    const base = validOutput() as { entry: { title_source_references: string[]; sentences: Array<Record<string, unknown>> } };
    base.entry.title_source_references = ["s1", "s2"];
    base.entry.sentences = [
      { text: "Maya started the day at the market.", source_references: ["s1"], fact_references: [], preserves_uncertainty: false },
      { text: "By evening she was back home.", source_references: ["s2"], fact_references: [], preserves_uncertainty: false }
    ];
    return base;
  };

  it("asks for one coherent story and passes each note's recording time", async () => {
    const fetchMock = vi.fn<typeof fetch>(async (_input, init) => {
      const body = JSON.parse(String(init?.body));
      expect(body.messages[1].content).toContain("ONE coherent entry for the whole day");
      expect(body.messages[1].content).toContain("2026-07-16T08:15:00-07:00");
      return Response.json({
        id: "c", model: "m",
        choices: [{ index: 0, finish_reason: "stop", message: { role: "assistant", content: JSON.stringify(output()) } }]
      });
    });
    const client = new FireworksClient({ config, fetch: fetchMock });
    await client.generateDailyEntry("req_multi", {
      ...dailyRequest,
      source_segments: [
        { ...segment("s1", "I went to the market."), recorded_at: "2026-07-16T08:15:00-07:00" },
        { ...segment("s2", "Then I came home."), recorded_at: "2026-07-16T18:40:00-07:00" }
      ]
    });
    expect(fetchMock).toHaveBeenCalledOnce();
  });

  it("uses the same day-story instructions for a single note", async () => {
    const fetchMock = vi.fn<typeof fetch>(async (_input, init) => {
      const body = JSON.parse(String(init?.body));
      expect(body.messages[1].content).toContain("ONE coherent entry for the whole day");
      return Response.json(validCompletion());
    });
    const client = new FireworksClient({ config, fetch: fetchMock });
    await client.generateDailyEntry("req_single", dailyRequest);
    expect(fetchMock).toHaveBeenCalledOnce();
  });
});

describe("FireworksClient", () => {
  it("builds a strict provider schema with required fields on every object", () => {
    assertStrictObjects(FireworksDailyEntryJsonSchema);
    assertStrictObjects(FireworksStoryChapterJsonSchema);
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
      .rejects.toMatchObject({
        code: "invalid_provider_response",
        retryable: true,
        diagnosticCode: "provider_source_reference_invalid"
      });
  });

  it("rejects a model response containing an unknown fact reference", async () => {
    const request: DailyEntryGenerationRequest = {
      ...dailyRequest,
      accepted_prior_facts: [{
        id: "fact-1",
        statement: "Maya keeps a small garden.",
        status: "accepted",
        source_references: ["s1"]
      }]
    };
    const completion = validCompletion();
    completion.choices[0]!.message.content = JSON.stringify({
      ...validOutput(),
      entry: {
        title: "A return home",
        title_source_references: ["s1"],
        perspective: "third_person",
        sentences: [{
          text: "Maya returned home.",
          source_references: ["s1"],
          fact_references: ["made-up-fact"],
          preserves_uncertainty: false
        }]
      }
    });
    const client = new FireworksClient({
      config,
      fetch: vi.fn<typeof fetch>(async () => Response.json(completion))
    });

    await expect(client.generateDailyEntry("req_fact_ref", request))
      .rejects.toMatchObject({
        code: "invalid_provider_response",
        retryable: true,
        diagnosticCode: "provider_fact_reference_invalid"
      });
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

describe("FireworksClient story chapters", () => {
  const chapterRequest: StoryChapterGenerationRequest = {
    schema_version: "1.0",
    prompt_version: "story-chapter-v1",
    job_id: "5f3acbd5-676e-4cb3-83a4-150b09c735a9",
    chapter_key: "2026-07",
    language_code: "en-US",
    subject: { display_name: "Maya", pronouns: [] },
    render_configuration: {
      perspective: "third_person",
      tense: "past",
      tone: "warm_restrained",
      target_words: 300
    },
    source_days: [
      { id: "2026-07-01", day_key: "2026-07-01", title: "The harbor", prose: "Maya walked the harbor at dawn." },
      { id: "2026-07-02", day_key: "2026-07-02", title: "The market", prose: "She spent the morning at the market." }
    ],
    retention_policy: { mode: "request_ephemeral", maximum_retention_seconds: 0 }
  };

  it("sends a chapter-specific schema whose fact arrays allow no items", async () => {
    const fetchMock = vi.fn<typeof fetch>(async (_input, init) => {
      const body = JSON.parse(String(init?.body));
      expect(body.response_format).toEqual({
        type: "json_schema",
        json_schema: {
          name: "lore_story_chapter",
          schema: FireworksStoryChapterJsonSchema
        }
      });
      const factArrayLimits = collectFactArrayLimits(body.response_format.json_schema.schema);
      expect(factArrayLimits).toHaveLength(2);
      expect(factArrayLimits.every((limit) => limit === 0)).toBe(true);
      return Response.json(chapterCompletion());
    });
    const client = new FireworksClient({ config, fetch: fetchMock });

    await client.generateStoryChapter("req_chapter_schema", chapterRequest);

    expect(fetchMock).toHaveBeenCalledOnce();
  });

  it("accepts a chapter whose sentences cite invented fact ids, clearing them", async () => {
    const client = new FireworksClient({
      config,
      fetch: vi.fn<typeof fetch>(async () => Response.json(chapterCompletion({ factReferences: ["made-up"] })))
    });

    const response = await client.generateStoryChapter("req_chapter_facts", chapterRequest);

    expect(response.entry.sentences[0]!.fact_references).toEqual([]);
  });

  it("still rejects a chapter that cites an unknown source day id", async () => {
    const client = new FireworksClient({
      config,
      fetch: vi.fn<typeof fetch>(async () => Response.json(chapterCompletion({ sourceReferences: ["invented-day"] })))
    });

    await expect(client.generateStoryChapter("req_chapter_source", chapterRequest))
      .rejects.toMatchObject({
        code: "invalid_provider_response",
        retryable: true,
        diagnosticCode: "provider_source_reference_invalid"
      });
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

function chapterCompletion(options: { factReferences?: string[]; sourceReferences?: string[] } = {}) {
  return {
    id: "chatcmpl_chapter",
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
            sentences: [{
              text: "Maya began July at the harbor.",
              source_references: options.sourceReferences ?? ["2026-07-01"],
              fact_references: options.factReferences ?? [],
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
  };
}

/** Collects the maxItems of every fact_references / related_fact_ids array in a JSON schema. */
function collectFactArrayLimits(value: unknown, limits: number[] = []): number[] {
  if (Array.isArray(value)) {
    value.forEach((item) => collectFactArrayLimits(item, limits));
  } else if (typeof value === "object" && value !== null) {
    for (const [key, property] of Object.entries(value)) {
      if ((key === "fact_references" || key === "related_fact_ids")
        && typeof property === "object" && property !== null) {
        limits.push((property as Record<string, unknown>).maxItems as number);
      } else {
        collectFactArrayLimits(property, limits);
      }
    }
  }
  return limits;
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
