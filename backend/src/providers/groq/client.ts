import type { GroqRuntimeConfig } from "../../config.js";
import {
  API_SCHEMA_VERSION,
  RETENTION_POLICY_VERSION,
  type ProcessingProvenance
} from "../../contracts/common.js";
import {
  RemoteTranscriptionResponseSchema,
  type RemoteTranscriptionResponse,
  type TranscriptionMetadata
} from "../../contracts/transcription.js";
import { LoreApiError } from "../../http/errors.js";
import { groqError } from "./errors.js";
import { GroqTranscriptionSchema } from "./provider-schemas.js";

const MAX_VOCABULARY_PROMPT_CHARACTERS = 200;

export type GroqClientOptions = {
  config: GroqRuntimeConfig;
  fetch?: typeof globalThis.fetch;
  now?: () => Date;
};

export type GroqAudioInput = {
  bytes: Blob;
  filename: string;
  mimeType: string;
};

export class GroqClient {
  private readonly fetchImpl: typeof globalThis.fetch;
  private readonly now: () => Date;

  constructor(private readonly options: GroqClientOptions) {
    this.fetchImpl = options.fetch ?? globalThis.fetch;
    this.now = options.now ?? (() => new Date());
  }

  async transcribe(
    requestId: string,
    metadata: TranscriptionMetadata,
    audio: GroqAudioInput,
    signal?: AbortSignal
  ): Promise<RemoteTranscriptionResponse> {
    const startedAt = performance.now();
    const form = new FormData();
    form.append("file", audio.bytes, audio.filename);
    form.append("model", this.options.config.transcriptionModel);
    form.append("response_format", "verbose_json");
    form.append("temperature", "0");
    form.append("timestamp_granularities[]", "segment");

    const language = iso639Language(metadata.language_code);
    if (language) form.append("language", language);

    const vocabularyPrompt = makeVocabularyPrompt(metadata.vocabulary_hints);
    if (vocabularyPrompt) form.append("prompt", vocabularyPrompt);

    const response = await this.fetchImpl(`${this.options.config.baseUrl}/audio/transcriptions`, {
      method: "POST",
      headers: { Authorization: `Bearer ${this.options.config.apiKey}` },
      body: form,
      signal: signal ?? null
    });
    if (!response.ok) throw groqError(response);

    const providerResult = GroqTranscriptionSchema.safeParse(await safeJson(response));
    if (!providerResult.success) {
      throw new LoreApiError("invalid_provider_response", 502, true);
    }

    const transcript = providerResult.data.text.trim();
    if (!transcript) throw new LoreApiError("empty_transcript", 422, false);

    const segments = (providerResult.data.segments ?? []).flatMap((segment, index) => {
      const text = segment.text.trim();
      if (!text) return [];
      return [{
        id: `${metadata.chunk_id}:segment-${segment.id ?? index}`,
        chunk_id: metadata.chunk_id,
        start_milliseconds: metadata.start_milliseconds + Math.round(segment.start * 1_000),
        end_milliseconds: metadata.start_milliseconds + Math.round(segment.end * 1_000),
        text,
        confidence: null,
        speaker_label: null
      }];
    });

    const effectiveSegments = segments.length > 0 ? segments : [{
      id: `${metadata.chunk_id}:segment-0`,
      chunk_id: metadata.chunk_id,
      start_milliseconds: metadata.start_milliseconds,
      end_milliseconds: metadata.start_milliseconds + metadata.duration_milliseconds,
      text: transcript,
      confidence: null,
      speaker_label: null
    }];

    return RemoteTranscriptionResponseSchema.parse({
      schema_version: API_SCHEMA_VERSION,
      job_id: metadata.job_id,
      request_id: requestId,
      chunk: {
        id: metadata.chunk_id,
        index: metadata.chunk_index,
        count: metadata.chunk_count,
        start_milliseconds: metadata.start_milliseconds,
        duration_milliseconds: metadata.duration_milliseconds
      },
      transcript,
      language_code: providerResult.data.language ?? language,
      segments: effectiveSegments,
      provenance: this.provenance(providerResult.data.x_groq?.id ?? response.headers.get("x-request-id"), startedAt)
    });
  }

  private provenance(providerRequestId: string | null, startedAt: number): ProcessingProvenance {
    const timestamp = this.now().toISOString();
    return {
      provider_id: "groq",
      model_alias: "transcription-fallback-v1",
      model_id: this.options.config.transcriptionModel,
      model_policy_version: this.options.config.policyVersion,
      provider_request_id: providerRequestId,
      processed_at: timestamp,
      processing_duration_milliseconds: Math.max(0, Math.round(performance.now() - startedAt)),
      retention_attestation: {
        mode: "request_ephemeral",
        maximum_retention_seconds: 0,
        policy_version: RETENTION_POLICY_VERSION,
        attested_at: timestamp
      }
    };
  }
}

function iso639Language(languageCode: string | null): string | null {
  if (!languageCode) return null;
  const code = languageCode.split(/[-_]/, 1)[0]?.toLowerCase();
  return code && /^[a-z]{2}$/.test(code) ? code : null;
}

function makeVocabularyPrompt(hints: string[]): string | null {
  const joined = hints.map((hint) => hint.trim()).filter(Boolean).join(", ");
  const bounded = Array.from(joined).slice(0, MAX_VOCABULARY_PROMPT_CHARACTERS).join("");
  return bounded ? `Preferred spellings: ${bounded}` : null;
}

async function safeJson(response: Response): Promise<unknown> {
  try {
    return await response.json();
  } catch {
    throw new LoreApiError("invalid_provider_response", 502, true);
  }
}
