import { loadFireworksRuntimeConfig } from "../../../src/config.js";
import { acquireProcessingLease } from "../../../src/auth/processing-lease.js";
import { DailyEntryLabRequestSchema } from "../../../src/contracts/daily-entry.js";
import { requireProcessingAuthorization, type ProcessingAuthorizationDependencies } from "../../../src/http/auth.js";
import { errorResponse, LoreApiError } from "../../../src/http/errors.js";
import { writeSafeLog } from "../../../src/http/logger.js";
import {
  jsonSuccess,
  processingSignal,
  requestId,
  requireContentLengthBelow,
  requireIdempotencyKey,
  requireMethod
} from "../../../src/http/request.js";
import { FireworksClient } from "../../../src/providers/fireworks/client.js";

const MAX_LAB_BODY_BYTES = 1_000_000;

export type LabDailyEntryHandlerDependencies = {
  environment?: NodeJS.ProcessEnv;
  fetch?: typeof globalThis.fetch;
  auth?: Omit<ProcessingAuthorizationDependencies, "environment">;
};

/**
 * DEBUG Model Lab: compares allowlisted writers and prompt versions on the
 * founder's own notes. Only sessions backed by a development App Attest key
 * (Xcode-signed device builds) are admitted, so TestFlight and App Store
 * installs can never reach it. Same request-ephemeral handling as production:
 * nothing is persisted and logs carry no content.
 */
export async function handleLabDailyEntry(
  request: Request,
  dependencies: LabDailyEntryHandlerDependencies = {}
): Promise<Response> {
  const id = requestId(request);
  const startedAt = performance.now();
  try {
    requireMethod(request, "POST");
    const authorization = await requireProcessingAuthorization(request, {
      ...(dependencies.environment ? { environment: dependencies.environment } : {}),
      ...dependencies.auth
    });
    if (authorization.attestationEnvironment !== "development") {
      throw new LoreApiError("unauthorized", 403, false);
    }
    requireContentLengthBelow(request, MAX_LAB_BODY_BYTES);
    if (!request.headers.get("content-type")?.toLowerCase().startsWith("application/json")) {
      throw new LoreApiError("invalid_request", 415, false);
    }

    let rawBody: unknown;
    try {
      rawBody = await request.json();
    } catch {
      throw new LoreApiError("invalid_request", 400, false);
    }
    const parsed = DailyEntryLabRequestSchema.safeParse(rawBody);
    if (!parsed.success) throw new LoreApiError("invalid_request", 400, false);

    const idempotencyKey = requireIdempotencyKey(request);
    if (idempotencyKey !== `lab-daily-entry:${parsed.data.job_id.toLowerCase()}`) {
      throw new LoreApiError("invalid_request", 400, false);
    }

    const providerConfig = loadFireworksRuntimeConfig(dependencies.environment);
    const lease = await acquireProcessingLease({
      authorization,
      task: "daily_entry",
      taskId: `lab-${parsed.data.job_id.toLowerCase()}`,
      idempotencyKey,
      ...(dependencies.auth?.now ? { now: dependencies.auth.now } : {})
    });

    try {
      writeSafeLog({
        event: "provider_started",
        request_id: id,
        route: "lab_daily_entry",
        provider: "fireworks",
        model_alias: "daily-entry-lab"
      });
      const client = new FireworksClient({
        config: providerConfig,
        ...(dependencies.fetch ? { fetch: dependencies.fetch } : {})
      });
      const response = await client.generateLabDailyEntry(id, parsed.data, processingSignal(request));
      writeSafeLog({
        event: "request_completed",
        request_id: id,
        route: "lab_daily_entry",
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
      route: "lab_daily_entry",
      status: apiError.status,
      error_code: apiError.diagnosticCode ?? apiError.code,
      duration_ms: Math.round(performance.now() - startedAt)
    });
    return errorResponse(apiError, id);
  }
}

export default { fetch: handleLabDailyEntry };
