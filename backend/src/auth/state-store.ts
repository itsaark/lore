import { neon } from "@neondatabase/serverless";
import type { ChallengePurpose } from "../contracts/auth.js";

export type ChallengeRecord = {
  id: string;
  challengeHash: string;
  purpose: ChallengePurpose;
  keyRef: string | null;
  expiresAt: Date;
};

export type ChallengeConsumeResult = "consumed" | "expired" | "replayed" | "mismatch" | "missing";

export type AppAttestKeyRecord = {
  keyRef: string;
  keyIdHash: string;
  publicKeyPem: string;
  receiptCiphertext: string;
  environment: "development" | "production";
  validationCategory: number | null;
  bundleVersion: string | null;
  counter: number;
  createdAt: Date;
  updatedAt: Date;
};

export type ProcessingLeaseAcquireResult =
  | { status: "acquired"; expiresAt: Date }
  | { status: "active"; expiresAt: Date };

export type SecurityMetadataCleanupResult = {
  challenges: number;
  rateLimitBuckets: number;
  processingLeases: number;
};

export interface AuthStateStore {
  putChallenge(record: ChallengeRecord): Promise<void>;
  inspectChallenge(input: {
    id: string;
    challengeHash: string;
    purpose: ChallengePurpose;
    keyRef: string | null;
    now: Date;
  }): Promise<ChallengeConsumeResult>;
  registerKeyWithChallenge(input: {
    challenge: { id: string; challengeHash: string; purpose: "attestation"; now: Date };
    key: AppAttestKeyRecord;
  }): Promise<ChallengeConsumeResult | "key_exists">;
  getKey(keyRef: string): Promise<AppAttestKeyRecord | null>;
  advanceCounterWithChallenge(input: {
    challenge: { id: string; challengeHash: string; purpose: "assertion"; keyRef: string; now: Date };
    expectedPreviousCounter: number;
    nextCounter: number;
  }): Promise<ChallengeConsumeResult | "counter_replayed">;
  acquireProcessingLease(input: {
    claimRef: string;
    leaseToken: string;
    now: Date;
    expiresAt: Date;
  }): Promise<ProcessingLeaseAcquireResult>;
  releaseProcessingLease(input: { claimRef: string; leaseToken: string }): Promise<boolean>;
  incrementRateLimit(bucketRef: string, now: Date, windowSeconds: number, maximum: number): Promise<boolean>;
  cleanupExpiredSecurityMetadata(now: Date, batchSize: number): Promise<SecurityMetadataCleanupResult>;
}

export class NeonAuthStateStore implements AuthStateStore {
  private readonly sql;

  constructor(databaseUrl: string) {
    this.sql = neon(databaseUrl);
  }

  async putChallenge(record: ChallengeRecord): Promise<void> {
    await this.sql.query(
      `INSERT INTO lore_app_attest_challenges
       (challenge_id, challenge_hash, purpose, key_ref, expires_at)
       VALUES ($1, $2, $3, $4, $5)`,
      [record.id, record.challengeHash, record.purpose, record.keyRef, record.expiresAt.toISOString()]
    );
  }

  async inspectChallenge(input: {
    id: string;
    challengeHash: string;
    purpose: ChallengePurpose;
    keyRef: string | null;
    now: Date;
  }): Promise<ChallengeConsumeResult> {
    const rows = await this.sql.query(
      `SELECT challenge_hash, purpose, key_ref, expires_at, consumed_at
       FROM lore_app_attest_challenges WHERE challenge_id = $1`,
      [input.id]
    ) as Array<Record<string, unknown>>;
    const row = rows[0];
    if (!row) return "missing";
    if (row.consumed_at) return "replayed";
    if (new Date(String(row.expires_at)) <= input.now) return "expired";
    if (row.challenge_hash !== input.challengeHash || row.purpose !== input.purpose || row.key_ref !== input.keyRef) {
      return "mismatch";
    }
    return "consumed";
  }

