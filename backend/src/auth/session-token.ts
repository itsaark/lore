import { createHmac, timingSafeEqual } from "node:crypto";
import { z } from "zod";
import type { AppAttestRuntimeConfig } from "../config.js";

const HeaderSchema = z.object({ alg: z.literal("HS256"), typ: z.literal("JWT") }).strict();
const ClaimsSchema = z.object({
  iss: z.literal("lore-processing-api"),
  aud: z.literal("lore-ios"),
  sub: z.string().regex(/^[a-f0-9]{64}$/),
  scope: z.literal("processing"),
  env: z.enum(["development", "production"]),
  iat: z.number().int().nonnegative(),
  exp: z.number().int().positive(),
  jti: z.string().uuid()
}).strict();

export type SessionClaims = z.infer<typeof ClaimsSchema>;

export function issueSessionToken(
  keyRef: string,
  config: AppAttestRuntimeConfig,
  now: Date,
  randomId: () => string = () => crypto.randomUUID()
): { token: string; expiresAt: Date } {
  const issuedAt = Math.floor(now.getTime() / 1_000);
  const expiresAt = new Date((issuedAt + config.sessionTtlSeconds) * 1_000);
  const header = base64UrlJson({ alg: "HS256", typ: "JWT" });
  const payload = base64UrlJson({
    iss: "lore-processing-api",
    aud: "lore-ios",
    sub: keyRef,
    scope: "processing",
    env: config.environment,
    iat: issuedAt,
    exp: Math.floor(expiresAt.getTime() / 1_000),
    jti: randomId()
  });
  const unsigned = `${header}.${payload}`;
  const signature = createHmac("sha256", config.sessionSigningSecret).update(unsigned).digest("base64url");
  return { token: `${unsigned}.${signature}`, expiresAt };
}

export function verifySessionToken(
  token: string,
  config: AppAttestRuntimeConfig,
  now: Date = new Date()
): SessionClaims {
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("invalid session token");
  const [encodedHeader, encodedPayload, actualSignature] = parts as [string, string, string];
  const expectedSignature = createHmac("sha256", config.sessionSigningSecret)
    .update(`${encodedHeader}.${encodedPayload}`)
    .digest();
  const actualBytes = Buffer.from(actualSignature, "base64url");
  if (actualBytes.length !== expectedSignature.length || !timingSafeEqual(actualBytes, expectedSignature)) {
    throw new Error("invalid session signature");
  }
  const header = HeaderSchema.parse(parseBase64UrlJson(encodedHeader));
  void header;
  const claims = ClaimsSchema.parse(parseBase64UrlJson(encodedPayload));
  const nowSeconds = Math.floor(now.getTime() / 1_000);
  if (claims.exp <= nowSeconds || claims.iat > nowSeconds + 30 || claims.exp - claims.iat > 900) {
    throw new Error("expired session token");
  }
  if (claims.env !== config.environment) throw new Error("wrong session environment");
  return claims;
}

function base64UrlJson(value: unknown): string {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
}

function parseBase64UrlJson(value: string): unknown {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw new Error("invalid JWT encoding");
  return JSON.parse(Buffer.from(value, "base64url").toString("utf8"));
}
