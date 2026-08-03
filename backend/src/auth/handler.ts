import { createHmac } from "node:crypto";
import { loadAppAttestRuntimeConfig, type AppAttestRuntimeConfig } from "../config.js";
import { LoreApiError } from "../http/errors.js";
import { AppAttestFlow } from "./flow.js";
import { NodeAppAttestVerifier, type AppAttestCryptographicVerifier } from "./app-attest-verifier.js";
import { NeonAuthStateStore, type AuthStateStore } from "./state-store.js";

export type AuthHandlerDependencies = {
  environment?: NodeJS.ProcessEnv;
  config?: AppAttestRuntimeConfig;
  store?: AuthStateStore;
  verifier?: AppAttestCryptographicVerifier;
  now?: () => Date;
  randomChallenge?: () => Buffer;
  randomId?: () => string;
};

export function makeAppAttestFlow(dependencies: AuthHandlerDependencies): AppAttestFlow {
  const config = dependencies.config ?? loadAppAttestRuntimeConfig(dependencies.environment);
  return new AppAttestFlow({
    config,
    store: dependencies.store ?? new NeonAuthStateStore(config.databaseUrl),
    verifier: dependencies.verifier ?? new NodeAppAttestVerifier(),
    ...(dependencies.now ? { now: dependencies.now } : {}),
    ...(dependencies.randomChallenge ? { randomChallenge: dependencies.randomChallenge } : {}),
    ...(dependencies.randomId ? { randomId: dependencies.randomId } : {})
  });
}

export function rateLimitIdentity(request: Request, config: AppAttestRuntimeConfig): string {
  const forwarded = request.headers.get("x-vercel-forwarded-for")
    ?? request.headers.get("x-forwarded-for")?.split(",")[0]?.trim()
    ?? "unavailable";
  return createHmac("sha256", config.stateHmacSecret).update(`network:${forwarded}`).digest("hex");
}

export async function requireJsonBody(request: Request, maximumBytes = 400_000): Promise<unknown> {
  const contentType = request.headers.get("content-type")?.toLowerCase() ?? "";
  if (!contentType.startsWith("application/json")) {
    throw new LoreApiError("invalid_request", 415, false);
  }
  const rawLength = request.headers.get("content-length");
  if (rawLength && Number(rawLength) > maximumBytes) {
    throw new LoreApiError("payload_too_large", 413, false);
  }
  try {
    const text = await request.text();
    if (Buffer.byteLength(text, "utf8") > maximumBytes) {
      throw new LoreApiError("payload_too_large", 413, false);
    }
    return JSON.parse(text);
  } catch (error) {
    if (error instanceof LoreApiError) throw error;
    throw new LoreApiError("invalid_request", 400, false);
  }
}
