import { describe, expect, it } from "vitest";
import { DailyEntryGenerationRequestSchema, DailyEntryLabRequestSchema } from "../src/contracts/daily-entry.js";
import { TranscriptionMetadataSchema } from "../src/contracts/transcription.js";

const retentionPolicy = {
  mode: "request_ephemeral",
  maximum_retention_seconds: 0
} as const;

describe("wire contracts", () => {
  it("accepts bounded multipart transcription metadata", () => {
    const result = TranscriptionMetadataSchema.parse({
      schema_version: "1.0",
      job_id: "9f170d1f-8e71-4a12-a861-2ca5f9f52ed2",
      idempotency_key: "transcription:note-1:revision-1:chunk-0",
      chunk_id: "chunk-0",
      chunk_index: "0",
      chunk_count: "1",
      start_milliseconds: "0",
      duration_milliseconds: "12000",
      language_code: "en-US",
      vocabulary_hints: ["Hyderabad"],
      retention_policy: retentionPolicy
    });

    expect(result.chunk_index).toBe(0);
    expect(result.retention_policy.maximum_retention_seconds).toBe(0);
  });

  it("rejects an out-of-range chunk index", () => {
    const result = TranscriptionMetadataSchema.safeParse({
      schema_version: "1.0",
      job_id: "9f170d1f-8e71-4a12-a861-2ca5f9f52ed2",
      idempotency_key: "transcription:note-1:revision-1:chunk-1",
      chunk_id: "chunk-1",
      chunk_index: 1,
      chunk_count: 1,
      start_milliseconds: 0,
      duration_milliseconds: 12000,
      language_code: null,
      vocabulary_hints: [],
      retention_policy: retentionPolicy
    });

    expect(result.success).toBe(false);
  });

  it("accepts the grounded daily-entry request", () => {
    const result = DailyEntryGenerationRequestSchema.parse(dailyEntryRequest());

    expect(result.source_segments).toHaveLength(1);
    expect(result).not.toHaveProperty("remembered_time");
  });

  it("accepts remembered time with inclusive dates in daily-entry and Lab requests", () => {
    const rememberedTime = { precision: "week", start_date: "2026-07-16", end_date: "2026-07-16" };
    const request = { ...dailyEntryRequest(), remembered_time: rememberedTime };

    expect(DailyEntryGenerationRequestSchema.parse(request).remembered_time).toEqual(rememberedTime);
    expect(DailyEntryLabRequestSchema.parse({ ...request, lab_model: "glm-5p3" }).remembered_time).toEqual(rememberedTime);
  });

  it.each([
    ["2003-11-16", "2003-11-15", "end_date"],
    ["2026-07-17", "2026-07-23", "start_date"]
  ])("rejects invalid remembered range %s through %s in daily-entry and Lab requests", (startDate, endDate, invalidField) => {
    const request = {
      ...dailyEntryRequest(),
      remembered_time: { precision: "week", start_date: startDate, end_date: endDate }
    };

    for (const result of [
      DailyEntryGenerationRequestSchema.safeParse(request),
      DailyEntryLabRequestSchema.safeParse({ ...request, lab_model: "glm-5p3" })
    ]) {
      expect(result.error?.issues).toMatchObject([{ path: ["remembered_time", invalidField] }]);
    }
  });

  it("rejects client-supplied labels in remembered time", () => {
    const result = DailyEntryGenerationRequestSchema.safeParse({
      ...dailyEntryRequest(),
      remembered_time: { precision: "year", start_date: "2003-01-01", end_date: "2003-12-31", label: "School days" }
    });

    expect(result.error?.issues).toMatchObject([{ code: "unrecognized_keys", path: ["remembered_time"] }]);
  });

  it("normalizes omitted nullable transcript metadata from Swift", () => {
    const input = dailyEntryRequest();
    const segment = input.source_segments[0];
    if (!segment) throw new Error("fixture must include one segment");
    delete (segment as Record<string, unknown>).confidence;
    delete (segment as Record<string, unknown>).speaker_label;

    const parsed = DailyEntryGenerationRequestSchema.parse(input);

    expect(parsed.source_segments[0]).toMatchObject({
      confidence: null,
      speaker_label: null
    });
  });
});

function dailyEntryRequest() {
  return {
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
      end_milliseconds: 8200,
      text: "Synthetic journal fixture.",
      confidence: null,
      speaker_label: null
    }],
    accepted_prior_facts: [],
    retention_policy: retentionPolicy
  };
}