  async registerKeyWithChallenge(input: {
    challenge: { id: string; challengeHash: string; purpose: "attestation"; now: Date };
    key: AppAttestKeyRecord;
  }): Promise<ChallengeConsumeResult | "key_exists"> {
    const rows = await this.sql.query(
      `SELECT lore_register_app_attest_key(
         $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12
       ) AS status`,
      [input.challenge.id, input.challenge.challengeHash,
        input.challenge.now.toISOString(), input.key.keyRef, input.key.keyIdHash,
        input.key.publicKeyPem, input.key.receiptCiphertext, input.key.environment,
        input.key.validationCategory, input.key.bundleVersion, input.key.counter,
        input.key.createdAt.toISOString()]
    ) as Array<Record<string, unknown>>;
    return parseStoreStatus(rows[0]?.status, ["consumed", "expired", "replayed", "mismatch", "missing", "key_exists"]);
  }

  async getKey(keyRef: string): Promise<AppAttestKeyRecord | null> {
    const rows = await this.sql.query(
      `SELECT key_ref, key_id_hash, public_key_pem, receipt_ciphertext, environment,
              validation_category, bundle_version, counter, created_at, updated_at
       FROM lore_app_attest_keys WHERE key_ref = $1`,
      [keyRef]
    ) as Array<Record<string, unknown>>;
    const row = rows[0];
    if (!row) return null;
    return {
      keyRef: String(row.key_ref),
      keyIdHash: String(row.key_id_hash),
      publicKeyPem: String(row.public_key_pem),
      receiptCiphertext: String(row.receipt_ciphertext),
      environment: row.environment === "development" ? "development" : "production",
      validationCategory: row.validation_category === null ? null : Number(row.validation_category),
      bundleVersion: row.bundle_version === null ? null : String(row.bundle_version),
      counter: Number(row.counter),
      createdAt: new Date(String(row.created_at)),
      updatedAt: new Date(String(row.updated_at))
    };
  }

  async advanceCounterWithChallenge(input: {
    challenge: { id: string; challengeHash: string; purpose: "assertion"; keyRef: string; now: Date };
    expectedPreviousCounter: number;
    nextCounter: number;
  }): Promise<ChallengeConsumeResult | "counter_replayed"> {
    const rows = await this.sql.query(
      `SELECT lore_advance_app_attest_counter($1, $2, $3, $4, $5, $6) AS status`,
      [input.challenge.id, input.challenge.challengeHash, input.challenge.keyRef,
        input.expectedPreviousCounter, input.nextCounter, input.challenge.now.toISOString()]
    ) as Array<Record<string, unknown>>;
    return parseStoreStatus(rows[0]?.status, [
      "consumed", "expired", "replayed", "mismatch", "missing", "counter_replayed"
    ]);
  }

  async acquireProcessingLease(input: {
    claimRef: string;
    leaseToken: string;
    now: Date;
    expiresAt: Date;
  }): Promise<ProcessingLeaseAcquireResult> {
    const rows = await this.sql.query(
      `SELECT result_status, result_expires_at
       FROM lore_acquire_processing_lease($1, $2, $3, $4)`,
      [input.claimRef, input.leaseToken, input.now.toISOString(), input.expiresAt.toISOString()]
    ) as Array<Record<string, unknown>>;
    const row = rows[0];
    if ((row?.result_status !== "acquired" && row?.result_status !== "active") || !row.result_expires_at) {
      throw new Error("Processing lease transaction returned an invalid result");
    }
    return {
      status: row.result_status,
      expiresAt: new Date(String(row.result_expires_at))
    };
  }

  async releaseProcessingLease(input: { claimRef: string; leaseToken: string }): Promise<boolean> {
    const rows = await this.sql.query(
      `DELETE FROM lore_processing_leases
       WHERE claim_ref = $1 AND lease_token = $2
       RETURNING claim_ref`,
      [input.claimRef, input.leaseToken]
    ) as Array<Record<string, unknown>>;
    return rows.length === 1;
  }

