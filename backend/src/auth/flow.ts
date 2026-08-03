import { createCipheriv, createHash, createHmac, randomBytes } from "node:crypto";
import type { AppAttestRuntimeConfig } from "../config.js";
import {
  AssertionClientDataSchema,
  type AttestationRequest,
  type ChallengePurpose,
  type ChallengeResponse,
  type SessionRequest,
  type SessionResponse
} from "../contracts/auth.js";
import { API_SCHEMA_VERSION } from "../contracts/common.js";
import { LoreApiError } from "../http/errors.js";
import type { AppAttestCryptographicVerifier } from "./app-attest-verifier.js";
import { issueSessionToken } from "./session-token.js";
import type { AuthStateStore, ChallengeConsumeResult } from "./state-store.js";

export type AppAttestFlowDependencies = {
  config: AppAttestRuntimeConfig;
  store: AuthStateStore;
  verifier: AppAttestCryptographicVerifier;
  now?: () => Date;
  randomChallenge?: () => Buffer;
  randomId?: () => string;
};

export class AppAttestFlow {
  private readonly now: () => Date;
  private readonly randomChallenge: () => Buffer;
  private readonly randomId: () => string;

  constructor(private readonly dependencies: AppAttestFlowDependencies) {
    this.now = dependencies.now ?? (() => new Date());
    this.randomChallenge = dependencies.randomChallenge ?? (() => randomBytes(32));
    this.randomId = dependencies.randomId ?? (() => crypto.randomUUID());
  }

  async issueChallenge(input: {
    purpose: ChallengePurpose;
    keyId: string | null;
    rateLimitIdentity: string;
  }): Promise<ChallengeResponse> {
    const now = this.now();
    const rateBucket = this.opaqueReference(`challenge-rate:${input.rateLimitIdentity}`);
    if (!await this.dependencies.store.incrementRateLimit(rateBucket, now, 900, 30)) {
      throw new LoreApiError("rate_limited", 429, true, undefined, 900);
    }
    const challenge = this.randomChallenge().toString("base64url");
    const id = this.randomId();
    const expiresAt = new Date(now.getTime() + this.dependencies.config.challengeTtlSeconds * 1_000);
    await this.dependencies.store.putChallenge({
      id,
      challengeHash: this.challengeHash(challenge),
      purpose: input.purpose,
      keyRef: input.keyId ? this.keyReference(input.keyId) : null,
      expiresAt
    });
    return {
      schema_version: API_SCHEMA_VERSION,
      challenge_id: id,
      challenge,
      purpose: input.purpose,
      expires_at: expiresAt.toISOString()
    };
  }

  async attest(request: AttestationRequest): Promise<SessionResponse> {
    const now = this.now();
    await this.inspectChallengeOrThrow({
      id: request.challenge_id,
      challenge: request.challenge,
      purpose: "attestation",
      keyRef: null,
      now
    });

    let verified;
    try {
      verified = await this.dependencies.verifier.verifyAttestation({
        attestation: decodeCanonicalBase64(request.attestation_object),
        challenge: Buffer.from(request.challenge, "utf8"),
        keyId: request.key_id,
        config: this.dependencies.config,
        now
      });
    } catch {
      throw new LoreApiError("attestation_invalid", 401, false);
    }
    if ((verified.validationCategory === null) !== (verified.bundleVersion === null)) {
      throw new LoreApiError("attestation_invalid", 401, false);
    }

    const keyRef = this.keyReference(request.key_id);
    const registration = await this.dependencies.store.registerKeyWithChallenge({
      challenge: {
        id: request.challenge_id,
        challengeHash: this.challengeHash(request.challenge),
        purpose: "attestation",
        now
      },
      key: {
        keyRef,
        keyIdHash: this.opaqueReference(`key-id:${request.key_id}`),
        publicKeyPem: verified.publicKeyPem,
        receiptCiphertext: this.encryptReceipt(verified.receiptBase64),
        environment: verified.environment,
        validationCategory: verified.validationCategory,
        bundleVersion: verified.bundleVersion,
        counter: 0,
        createdAt: now,
        updatedAt: now
      }
    });
    if (registration === "key_exists") throw new LoreApiError("attestation_invalid", 409, false);
    throwForChallengeResult(registration);
    return this.sessionResponse(keyRef, now);
  }

