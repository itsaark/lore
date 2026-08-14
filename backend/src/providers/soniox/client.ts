import { z } from "zod";
import type { SonioxRuntimeConfig } from "../../config.js";
import { LoreApiError } from "../../http/errors.js";

const TemporaryApiKeyResponseSchema = z.object({
  api_key: z.string().min(1).max(512),
  expires_at: z.iso.datetime({ offset: true })
}).passthrough();

export type SonioxTemporaryKeyUsage = "transcribe_websocket" | "tts_rt";

export type SonioxTemporaryKey = {
  apiKey: string;
  expiresAt: string;
};

export type SonioxClientOptions = {
  config: SonioxRuntimeConfig;
  fetch?: typeof globalThis.fetch;
};

export class SonioxClient {
  private readonly fetchImpl: typeof globalThis.fetch;

  constructor(private readonly options: SonioxClientOptions) {
    this.fetchImpl = options.fetch ?? globalThis.fetch;
  }

  async createTemporaryKey(
    usageType: SonioxTemporaryKeyUsage,
    clientReferenceId: string,
    signal?: AbortSignal
  ): Promise<SonioxTemporaryKey> {
    const response = await this.fetchImpl(`${this.options.config.baseUrl}/auth/temporary-api-key`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${this.options.config.apiKey}`,
        "Content-Type": "application/json",
        Accept: "application/json"
      },
      body: JSON.stringify({
        usage_type: usageType,
        // This is only the window in which the one-time WebSocket connection
        // may be opened. The connected session has its own bounded duration.
        expires_in_seconds: 300,
        client_reference_id: clientReferenceId,
        single_use: true,
        max_session_duration_seconds: 1_200
      }),
      signal: signal ?? null
    });

    if (!response.ok) throw sonioxError(response);
    const parsed = TemporaryApiKeyResponseSchema.safeParse(await safeJson(response));
    if (!parsed.success) {
      throw new LoreApiError(
        "invalid_provider_response",
        502,
        true,
        undefined,
        null,
        "soniox_temporary_key_invalid"
      );
    }
    return { apiKey: parsed.data.api_key, expiresAt: parsed.data.expires_at };
  }
}

function sonioxError(response: Response): LoreApiError {
  const retryAfter = parseRetryAfter(response.headers.get("retry-after"));
  switch (response.status) {
    case 400:
    case 404:
    case 422:
      return new LoreApiError("invalid_provider_response", 502, false);
    case 401:
    case 403:
      return new LoreApiError("provider_policy_unverified", 503, false);
    case 429:
      return new LoreApiError("provider_rate_limited", 429, true, undefined, retryAfter);
    case 499:
      return new LoreApiError("request_cancelled", 499, false);
    default:
      return new LoreApiError("provider_unavailable", 503, response.status >= 500, undefined, retryAfter);
  }
}

async function safeJson(response: Response): Promise<unknown> {
  try {
    return await response.json();
  } catch {
    throw new LoreApiError(
      "invalid_provider_response",
      502,
      true,
      undefined,
      null,
      "soniox_body_invalid_json"
    );
  }
}

function parseRetryAfter(value: string | null): number | null {
  if (!value) return null;
  const seconds = Number(value);
  return Number.isInteger(seconds) && seconds > 0 ? seconds : null;
}
