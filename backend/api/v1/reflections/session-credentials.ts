import { loadSonioxRuntimeConfig } from "../../../src/config.js";
import {
  API_SCHEMA_VERSION
} from "../../../src/contracts/common.js";
import {
  REFLECTION_MAX_SESSION_DURATION_SECONDS,
  ReflectionSessionCredentialsRequestSchema,
  ReflectionSessionCredentialsResponseSchema
} from "../../../src/contracts/reflection.js";
import {
  requireProcessingAuthorization,
  type ProcessingAuthorizationDependencies
} from "../../../src/http/auth.js";
import { errorResponse, LoreApiError } from "../../../src/http/errors.js";
import { writeSafeLog } from "../../../src/http/logger.js";
import {
  jsonSuccess,
  processingSignal,
  requestId,
  requireContentLengthBelow,
  requireMethod
} from "../../../src/http/request.js";
import { SonioxClient } from "../../../src/providers/soniox/client.js";

const MAX_BODY_BYTES = 8_000;

export type ReflectionCredentialsHandlerDependencies = {
  environment?: NodeJS.ProcessEnv;
  fetch?: typeof globalThis.fetch;
  auth?: Omit<ProcessingAuthorizationDependencies, "environment">;
};

export async function handleReflectionSessionCredentials(
  request: Request,
  dependencies: ReflectionCredentialsHandlerDependencies = {}
): Promise<Response> {
  const id = requestId(request);
  const startedAt = performance.now();
  try {
    requireMethod(request, "POST");
    await requireProcessingAuthorization(request, {
      ...(dependencies.environment ? { environment: dependencies.environment } : {}),
      ...dependencies.auth
    });
    requireContentLengthBelow(request, MAX_BODY_BYTES);
    requireJsonContentType(request);
    const body = ReflectionSessionCredentialsRequestSchema.safeParse(await parseJsonBody(request));
    if (!body.success) throw new LoreApiError("invalid_request", 400, false);

    const config = loadSonioxRuntimeConfig(dependencies.environment);
    const client = new SonioxClient({
      config,
      ...(dependencies.fetch ? { fetch: dependencies.fetch } : {})
    });
    const signal = processingSignal(request, 15_000);
    const clientReferenceId = `reflection:${body.data.session_id}`;

    writeSafeLog({
      event: "provider_started",
      request_id: id,
      route: "reflection_credentials",
      provider: "soniox",
      model_alias: "reflection-stt-v1"
    });
    const [stt, tts] = await Promise.all([
      client.createTemporaryKey("transcribe_websocket", clientReferenceId, signal),
      client.createTemporaryKey("tts_rt", clientReferenceId, signal)
    ]);

    const response = ReflectionSessionCredentialsResponseSchema.parse({
      schema_version: API_SCHEMA_VERSION,
      session_id: body.data.session_id,
      stt: {
        temporary_api_key: stt.apiKey,
        expires_at: stt.expiresAt,
        websocket_url: config.sttWebSocketUrl,
        model_alias: config.sttModelAlias,
        audio_format: "pcm_s16le",
        sample_rate: 16_000,
        num_channels: 1
      },
      tts: {
        temporary_api_key: tts.apiKey,
        expires_at: tts.expiresAt,
        websocket_url: config.ttsWebSocketUrl,
        model_alias: config.ttsModelAlias,
        voice: config.ttsVoice,
        audio_format: "pcm_s16le",
        sample_rate: 24_000
      },
      maximum_session_duration_seconds: REFLECTION_MAX_SESSION_DURATION_SECONDS
    });
    writeSafeLog({
      event: "request_completed",
      request_id: id,
      route: "reflection_credentials",
      status: 200,
      duration_ms: Math.round(performance.now() - startedAt)
    });
    return jsonSuccess(response, id);
  } catch (error) {
    const apiError = error instanceof LoreApiError
      ? error
      : new LoreApiError("internal_error", 500, true);
    writeSafeLog({
      event: "request_failed",
      request_id: id,
      route: "reflection_credentials",
      status: apiError.status,
      error_code: apiError.diagnosticCode ?? apiError.code,
      duration_ms: Math.round(performance.now() - startedAt)
    });
    return errorResponse(apiError, id);
  }
}

function requireJsonContentType(request: Request): void {
  if (!request.headers.get("content-type")?.toLowerCase().startsWith("application/json")) {
    throw new LoreApiError("invalid_request", 415, false);
  }
}

async function parseJsonBody(request: Request): Promise<unknown> {
  try {
    return await request.json();
  } catch {
    throw new LoreApiError("invalid_request", 400, false);
  }
}

export default { fetch: handleReflectionSessionCredentials };
