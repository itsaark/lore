import { loadGroqRuntimeConfig } from "../../src/config.js";
import {
  MAX_AUDIO_CHUNK_BYTES,
  MAX_MULTIPART_BODY_BYTES,
  TranscriptionMetadataSchema
} from "../../src/contracts/transcription.js";
import { requirePreviewAuthorization } from "../../src/http/auth.js";
import { errorResponse, LoreApiError } from "../../src/http/errors.js";
import { writeSafeLog } from "../../src/http/logger.js";
import {
  jsonSuccess,
  processingSignal,
  requestId,
  requireContentLengthBelow,
  requireMethod
} from "../../src/http/request.js";
import { GroqClient } from "../../src/providers/groq/client.js";

const SUPPORTED_AUDIO_TYPES = new Set([
  "audio/flac",
  "audio/m4a",
  "audio/mp4",
  "audio/mpeg",
  "audio/ogg",
  "audio/wav",
  "audio/webm",
  "video/mp4"
]);

export type TranscriptionHandlerDependencies = {
  environment?: NodeJS.ProcessEnv;
  fetch?: typeof globalThis.fetch;
};

export async function handleTranscription(
  request: Request,
  dependencies: TranscriptionHandlerDependencies = {}
): Promise<Response> {
  const id = requestId(request);
  const startedAt = performance.now();
  try {
    requireMethod(request, "POST");
    requirePreviewAuthorization(request, dependencies.environment);
    requireContentLengthBelow(request, MAX_MULTIPART_BODY_BYTES);
    if (!request.headers.get("content-type")?.toLowerCase().startsWith("multipart/form-data")) {
      throw new LoreApiError("invalid_request", 415, false);
    }

    const form = await parseFormData(request);
    const audio = form.get("audio");
    if (!(audio instanceof File)) {
      throw new LoreApiError("invalid_request", 400, false);
    }
    if (audio.size <= 0 || audio.size > MAX_AUDIO_CHUNK_BYTES) {
      throw new LoreApiError("payload_too_large", 413, false);
    }
    if (!SUPPORTED_AUDIO_TYPES.has(audio.type.toLowerCase())) {
      throw new LoreApiError("unsupported_audio", 415, false);
    }

    const metadata = TranscriptionMetadataSchema.safeParse({
      schema_version: stringField(form, "schema_version"),
      job_id: stringField(form, "job_id"),
      idempotency_key: stringField(form, "idempotency_key"),
      chunk_id: stringField(form, "chunk_id"),
      chunk_index: stringField(form, "chunk_index"),
      chunk_count: stringField(form, "chunk_count"),
      start_milliseconds: stringField(form, "start_milliseconds"),
      duration_milliseconds: stringField(form, "duration_milliseconds"),
      language_code: nullableStringField(form, "language_code"),
      vocabulary_hints: jsonField(form, "vocabulary_hints"),
      retention_policy: jsonField(form, "retention_policy")
    });
    if (!metadata.success) {
      const schemaVersion = form.get("schema_version");
      throw new LoreApiError(
        schemaVersion !== "1.0" ? "unsupported_schema" : "invalid_request",
        400,
        false
      );
    }

    writeSafeLog({ event: "provider_started", request_id: id, route: "transcription", provider: "groq", model_alias: "transcription-fallback-v1" });
    const client = new GroqClient({
      config: loadGroqRuntimeConfig(dependencies.environment),
      ...(dependencies.fetch ? { fetch: dependencies.fetch } : {})
    });
    const response = await client.transcribe(
      id,
      metadata.data,
      { bytes: audio, filename: audio.name, mimeType: audio.type },
      processingSignal(request)
    );
    writeSafeLog({
      event: "request_completed",
      request_id: id,
      route: "transcription",
      status: 200,
      duration_ms: Math.round(performance.now() - startedAt)
    });
    return jsonSuccess(response, id);
  } catch (error) {
    const apiError = error instanceof LoreApiError ? error : new LoreApiError("internal_error", 500, true);
    writeSafeLog({
      event: "request_failed",
      request_id: id,
      route: "transcription",
      status: apiError.status,
      error_code: apiError.code,
      duration_ms: Math.round(performance.now() - startedAt)
    });
    return errorResponse(apiError, id);
  }
}

function stringField(form: FormData, name: string): string {
  const value = form.get(name);
  return typeof value === "string" ? value : "";
}

function nullableStringField(form: FormData, name: string): string | null {
  const value = stringField(form, name).trim();
  return value ? value : null;
}

function jsonField(form: FormData, name: string): unknown {
  const value = stringField(form, name);
  try {
    return JSON.parse(value);
  } catch {
    return undefined;
  }
}

async function parseFormData(request: Request): Promise<FormData> {
  try {
    return await request.formData();
  } catch {
    throw new LoreApiError("invalid_request", 400, false);
  }
}

export default { fetch: handleTranscription };
