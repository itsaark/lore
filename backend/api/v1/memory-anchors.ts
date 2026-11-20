import { acquireProcessingLease } from "../../src/auth/processing-lease.js";
import { loadFireworksRuntimeConfig } from "../../src/config.js";
import { API_SCHEMA_VERSION } from "../../src/contracts/common.js";
import { MemoryAnchorRequestSchema } from "../../src/contracts/memory-anchor.js";
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

const MAX_MEMORY_ANCHOR_BODY_BYTES = 200_000;
const MEMORY_ANCHOR_LEASE_TTL_SECONDS = 60;

export type MemoryAnchorHandlerDependencies = {
  environment?: NodeJS.ProcessEnv;
  fetch?: typeof globalThis.fetch;
  auth?: Omit<ProcessingAuthorizationDependencies, "environment">;
};

export async function handleMemoryAnchor(
  request: Request,
  dependencies: MemoryAnchorHandlerDependencies = {}
): Promise<Response> {
  const id = requestId(request);
  const startedAt = performance.now();
  try {
    requireMethod(request, "POST");
    const authorization = await requireProcessingAuthorization(request, {
      ...(dependencies.environment ? { environment: dependencies.environment } : {}),
      ...dependencies.auth
    });
    requireContentLengthBelow(request, MAX_MEMORY_ANCHOR_BODY_BYTES);
    const mediaType = request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase();
    if (mediaType !== "application/json") {
      throw new LoreApiError("invalid_request", 415, false);
    }

    const rawBody = await parseJsonBody(request);
    const parsed = MemoryAnchorRequestSchema.safeParse(rawBody);
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
    if (idempotencyKey !== `memory-anchor:${jobId}`) {
      throw new LoreApiError("invalid_request", 400, false);
    }

    const config = loadFireworksRuntimeConfig(dependencies.environment);
    const lease = await acquireProcessingLease({
      authorization,
      task: "memory_anchor",
      taskId: jobId,
      idempotencyKey,
      ttlSeconds: MEMORY_ANCHOR_LEASE_TTL_SECONDS,
      ...(dependencies.auth?.now ? { now: dependencies.auth.now } : {})
    });

    try {
      const client = new FireworksClient({
        config,
        ...(dependencies.fetch ? { fetch: dependencies.fetch } : {})
      });
      const response = await client.generateMemoryAnchor(id, parsed.data, processingSignal(request));
      writeSafeLog({
        route: "memory_anchor",
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
      route: "memory_anchor",
      status: apiError.status,
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
    if (bytes.byteLength > MAX_MEMORY_ANCHOR_BODY_BYTES) {
      throw new LoreApiError("payload_too_large", 413, false, "The processing request is too large.");
    }
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch (error) {
    if (error instanceof LoreApiError) throw error;
    throw new LoreApiError("invalid_request", 400, false);
  }
}

export default { fetch: handleMemoryAnchor };