  async createSession(request: SessionRequest): Promise<SessionResponse> {
    const now = this.now();
    const keyRef = this.keyReference(request.key_id);
    const clientData = decodeCanonicalBase64(request.client_data);
    let decodedClientData;
    try {
      decodedClientData = AssertionClientDataSchema.parse(JSON.parse(clientData.toString("utf8")));
    } catch {
      throw new LoreApiError("assertion_invalid", 401, false);
    }
    if (decodedClientData.challenge_id !== request.challenge_id
      || decodedClientData.challenge !== request.challenge) {
      throw new LoreApiError("assertion_invalid", 401, false);
    }

    await this.inspectChallengeOrThrow({
      id: request.challenge_id,
      challenge: request.challenge,
      purpose: "assertion",
      keyRef,
      now
    });
    const key = await this.dependencies.store.getKey(keyRef);
    if (!key) {
      throw new LoreApiError("app_attest_key_unknown", 401, false);
    }
    if (key.environment !== this.dependencies.config.environment) {
      throw new LoreApiError("assertion_invalid", 401, false);
    }

    let verified;
    try {
      verified = await this.dependencies.verifier.verifyAssertion({
        assertion: decodeCanonicalBase64(request.assertion_object),
        clientData,
        publicKeyPem: key.publicKeyPem,
        previousCounter: key.counter,
        config: this.dependencies.config
      });
    } catch {
      throw new LoreApiError("assertion_invalid", 401, false);
    }
    const storedHasExtensions = key.validationCategory !== null && key.bundleVersion !== null;
    const storedHasPartialExtensions = (key.validationCategory === null) !== (key.bundleVersion === null);
    const assertionHasExtensions = verified.validationCategory !== null && verified.bundleVersion !== null;
    const assertionHasPartialExtensions = (verified.validationCategory === null) !== (verified.bundleVersion === null);
    if (storedHasPartialExtensions || assertionHasPartialExtensions
      || (storedHasExtensions && (!assertionHasExtensions
        || verified.validationCategory !== key.validationCategory
        || verified.bundleVersion !== key.bundleVersion))) {
      throw new LoreApiError("assertion_invalid", 401, false);
    }

    const advanced = await this.dependencies.store.advanceCounterWithChallenge({
      challenge: {
        id: request.challenge_id,
        challengeHash: this.challengeHash(request.challenge),
        purpose: "assertion",
        keyRef,
        now
      },
      expectedPreviousCounter: key.counter,
      nextCounter: verified.counter
    });
    if (advanced === "counter_replayed") throw new LoreApiError("counter_replayed", 409, false);
    throwForChallengeResult(advanced);
    return this.sessionResponse(keyRef, now);
  }

  keyReference(keyId: string): string {
    return this.opaqueReference(`key:${keyId}`);
  }

  private sessionResponse(keyRef: string, now: Date): SessionResponse {
    const issued = issueSessionToken(keyRef, this.dependencies.config, now, this.randomId);
    return {
      schema_version: API_SCHEMA_VERSION,
      token_type: "Bearer",
      session_token: issued.token,
      expires_at: issued.expiresAt.toISOString()
    };
  }

  private async inspectChallengeOrThrow(input: {
    id: string;
    challenge: string;
    purpose: ChallengePurpose;
    keyRef: string | null;
    now: Date;
  }): Promise<void> {
    const result = await this.dependencies.store.inspectChallenge({
      id: input.id,
      challengeHash: this.challengeHash(input.challenge),
      purpose: input.purpose,
      keyRef: input.keyRef,
      now: input.now
    });
    throwForChallengeResult(result);
  }

  private encryptReceipt(receiptBase64: string): string {
    const initializationVector = randomBytes(12);
    const cipher = createCipheriv(
      "aes-256-gcm",
      this.dependencies.config.receiptEncryptionKey,
      initializationVector
    );
    const ciphertext = Buffer.concat([cipher.update(receiptBase64, "utf8"), cipher.final()]);
    const tag = cipher.getAuthTag();
    return `v1.${initializationVector.toString("base64url")}.${tag.toString("base64url")}.${ciphertext.toString("base64url")}`;
  }

  private challengeHash(challenge: string): string {
    return createHash("sha256").update(challenge, "utf8").digest("hex");
  }

  private opaqueReference(value: string): string {
    return createHmac("sha256", this.dependencies.config.stateHmacSecret).update(value).digest("hex");
  }
}

function throwForChallengeResult(result: ChallengeConsumeResult): void {
  switch (result) {
  case "consumed": return;
  case "expired": throw new LoreApiError("challenge_expired", 410, false);
  case "replayed": throw new LoreApiError("challenge_replayed", 409, false);
  case "mismatch":
  case "missing": throw new LoreApiError("unauthorized", 401, false);
  }
}

function decodeCanonicalBase64(value: string): Buffer {
  const decoded = Buffer.from(value, "base64");
  if (decoded.length === 0 || decoded.toString("base64") !== value) {
    throw new LoreApiError("invalid_request", 400, false);
  }
  return decoded;
}
