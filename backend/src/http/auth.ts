import { timingSafeEqual } from "node:crypto";
import { loadAppAttestRuntimeConfig, type AppAttestRuntimeConfig } from "../config.js";
import { verifySessionToken, type SessionClaims } from "../auth/session-token.js";
import { NeonAuthStateStore, type AuthStateStore } from "../auth/state-store.js";
import { LoreApiError } from "./errors.js";

export type ProcessingAuthorizationDependencies = {
  environment?: NodeJS.ProcessEnv;
  config?: AppAttestRuntimeConfig;
  store?: AuthStateStore;
  now?: Date;
};

export type ProcessingAuthorization =
  | { kind: "preview" }
  | {
      kind: "session";
      claims: SessionClaims;
      config: AppAttestRuntimeConfig;
      store: AuthStateStore;
    };

export async function requireProcessingAuthorization(
  request: Request,
  dependencies: ProcessingAuthorizationDependencies = {}
): Promise<ProcessingAuthorization> {
  const environment = dependencies.environment ?? process.env;
  const token = bearerToken(request);
  const previewToken = environment.LORE_PREVIEW_BEARER_TOKEN;
  const isPreviewCredential = Boolean(token && previewToken && safeEqual(token, previewToken));

  if (environment.VERCEL_ENV !== "production" && isPreviewCredential) {
    return { kind: "preview" };
  }
  if (environment.VERCEL_ENV === "production" && isPreviewCredential) {
    throw new LoreApiError("unauthorized", 401, false);
  }
  if (!token) throw new LoreApiError("unauthorized", 401, false);

  let config: AppAttestRuntimeConfig;
  let claims: SessionClaims;
  try {
    config = dependencies.config ?? loadAppAttestRuntimeConfig(environment);
    claims = verifySessionToken(token, config, dependencies.now ?? new Date());
  } catch (error) {
    if (error instanceof LoreApiError && error.code === "auth_unavailable") throw error;
    throw new LoreApiError("unauthorized", 401, false);
  }

  const store = dependencies.store ?? new NeonAuthStateStore(config.databaseUrl);
  const key = await store.getKey(claims.sub);
  if (!key || key.environment !== config.environment) {
    throw new LoreApiError("unauthorized", 401, false);
  }
  const allowed = await store.incrementRateLimit(`processing:${claims.sub}`, dependencies.now ?? new Date(), 60, 120);
  if (!allowed) throw new LoreApiError("rate_limited", 429, true, undefined, 60);
  return { kind: "session", claims, config, store };
}

/** Kept for compatibility with tests/callers that explicitly exercise preview auth. */
export function requirePreviewAuthorization(
  request: Request,
  environment: NodeJS.ProcessEnv = process.env
): void {
  if (environment.VERCEL_ENV === "production") {
    throw new LoreApiError("unauthorized", 401, false);
  }
  const expected = environment.LORE_PREVIEW_BEARER_TOKEN;
  const actual = bearerToken(request);
  if (!expected || !actual || !safeEqual(expected, actual)) {
    throw new LoreApiError("unauthorized", 401, false);
  }
}

function bearerToken(request: Request): string | null {
  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) return null;
  const token = authorization.slice("Bearer ".length);
  return token.length > 0 && token.length <= 4_096 ? token : null;
}

function safeEqual(left: string, right: string): boolean {
  const leftBytes = Buffer.from(left);
  const rightBytes = Buffer.from(right);
  return leftBytes.length === rightBytes.length && timingSafeEqual(leftBytes, rightBytes);
}
