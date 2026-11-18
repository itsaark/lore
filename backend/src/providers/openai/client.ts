import { z } from "zod";
import {
  DAY_ILLUSTRATION_IMAGE_COMPLEXITY,
  DAY_ILLUSTRATION_IMAGE_MODEL,
  DAY_ILLUSTRATION_IMAGE_QUALITY,
  DAY_ILLUSTRATION_IMAGE_SIZE,
  type OpenAIRuntimeConfig
} from "../../config.js";
import { RETENTION_POLICY_VERSION, type ProcessingProvenance } from "../../contracts/common.js";
import {
  DAY_ILLUSTRATION_PROMPT_VERSION,
  DayIllustrationImageSchema
} from "../../contracts/day-illustration.js";
import { LoreApiError } from "../../http/errors.js";

const STYLE_PROMPT = `An original oil painting in the manner of Claude Monet's late Impressionism: loose, broken
brushstrokes, visible impasto, soft edges, shimmering reflected light, atmosphere over detail,
a luminous palette of lilac, sea-green, rose, pale gold and blue-grey. Composed with the quiet
interiority of a Virginia Woolf novel: a single held moment, light moving across a room, a window,
a garden or the sea, a feeling more than an event. No text, letters, numbers, signatures,
watermarks, logos, or frames. No recognisable faces. Portrait canvas.`;

const ImageGenerationSchema = z.object({
  data: z.tuple([z.object({ b64_json: DayIllustrationImageSchema.shape.data_base64 })])
});

const ProviderErrorSchema = z.object({
  error: z.object({ code: z.string() })
});

export type OpenAIImageClientOptions = {
  config: OpenAIRuntimeConfig;
  fetch?: typeof globalThis.fetch;
};

export class OpenAIImageClient {
  private readonly fetchImpl: typeof globalThis.fetch;

  constructor(private readonly options: OpenAIImageClientOptions) {
    this.fetchImpl = options.fetch ?? globalThis.fetch;
  }

  async generate(
    scene: string,
    signal?: AbortSignal
  ): Promise<{ image: z.infer<typeof DayIllustrationImageSchema>; provenance: ProcessingProvenance }> {
    const { config } = this.options;
    const startedAt = performance.now();
    try {
      const response = await this.fetchImpl(`${config.baseUrl}/images/generations`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${config.apiKey}`,
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          model: DAY_ILLUSTRATION_IMAGE_MODEL,
          prompt: `${STYLE_PROMPT}\n\nScene: ${scene}`,
          size: DAY_ILLUSTRATION_IMAGE_SIZE,
          quality: DAY_ILLUSTRATION_IMAGE_QUALITY,
          complexity: DAY_ILLUSTRATION_IMAGE_COMPLEXITY,
          moderation: "auto",
          output_format: "jpeg",
          output_compression: 80,
          n: 1
        }),
        signal: signal ?? null
      });
      if (!response.ok) throw await imageGenerationError(response);

      const result = ImageGenerationSchema.safeParse(await response.json());
      if (!result.success) throw new LoreApiError("invalid_provider_response", 502, true);

      const timestamp = new Date().toISOString();
      return {
        image: {
          media_type: "image/jpeg",
          data_base64: result.data.data[0].b64_json,
          pixel_width: 1024,
          pixel_height: 1536
        },
        provenance: {
          provider_id: "openai",
          model_alias: DAY_ILLUSTRATION_PROMPT_VERSION,
          model_id: DAY_ILLUSTRATION_IMAGE_MODEL,
          model_policy_version: config.policyVersion,
          provider_request_id: response.headers.get("x-request-id"),
          processed_at: timestamp,
          processing_duration_milliseconds: Math.max(0, Math.round(performance.now() - startedAt)),
          retention_attestation: {
            mode: "request_ephemeral",
            maximum_retention_seconds: 0,
            policy_version: RETENTION_POLICY_VERSION,
            attested_at: timestamp
          }
        }
      };
    } catch (error) {
      if (error instanceof LoreApiError) throw error;
      const cause = signal?.aborted ? signal.reason : error;
      if (cause instanceof Error && cause.name === "AbortError") {
        throw new LoreApiError("request_cancelled", 499, false);
      }
      if (error instanceof SyntaxError && !signal?.aborted) {
        throw new LoreApiError("invalid_provider_response", 502, true);
      }
      throw new LoreApiError("provider_unavailable", 503, true);
    }
  }
}

async function imageGenerationError(response: Response): Promise<LoreApiError> {
  if (response.status === 400) {
    const body = await response.json().catch((error: unknown) => {
      if (error instanceof SyntaxError) return null;
      throw error;
    });
    const parsed = ProviderErrorSchema.safeParse(body);
    if (parsed.success && /content[-_]policy|moderation|content_filter|safety_violation/i.test(parsed.data.error.code)) {
      return new LoreApiError("invalid_provider_response", 422, false, undefined, null, "provider_moderation_rejected");
    }
  }

  const retryAfter = Number(response.headers.get("retry-after"));
  const retryAfterSeconds = Number.isInteger(retryAfter) && retryAfter > 0 ? retryAfter : null;
  if (response.status === 429) {
    return new LoreApiError("provider_rate_limited", 429, true, undefined, retryAfterSeconds);
  }
  if (response.status >= 500 || response.status === 408) {
    return new LoreApiError("provider_unavailable", 503, true, undefined, retryAfterSeconds);
  }
  if (response.status === 401 || response.status === 403) {
    return new LoreApiError("provider_policy_unverified", 503, false);
  }
  return new LoreApiError("invalid_provider_response", 502, false);
}
