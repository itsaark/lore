import { loadFireworksRuntimeConfig } from "../../src/config.js";
import { DailyEntryGenerationRequestSchema } from "../../src/contracts/daily-entry.js";
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
import { FireworksClient } from "../../src/providers/fireworks/client.js";

const MAX_DAILY_ENTRY_BODY_BYTES = 1_000_000;

export type DailyEntryHandlerDependencies = {
  environment?: NodeJS.ProcessEnv;
  fetch?: typeof globalThis.fetch;
};

export async function handleDailyEntry(
  request: Request,
  dependencies: DailyEntryHandlerDependencies = {}
): Promise<Response> {
  const id = requestId(request);
  const startedAt = performance.now();
  try {
    requireMethod(request, "POST");
    requirePreviewAuthorization(request, dependencies.environment);
    requireContentLengthBelow(request, MAX_DAILY_ENTRY_BODY_BYTES);
    if (!request.headers.get("content-type")?.toLowerCase().startsWith("application/json")) {
      throw new LoreApiError("invalid_request", 415, false);
    }

    const rawBody = await parseJsonBody(request);
    const parsed = DailyEntryGenerationRequestSchema.safeParse(rawBody);
    if (!parsed.success) {
      const schemaVersion = isRecord(rawBody) ? rawBody.schema_version : undefined;
      throw new LoreApiError(
        schemaVersion !== "1.0" ? "unsupported_schema" : "invalid_request",
        400,
        false
      );
    }

    writeSafeLog({ event: "provider_started", request_id: id, route: "daily_entry", provider: "fireworks", model_alias: "daily-entry-v1" });
    const client = new FireworksClient({
      config: loadFireworksRuntimeConfig(dependencies.environment),
      ...(dependencies.fetch ? { fetch: dependencies.fetch } : {})
    });
    const response = await client.generateDailyEntry(id, parsed.data, processingSignal(request));
    writeSafeLog({
      event: "request_completed",
      request_id: id,
      route: "daily_entry",
      status: 200,
      duration_ms: Math.round(performance.now() - startedAt)
    });
    return jsonSuccess(response, id);
  } catch (error) {
    const apiError = error instanceof LoreApiError ? error : new LoreApiError("internal_error", 500, true);
    writeSafeLog({
      event: "request_failed",
      request_id: id,
      route: "daily_entry",
      status: apiError.status,
      error_code: apiError.code,
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
    return await request.json();
  } catch {
    throw new LoreApiError("invalid_request", 400, false);
  }
}

export default { fetch: handleDailyEntry };
