import { timingSafeEqual } from "node:crypto";
import type { MaintenanceRuntimeConfig } from "../config.js";
import { LoreApiError } from "../http/errors.js";
import type { AuthStateStore, SecurityMetadataCleanupResult } from "../auth/state-store.js";

export type SecurityMetadataCleanupStore = Pick<AuthStateStore, "cleanupExpiredSecurityMetadata">;

export function requireCronAuthorization(request: Request, config: MaintenanceRuntimeConfig): void {
  const actual = Buffer.from(request.headers.get("authorization") ?? "", "utf8");
  const expected = Buffer.from(`Bearer ${config.cronSecret}`, "utf8");
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
    throw new LoreApiError("unauthorized", 401, false);
  }
}

export async function cleanupExpiredSecurityMetadata(input: {
  store: SecurityMetadataCleanupStore;
  now: Date;
  batchSize: number;
}): Promise<SecurityMetadataCleanupResult> {
  if (!Number.isInteger(input.batchSize) || input.batchSize < 1 || input.batchSize > 1000) {
    throw new Error("Security metadata cleanup batch must be between 1 and 1000");
  }
  return input.store.cleanupExpiredSecurityMetadata(input.now, input.batchSize);
}