  async incrementRateLimit(
    bucketRef: string,
    now: Date,
    windowSeconds: number,
    maximum: number
  ): Promise<boolean> {
    const windowMilliseconds = windowSeconds * 1_000;
    const windowStart = new Date(Math.floor(now.getTime() / windowMilliseconds) * windowMilliseconds);
    const expiresAt = new Date(windowStart.getTime() + windowMilliseconds * 2);
    const rows = await this.sql.query(
      `INSERT INTO lore_auth_rate_limits (bucket_ref, window_started_at, request_count, expires_at)
       VALUES ($1, $2, 1, $3)
       ON CONFLICT (bucket_ref, window_started_at)
       DO UPDATE SET request_count = lore_auth_rate_limits.request_count + 1
       RETURNING request_count`,
      [bucketRef, windowStart.toISOString(), expiresAt.toISOString()]
    ) as Array<Record<string, unknown>>;
    return Number(rows[0]?.request_count ?? maximum + 1) <= maximum;
  }

  async cleanupExpiredSecurityMetadata(now: Date, batchSize: number): Promise<SecurityMetadataCleanupResult> {
    const rows = await this.sql.query(
      `SELECT deleted_challenges, deleted_rate_limit_buckets, deleted_processing_leases
       FROM lore_cleanup_expired_security_metadata($1, $2)`,
      [now.toISOString(), batchSize]
    ) as Array<Record<string, unknown>>;
    const row = rows[0];
    return {
      challenges: parseCleanupCount(row?.deleted_challenges, batchSize),
      rateLimitBuckets: parseCleanupCount(row?.deleted_rate_limit_buckets, batchSize),
      processingLeases: parseCleanupCount(row?.deleted_processing_leases, batchSize)
    };
  }
}

function parseStoreStatus<const Status extends string>(value: unknown, allowed: readonly Status[]): Status {
  if (typeof value === "string" && allowed.includes(value as Status)) return value as Status;
  throw new Error("Auth state transaction returned an invalid status");
}

function parseCleanupCount(value: unknown, batchSize: number): number {
  const count = Number(value);
  if (!Number.isInteger(count) || count < 0 || count > batchSize) {
    throw new Error("Security metadata cleanup returned an invalid count");
  }
  return count;
}

export class MemoryAuthStateStore implements AuthStateStore {
  private readonly challenges = new Map<string, ChallengeRecord & { consumedAt: Date | null }>();
  private readonly keys = new Map<string, AppAttestKeyRecord>();
  private readonly rateLimits = new Map<string, { count: number; expiresAt: Date }>();
  private readonly processingLeases = new Map<string, { leaseToken: string; expiresAt: Date }>();

  async putChallenge(record: ChallengeRecord): Promise<void> {
    if (this.challenges.has(record.id)) throw new Error("duplicate challenge");
    this.challenges.set(record.id, { ...record, consumedAt: null });
  }

  async inspectChallenge(input: {
    id: string;
    challengeHash: string;
    purpose: ChallengePurpose;
    keyRef: string | null;
    now: Date;
  }): Promise<ChallengeConsumeResult> {
    const record = this.challenges.get(input.id);
    if (!record) return "missing";
    if (record.consumedAt) return "replayed";
    if (record.expiresAt <= input.now) return "expired";
    if (record.challengeHash !== input.challengeHash || record.purpose !== input.purpose || record.keyRef !== input.keyRef) {
      return "mismatch";
    }
    return "consumed";
  }

