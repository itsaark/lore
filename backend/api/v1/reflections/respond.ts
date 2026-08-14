import { acquireProcessingLease } from "../../../src/auth/processing-lease.js";
import { loadFireworksRuntimeConfig } from "../../../src/config.js";
import { ReflectionGuideRequestSchema } from "../../../src/contracts/reflection.js";
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
  requireIdempotencyKey,
  requireMethod
} from "../../../src/http/request.js";
import { FireworksClient } from "../../../src/providers/fireworks/client.js";

const MAX_BODY_BYTES = 300_000;

export type ReflectionGuideHandlerDependencies = {
  environment?: NodeJS.ProcessEnv;
  fetch?: typeof globalThis.fetch;
  auth?: Omit<ProcessingAuthorizationDependencies, "environment">;
};

export async function handleReflectionGuide(
  request: Request,
  dependencies: ReflectionGuideHandlerDependencies = {}
): Promise<Response> {
  const id = requestId(request);
  const startedAt = performance.now();
  try {
    requireMethod(request, "POST");
    const authorization = await requireProcessingAuthorization(request, {
      ...(dependencies.environment ? { environment: dependencies.environment } : {}),
      ...dependencies.auth
    });
    requireContentLengthBelow(request, MAX_BODY_BYTES);
    requireJsonContentType(request);
    const body = ReflectionGuideRequestSchema.safeParse(await parseJsonBody(request));
    if (!body.success) throw new LoreApiError("invalid_request", 400, false);

    const lastTurnId = body.data.turns.at(-1)?.id ?? "initial";
    const idempotencyKey = requireIdempotencyKey(request);
    const expectedKey = `reflection-response:${body.data.session_id.toLowerCase()}:${lastTurnId.toLowerCase()}`;
    if (idempotencyKey !== expectedKey) throw new LoreApiError("invalid_request", 400, false);

    const config = loadFireworksRuntimeConfig(dependencies.environment);
    const lease = await acquireProcessingLease({
      authorization,
      task: "reflection_guide",
      taskId: lastTurnId.toLowerCase(),
      idempotencyKey,
      ...(dependencies.auth?.now ? { now: dependencies.auth.now } : {})
    });
    try {
      writeSafeLog({
        event: "provider_started",
        request_id: id,
        route: "reflection_guide",
        provider: "fireworks",
        model_alias: "reflection-guide-v1"
      });
      const client = new FireworksClient({
        config,
        ...(dependencies.fetch ? { fetch: dependencies.fetch } : {})
      });
      const response = await client.generateReflectionGuide(id, body.data, processingSignal(request));
      writeSafeLog({
        event: "request_completed",
        request_id: id,
        route: "reflection_guide",
        status: 200,
        duration_ms: Math.round(performance.now() - startedAt)
      });
      return jsonSuccess(response, id);
    } finally {
      await lease.release().catch(() => false);
    }
  } catch (error) {
    const apiError = error instanceof LoreApiError
      ? error
      : new LoreApiError("internal_error", 500, true);
    writeSafeLog({
      event: "request_failed",
      request_id: id,
      route: "reflection_guide",
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

export default { fetch: handleReflectionGuide };
