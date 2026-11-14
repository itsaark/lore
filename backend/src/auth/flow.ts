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
import { API_SCHEMA_VERSION, type ApiErrorCode } from "../contracts/common.js";
import { LoreApiError } from "../http/errors.js";
import { writeSafeLog } from "../http/logger.js";
import type { AppAttestCryptographicVerifier } from "./app-attest-verifier.js";
import { issueSessionToken } from "./session-token.js";
import type { AuthStateStore, ChallengeConsumeResult } from "./state-store.js";

export type AppAttestFlowDependencies = {
  config: AppAttestRuntimeConfig;
  /** Receives content-free rejection reasons; defaults to the safe runtime log. */
  logRejection?: (route: "auth_attestation" | "auth_session", code: string, reason: string) => void;
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
    } catch (error) {
      throw this.reject("auth_attestation", "attestation_invalid", 401, verificationReason(error));
    }
    if ((verified.validationCategory === null) !== (verified.bundleVersion === null)) {
      throw this.reject("auth_attestation", "attestation_invalid", 401, "partial_extensions");
    }
    if (!categoryMatchesEnvironment(verified.validationCategory, verified.environment)) {
      throw this.reject("auth_attestation", "attestation_invalid", 401, "development_category_production_key");
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
      throw this.reject("auth_session", "assertion_invalid", 401, "client_data_invalid");
    }
    if (decodedClientData.challenge_id !== request.challenge_id
      || decodedClientData.challenge !== request.challenge) {
      throw this.reject("auth_session", "assertion_invalid", 401, "client_data_mismatch");
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
    if (!this.dependencies.config.allowedAttestationEnvironments.has(key.environment)) {
      throw this.reject("auth_session", "assertion_invalid", 401, "environment_not_allowed");
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
    } catch (error) {
      const reason = verificationReason(error);
      if (reason === "counter_not_increased") {
        // A concurrent renewal for the same key already advanced the counter.
        // Report it like the atomic store does so clients retry, not rotate.
        throw this.reject("auth_session", "counter_replayed", 409, reason);
      }
      throw this.reject("auth_session", "assertion_invalid", 401, reason);
    }
    const storedHasExtensions = key.validationCategory !== null && key.bundleVersion !== null;
    const storedHasPartialExtensions = (key.validationCategory === null) !== (key.bundleVersion === null);
    const assertionHasExtensions = verified.validationCategory !== null && verified.bundleVersion !== null;
    const assertionHasPartialExtensions = (verified.validationCategory === null) !== (verified.bundleVersion === null);
    if (storedHasPartialExtensions || assertionHasPartialExtensions
      || (storedHasExtensions && (!assertionHasExtensions
        || verified.validationCategory !== key.validationCategory))) {
      throw this.reject("auth_session", "assertion_invalid", 401, extensionMismatchReason(key, verified));
    }
    // The bundle version is deliberately not pinned to the enrollment: App
    // Attest keys survive app updates, so every release changes it for
    // existing keys. The verifier has already checked its encoding.
    if (!categoryMatchesEnvironment(verified.validationCategory, key.environment)) {
      throw this.reject("auth_session", "assertion_invalid", 401, "development_category_production_key");
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

  private reject(
    route: "auth_attestation" | "auth_session",
    code: ApiErrorCode,
    status: number,
    reason: string
  ): LoreApiError {
    try {
      (this.dependencies.logRejection ?? defaultRejectionLog)(route, code, reason);
    } catch {
      // Diagnostics must never change the authentication outcome.
    }
    return new LoreApiError(code, status, false);
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

function defaultRejectionLog(route: "auth_attestation" | "auth_session", code: string, reason: string): void {
  writeSafeLog({
    event: "request_failed",
    request_id: "auth",
    route,
    status: code === "counter_replayed" ? 409 : 401,
    error_code: code,
    reason
  });
}

const VERIFICATION_REASONS: ReadonlyArray<[string, string]> = [
  ["wrong app identifier", "wrong_app_identifier"],
  ["counter did not increase", "counter_not_increased"],
  ["invalid assertion signature", "signature_invalid"],
  ["invalid assertion shape", "assertion_shape_invalid"],
  ["invalid assertion CBOR", "assertion_cbor_invalid"],
  ["unexpected CBOR fields", "cbor_fields_unexpected"],
  ["invalid assertion authenticator data", "auth_data_too_short"],
  ["unexpected assertion authenticator data", "auth_data_trailing_bytes_without_ed"],
  ["missing assertion extensions", "assertion_extensions_missing"],
  ["invalid assertion extension encoding", "assertion_extension_encoding_invalid"],
  ["invalid App Attest extensions", "extension_map_invalid"],
  ["invalid validation category", "validation_category_invalid"],
  ["invalid bundle version", "bundle_version_invalid"],
  ["validation category not allowed", "validation_category_not_allowed"],
  ["invalid attestation", "attestation_invalid"],
  ["invalid certificate chain", "certificate_chain_invalid"],
  ["certificate outside validity period", "certificate_expired"],
  ["invalid credential identifier", "credential_identifier_invalid"],
  ["unknown App Attest environment", "environment_unknown"],
  ["wrong App Attest environment", "environment_not_allowed"]
];

/** Maps the verifier's fixed messages to slugs; anything else stays opaque. */
export function verificationReason(error: unknown): string {
  const message = error instanceof Error ? error.message : "";
  for (const [prefix, reason] of VERIFICATION_REASONS) {
    if (message.startsWith(prefix)) return reason;
  }
  return "verifier_exception";
}

/** Development-signed launches (category 3) may only use development App Attest keys. */
function categoryMatchesEnvironment(
  category: number | null,
  environment: "development" | "production"
): boolean {
  return category !== 3 || environment === "development";
}

function extensionMismatchReason(
  key: { validationCategory: number | null; bundleVersion: string | null },
  verified: { validationCategory: number | null; bundleVersion: string | null }
): string {
  if ((key.validationCategory === null) !== (key.bundleVersion === null)) return "stored_partial_extensions";
  if ((verified.validationCategory === null) !== (verified.bundleVersion === null)) return "assertion_partial_extensions";
  if (verified.validationCategory === null) return "assertion_extensions_absent";
  return "validation_category_changed";
}
