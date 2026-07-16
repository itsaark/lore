import { timingSafeEqual } from "node:crypto";
import { LoreApiError } from "./errors.js";

export function requirePreviewAuthorization(
  request: Request,
  environment: NodeJS.ProcessEnv = process.env
): void {
  if (environment.VERCEL_ENV === "production") {
    throw new LoreApiError("provider_policy_unverified", 503, false);
  }

  const expected = environment.LORE_PREVIEW_BEARER_TOKEN;
  const authorization = request.headers.get("authorization");
  if (!expected || !authorization?.startsWith("Bearer ")) {
    throw new LoreApiError("unauthorized", 401, false);
  }

  const actual = authorization.slice("Bearer ".length);
  const expectedBytes = Buffer.from(expected);
  const actualBytes = Buffer.from(actual);
  if (expectedBytes.length !== actualBytes.length || !timingSafeEqual(expectedBytes, actualBytes)) {
    throw new LoreApiError("unauthorized", 401, false);
  }
}
