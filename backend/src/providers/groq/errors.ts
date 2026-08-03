import { LoreApiError } from "../../http/errors.js";

export function groqError(response: Response): LoreApiError {
  const retryAfter = parseRetryAfter(response.headers.get("retry-after"));

  switch (response.status) {
    case 400:
    case 404:
    case 422:
      return new LoreApiError("invalid_provider_response", 502, false);
    case 413:
      return new LoreApiError("payload_too_large", 413, false);
    case 401:
    case 403:
      return new LoreApiError("provider_policy_unverified", 503, false);
    case 429:
      return new LoreApiError("provider_rate_limited", 429, true, undefined, retryAfter);
    case 499:
      return new LoreApiError("request_cancelled", 499, false);
    case 498:
    case 500:
    case 502:
    case 503:
      return new LoreApiError("provider_unavailable", 503, true, undefined, retryAfter);
    default:
      return new LoreApiError("provider_unavailable", 502, response.status >= 500);
  }
}

function parseRetryAfter(value: string | null): number | null {
  if (!value) return null;
  const seconds = Number(value);
  return Number.isInteger(seconds) && seconds > 0 ? seconds : null;
}
