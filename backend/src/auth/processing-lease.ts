import { createHmac, randomBytes } from "node:crypto";
import type { ProcessingAuthorization } from "../http/auth.js";
import { LoreApiError } from "../http/errors.js";

export type ProcessingTask = "transcription" | "daily_entry";

export type HeldProcessingLease = {
  claimRef: string;
  leaseToken: string;
  release: () => Promise<boolean>;
};

/**
 * Acquires the one-winner boundary for a provider invocation. Preview bearer
 * traffic is deliberately test-only and does not create durable claims.
 */
export async function acquireProcessingLease(input: {
  authorization: ProcessingAuthorization;
  task: ProcessingTask;
  taskId: string;
  idempotencyKey: string;
  now?: Date;
  randomToken?: () => string;
}): Promise<HeldProcessingLease | null> {
  if (input.authorization.kind === "preview") return null;
  const authorization = input.authorization;

  const now = input.now ?? new Date();
  const expiresAt = new Date(
    now.getTime() + authorization.config.processingLeaseTtlSeconds * 1_000
  );
  const claimRef = processingClaimReference({
    secret: authorization.config.stateHmacSecret,
    installationRef: authorization.claims.sub,
    task: input.task,
    taskId: input.taskId,
    idempotencyKey: input.idempotencyKey
  });
  const leaseToken = input.randomToken?.() ?? randomBytes(32).toString("base64url");
  let result;
  try {
    result = await authorization.store.acquireProcessingLease({
      claimRef,
      leaseToken,
      now,
      expiresAt
    });
  } catch {
    throw new LoreApiError("auth_unavailable", 503, true);
  }

  if (result.status === "active") {
    const retryAfterSeconds = Math.max(
      1,
      Math.ceil((result.expiresAt.getTime() - now.getTime()) / 1_000)
    );
    throw new LoreApiError(
      "processing_in_progress",
      409,
      true,
      undefined,
      retryAfterSeconds
    );
  }

  return {
    claimRef,
    leaseToken,
    release: () => authorization.store.releaseProcessingLease({ claimRef, leaseToken })
  };
}

export function processingClaimReference(input: {
  secret: string;
  installationRef: string;
  task: ProcessingTask;
  taskId: string;
  idempotencyKey: string;
}): string {
  return createHmac("sha256", input.secret)
    .update(lengthPrefixed([
      "lore-processing-lease-v1",
      input.installationRef,
      input.task,
      input.taskId,
      input.idempotencyKey
    ]))
    .digest("hex");
}

function lengthPrefixed(parts: readonly string[]): string {
  return parts.map((part) => `${Buffer.byteLength(part, "utf8")}:${part}`).join("|");
}