  async registerKeyWithChallenge(input: {
    challenge: { id: string; challengeHash: string; purpose: "attestation"; now: Date };
    key: AppAttestKeyRecord;
  }): Promise<ChallengeConsumeResult | "key_exists"> {
    const status = await this.inspectChallenge({ ...input.challenge, keyRef: null });
    if (status !== "consumed") return status;
    if (this.keys.has(input.key.keyRef) || [...this.keys.values()].some((key) => key.keyIdHash === input.key.keyIdHash)) {
      this.challenges.get(input.challenge.id)!.consumedAt = input.challenge.now;
      return "key_exists";
    }
    this.challenges.get(input.challenge.id)!.consumedAt = input.challenge.now;
    this.keys.set(input.key.keyRef, { ...input.key });
    return "consumed";
  }

  async getKey(keyRef: string): Promise<AppAttestKeyRecord | null> {
    const record = this.keys.get(keyRef);
    return record ? { ...record } : null;
  }

  async advanceCounterWithChallenge(input: {
    challenge: { id: string; challengeHash: string; purpose: "assertion"; keyRef: string; now: Date };
    expectedPreviousCounter: number;
    nextCounter: number;
  }): Promise<ChallengeConsumeResult | "counter_replayed"> {
    const status = await this.inspectChallenge({ ...input.challenge });
    if (status !== "consumed") return status;
    const record = this.keys.get(input.challenge.keyRef);
    if (!record || record.counter !== input.expectedPreviousCounter || input.nextCounter <= record.counter) {
      return "counter_replayed";
    }
    this.challenges.get(input.challenge.id)!.consumedAt = input.challenge.now;
    record.counter = input.nextCounter;
    record.updatedAt = input.challenge.now;
    return "consumed";
  }

  async acquireProcessingLease(input: {
    claimRef: string;
    leaseToken: string;
    now: Date;
    expiresAt: Date;
  }): Promise<ProcessingLeaseAcquireResult> {
    const existing = this.processingLeases.get(input.claimRef);
    if (existing && existing.expiresAt > input.now) {
      return { status: "active", expiresAt: existing.expiresAt };
    }
    this.processingLeases.set(input.claimRef, {
      leaseToken: input.leaseToken,
      expiresAt: input.expiresAt
    });
    return { status: "acquired", expiresAt: input.expiresAt };
  }

  async releaseProcessingLease(input: { claimRef: string; leaseToken: string }): Promise<boolean> {
    const existing = this.processingLeases.get(input.claimRef);
    if (!existing || existing.leaseToken !== input.leaseToken) return false;
    this.processingLeases.delete(input.claimRef);
    return true;
  }

  async incrementRateLimit(bucketRef: string, now: Date, windowSeconds: number, maximum: number): Promise<boolean> {
    const window = Math.floor(now.getTime() / (windowSeconds * 1_000));
    const key = `${bucketRef}:${window}`;
    const next = (this.rateLimits.get(key)?.count ?? 0) + 1;
    this.rateLimits.set(key, {
      count: next,
      expiresAt: new Date((window + 2) * windowSeconds * 1_000)
    });
    return next <= maximum;
  }

  async cleanupExpiredSecurityMetadata(now: Date, batchSize: number): Promise<SecurityMetadataCleanupResult> {
    if (!Number.isInteger(batchSize) || batchSize < 1 || batchSize > 1000) {
      throw new Error("Security metadata cleanup batch must be between 1 and 1000");
    }
    return {
      challenges: deleteExpiredFromMap(this.challenges, batchSize, (value) => value.expiresAt <= now),
      rateLimitBuckets: deleteExpiredFromMap(this.rateLimits, batchSize, (value) => value.expiresAt <= now),
      processingLeases: deleteExpiredFromMap(this.processingLeases, batchSize, (value) => value.expiresAt <= now)
    };
  }
}

function deleteExpiredFromMap<Value>(
  values: Map<string, Value>,
  batchSize: number,
  isExpired: (value: Value) => boolean
): number {
  let deleted = 0;
  for (const [key, value] of values) {
    if (!isExpired(value)) continue;
    values.delete(key);
    deleted += 1;
    if (deleted === batchSize) break;
  }
  return deleted;
}
