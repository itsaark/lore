import { acquireProcessingLease } from "../../src/auth/processing-lease.js";
import { loadFireworksRuntimeConfig, loadOpenAIRuntimeConfig } from "../../src/config.js";
import { API_SCHEMA_VERSION } from "../../src/contracts/common.js";
import {
  DAY_ILLUSTRATION_PROMPT_VERSION,
  DAY_SCENE_MODEL_ALIAS,
  DayIllustrationGenerationRequestSchema,
  DayIllustrationGenerationResponseSchema
} from "../../src/contracts/day-illustration.js";
import { requireProcessingAuthorization, type ProcessingAuthorizationDependencies } from "../../src/http/auth.js";
import { errorResponse, LoreApiError } from "../../src/http/errors.js";
import { writeSafeLog } from "../../src/http/logger.js";
import {
  jsonSuccess,
  processingSignal,
  requestId,
  requireContentLengthBelow,
  requireIdempotencyKey,
  requireMethod
} from "../../src/http/request.js";
import { FireworksClient } from "../../src/providers/fireworks/client.js";
import { OpenAIImageClient } from "../../src/providers/openai/client.js";

const MAX_DAY_ILLUSTRATION_BODY_BYTES = 200_000;
const DAY_ILLUSTRATION_LEASE_TTL_SECONDS = 180;

export type DayIllustrationHandlerDependencies = {
  environment?: NodeJS.ProcessEnv;
  fetch?: typeof globalThis.fetch;
  auth?: Omit<ProcessingAuthorizationDependencies, "environment">;
};

export async function handleDayIllustration(
  request: Request,
  dependencies: DayIllustrationHandlerDependencies = {}
): Promise<Response> {
  const id = requestId(request);
  const startedAt = performance.now();
  try {
    requireMethod(request, "POST");
    const authorization = await requireProcessingAuthorization(request, {
      ...(dependencies.environment ? { environment: dependencies.environment } : {}),
      ...dependencies.auth
    });
    requireContentLengthBelow(request, MAX_DAY_ILLUSTRATION_BODY_BYTES);
    const mediaType = request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase();
    if (mediaType !== "application/json") {
      throw new LoreApiError("invalid_request", 415, false);
    }

    const rawBody = await parseJsonBody(request);
    const parsed = DayIllustrationGenerationRequestSchema.safeParse(rawBody);
    if (!parsed.success) {
      const schemaVersion = isRecord(rawBody) ? rawBody.schema_version : undefined;
      throw new LoreApiError(
        schemaVersion !== API_SCHEMA_VERSION ? "unsupported_schema" : "invalid_request",
        400,
        false
      );
    }

    const jobId = parsed.data.job_id.toLowerCase();
    const idempotencyKey = requireIdempotencyKey(request);
    if (idempotencyKey !== `day-illustration:${jobId}`) {
      throw new LoreApiError("invalid_request", 400, false);
    }

    const fireworksConfig = loadFireworksRuntimeConfig(dependencies.environment);
    const openAIConfig = loadOpenAIRuntimeConfig(dependencies.environment);
    const lease = await acquireProcessingLease({
      authorization,
      task: "day_illustration",
      taskId: jobId,
      idempotencyKey,
      ttlSeconds: DAY_ILLUSTRATION_LEASE_TTL_SECONDS,
      ...(dependencies.auth?.now ? { now: dependencies.auth.now } : {})
    });

    try {
      const signal = processingSignal(request, 140_000);
      const fireworks = new FireworksClient({
        config: fireworksConfig,
        ...(dependencies.fetch ? { fetch: dependencies.fetch } : {})
      });
      const openAI = new OpenAIImageClient({
        config: openAIConfig,
        ...(dependencies.fetch ? { fetch: dependencies.fetch } : {})
      });
      writeSafeLog({
        event: "provider_started", request_id: id, route: "day_illustration",
        provider: "fireworks", model_alias: DAY_SCENE_MODEL_ALIAS
      });
      const scene = await fireworks.generateDayScene(id, parsed.data, signal);
      writeSafeLog({
        event: "provider_started", request_id: id, route: "day_illustration",
        provider: "openai", model_alias: DAY_ILLUSTRATION_PROMPT_VERSION
      });
      const generation = await openAI.generate(scene.description, signal);
      const response = DayIllustrationGenerationResponseSchema.parse({
        schema_version: API_SCHEMA_VERSION,
        prompt_version: DAY_ILLUSTRATION_PROMPT_VERSION,
        job_id: parsed.data.job_id,
        request_id: id,
        image: generation.image,
        scene: { description: scene.description },
        scene_provenance: scene.provenance,
        provenance: generation.provenance
      });
      writeSafeLog({
        event: "request_completed",
        request_id: id,
        route: "day_illustration",
        status: 200,
        duration_ms: Math.round(performance.now() - startedAt)
      });
      return jsonSuccess(response, id);
    } finally {
      await lease.release().catch(() => false);
    }
  } catch (error) {
    const apiError = error instanceof LoreApiError ? error : new LoreApiError("internal_error", 500, true);
    writeSafeLog({
      event: "request_failed",
      request_id: id,
      route: "day_illustration",
      status: apiError.status,
      error_code: apiError.diagnosticCode ?? apiError.code,
      duration_ms: Math.round(performance.now() - startedAt)
    });
    return errorResponse(apiError, id);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function parseJsonBody(request: Request): Promise<unknown> {
  try {
    const bytes = await request.arrayBuffer();
    if (bytes.byteLength > MAX_DAY_ILLUSTRATION_BODY_BYTES) {
      throw new LoreApiError("payload_too_large", 413, false, "The processing request is too large.");
    }
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch (error) {
    if (error instanceof LoreApiError) throw error;
    throw new LoreApiError("invalid_request", 400, false);
  }
}

export default { fetch: handleDayIllustration };
