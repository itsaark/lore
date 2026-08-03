import { API_SCHEMA_VERSION, type ApiErrorCode, type ApiErrorResponse } from "../contracts/common.js";

const DEFAULT_MESSAGES: Record<ApiErrorCode, string> = {
  unauthorized: "This request is not authorized.",
  auth_unavailable: "Installation authentication is temporarily unavailable.",
  challenge_expired: "The installation challenge expired.",
  challenge_replayed: "The installation challenge was already used.",
  attestation_invalid: "The app installation attestation is invalid.",
  assertion_invalid: "The app installation assertion is invalid.",
  app_attest_key_unknown: "The app installation key is not registered.",
  counter_replayed: "The app installation assertion counter is invalid.",
  rate_limited: "Too many authentication requests were made. Please try again shortly.",
  processing_in_progress: "This processing job is already running.",
  consent_required: "Remote processing permission is required.",
  unsupported_schema: "This app version is not supported by the processing service.",
  invalid_request: "The processing request is invalid.",
  payload_too_large: "The audio chunk is too large.",
  unsupported_audio: "The audio format is not supported.",
  provider_rate_limited: "Remote processing is busy. Please try again shortly.",
  provider_unavailable: "Remote processing is temporarily unavailable.",
  provider_policy_unverified: "Remote processing is disabled or its provider policy is not configured.",
  invalid_provider_response: "Remote processing returned an invalid result.",
  empty_transcript: "No usable speech was found.",
  request_cancelled: "The processing request was cancelled.",
  internal_error: "The processing request could not be completed."
};

export class LoreApiError extends Error {
  constructor(
    readonly code: ApiErrorCode,
    readonly status: number,
    readonly retryable: boolean,
    message: string = DEFAULT_MESSAGES[code],
    readonly retryAfterSeconds: number | null = null
  ) {
    super(message);
    this.name = "LoreApiError";
  }
}

export function errorResponse(error: unknown, requestId: string): Response {
  const apiError = error instanceof LoreApiError
    ? error
    : new LoreApiError("internal_error", 500, true);
  const body: ApiErrorResponse = {
    schema_version: API_SCHEMA_VERSION,
    request_id: requestId,
    error: {
      code: apiError.code,
      message: apiError.message,
      retryable: apiError.retryable
    },
    retry_after_seconds: apiError.retryAfterSeconds
  };

  return Response.json(body, {
    status: apiError.status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
      ...(apiError.retryAfterSeconds === null
        ? {}
        : { "Retry-After": String(apiError.retryAfterSeconds) })
    }
  });
}
