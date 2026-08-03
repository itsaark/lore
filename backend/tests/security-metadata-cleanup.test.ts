import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { handleSecurityMetadataCleanup } from "../api/internal/security-metadata-cleanup.js";
import type { MaintenanceRuntimeConfig } from "../src/config.js";
import { MemoryAuthStateStore, type SecurityMetadataCleanupResult } from "../src/auth/state-store.js";

const baseTime = new Date("2026-08-03T20:00:00.000Z");
const cleanupTime = new Date("2026-08-03T20:03:00.000Z");

describe("bounded security metadata cleanup", () => {
  it("deletes only expired metadata, with an independent per-table batch bound", async () => {
    const store = new MemoryAuthStateStore();
    for (const id of ["expired-1", "expired-2", "expired-3"]) {
      await store.putChallenge(challenge(id, new Date(baseTime.getTime() - 1)));
    }
    await store.putChallenge(challenge("fresh", new Date(cleanupTime.getTime() + 60_000)));

    expect(await store.incrementRateLimit("opaque-old-bucket", baseTime, 60, 1)).toBe(true);
    expect(await store.incrementRateLimit("opaque-old-bucket", baseTime, 60, 1)).toBe(false);
    await store.acquireProcessingLease({
      claimRef: "a".repeat(64),
      leaseToken: "expired-lease-token-1234567890",
      now: baseTime,
      expiresAt: new Date(baseTime.getTime() + 60_000)
    });
    await store.acquireProcessingLease({
      claimRef: "b".repeat(64),
      leaseToken: "fresh-lease-token-123456789012",
      now: cleanupTime,
      expiresAt: new Date(cleanupTime.getTime() + 60_000)
    });

    await expect(store.cleanupExpiredSecurityMetadata(cleanupTime, 2)).resolves.toEqual({
      challenges: 2,
      rateLimitBuckets: 1,
      processingLeases: 1
    });
    await expect(store.inspectChallenge(challengeInspection("expired-1"))).resolves.toBe("missing");
    await expect(store.inspectChallenge(challengeInspection("expired-2"))).resolves.toBe("missing");
    await expect(store.inspectChallenge(challengeInspection("expired-3"))).resolves.toBe("expired");
    await expect(store.inspectChallenge(challengeInspection("fresh"))).resolves.toBe("consumed");
    await expect(store.incrementRateLimit("opaque-old-bucket", baseTime, 60, 1)).resolves.toBe(true);
    await expect(store.releaseProcessingLease({
      claimRef: "a".repeat(64), leaseToken: "expired-lease-token-1234567890"
    })).resolves.toBe(false);
    await expect(store.releaseProcessingLease({
      claimRef: "b".repeat(64), leaseToken: "fresh-lease-token-123456789012"
    })).resolves.toBe(true);
  });

  it.each([0, 1001, 1.5])("rejects an invalid batch size of %s", async (batchSize) => {
    await expect(new MemoryAuthStateStore().cleanupExpiredSecurityMetadata(cleanupTime, batchSize))
      .rejects.toThrow("between 1 and 1000");
  });

  it("requires the server-only cron bearer before invoking cleanup", async () => {
    let calls = 0;
    const response = await handleSecurityMetadataCleanup(cleanupRequest("wrong-secret"), {
      config: maintenanceConfig(),
      store: { cleanupExpiredSecurityMetadata: async () => { calls += 1; return zeroCounts(); } }
    });
    expect(response.status).toBe(401);
    expect(calls).toBe(0);
  });

  it("runs one bounded batch and reports when another invocation may be useful", async () => {
    const calls: Array<{ now: Date; batchSize: number }> = [];
    const response = await handleSecurityMetadataCleanup(cleanupRequest("cron-secret-at-least-32-characters"), {
      config: maintenanceConfig(),
      now: () => cleanupTime,
      store: {
        cleanupExpiredSecurityMetadata: async (now, batchSize) => {
          calls.push({ now, batchSize });
          return { challenges: 500, rateLimitBuckets: 4, processingLeases: 1 };
        }
      }
    });
    expect(response.status).toBe(200);
    expect(calls).toEqual([{ now: cleanupTime, batchSize: 500 }]);
    await expect(response.json()).resolves.toEqual({
      schema_version: "1.0",
      deleted: {
        challenges: 500,
        rate_limit_buckets: 4,
        processing_leases: 1,
        total: 505
      },
      batch_limit_per_table: 500,
      may_have_more: true
    });
  });

  it("allows only GET and fails closed when maintenance configuration is absent", async () => {
    const post = new Request("https://lore.invalid/api/internal/security-metadata-cleanup", { method: "POST" });
    expect((await handleSecurityMetadataCleanup(post)).status).toBe(405);
    expect((await handleSecurityMetadataCleanup(new Request(
      "https://lore.invalid/api/internal/security-metadata-cleanup",
      { method: "GET", headers: { Authorization: "Bearer anything" } }
    ), { environment: {} })).status).toBe(503);
  });

  it("defines three lock-safe bounded deletes and no user-content delete target", () => {
    const migration = readFileSync(
      new URL("../migrations/003_security_metadata_cleanup.sql", import.meta.url),
      "utf8"
    );
    expect(migration.match(/LIMIT p_batch_size/g)).toHaveLength(3);
    expect(migration.match(/FOR UPDATE SKIP LOCKED/g)).toHaveLength(3);
    expect(migration).toContain("p_batch_size IS NULL");
    expect([...migration.matchAll(/DELETE FROM\s+([a-z_]+)/g)].map((match) => match[1])).toEqual([
      "lore_app_attest_challenges",
      "lore_auth_rate_limits",
      "lore_processing_leases"
    ]);
  });
});

function maintenanceConfig(): MaintenanceRuntimeConfig {
  return {
    cronSecret: "cron-secret-at-least-32-characters",
    databaseUrl: "postgresql://test.invalid/lore",
    batchSize: 500
  };
}

function cleanupRequest(secret: string): Request {
  return new Request("https://lore.invalid/api/internal/security-metadata-cleanup", {
    method: "GET",
    headers: { Authorization: `Bearer ${secret}` }
  });
}

function challenge(id: string, expiresAt: Date) {
  return { id, challengeHash: "hash", purpose: "attestation" as const, keyRef: null, expiresAt };
}

function challengeInspection(id: string) {
  return { id, challengeHash: "hash", purpose: "attestation" as const, keyRef: null, now: cleanupTime };
}

function zeroCounts(): SecurityMetadataCleanupResult {
  return { challenges: 0, rateLimitBuckets: 0, processingLeases: 0 };
}
