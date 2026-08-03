import { createHash, timingSafeEqual, verify, X509Certificate } from "node:crypto";
import { decodeAllSync } from "cbor";
import { verifyAttestation as verifyCoreAttestation } from "node-app-attest";
import type { AppAttestRuntimeConfig } from "../config.js";

export type VerifiedAttestation = {
  publicKeyPem: string;
  receiptBase64: string;
  environment: "development" | "production";
  validationCategory: number | null;
  bundleVersion: string | null;
};

export type VerifiedAssertion = {
  counter: number;
  validationCategory: number | null;
  bundleVersion: string | null;
};

export interface AppAttestCryptographicVerifier {
  verifyAttestation(input: {
    attestation: Buffer;
    challenge: Buffer;
    keyId: string;
    config: AppAttestRuntimeConfig;
    now: Date;
  }): Promise<VerifiedAttestation>;
  verifyAssertion(input: {
    assertion: Buffer;
    clientData: Buffer;
    publicKeyPem: string;
    previousCounter: number;
    config: AppAttestRuntimeConfig;
  }): Promise<VerifiedAssertion>;
}

/**
 * node-app-attest is intentionally limited to Apple's certificate-chain/nonce/key core.
 * Current certificate-time, strict CBOR, environment, extension, and unsigned-counter
 * checks stay in this wrapper so package drift cannot silently weaken Lore's policy.
 */
export class NodeAppAttestVerifier implements AppAttestCryptographicVerifier {
  async verifyAttestation(input: {
    attestation: Buffer;
    challenge: Buffer;
    keyId: string;
    config: AppAttestRuntimeConfig;
    now: Date;
  }): Promise<VerifiedAttestation> {
    const decoded = decodeSingleObject(input.attestation, "attestation");
    assertExactKeys(decoded, ["fmt", "attStmt", "authData"]);
    if (decoded.fmt !== "apple-appattest" || !isRecord(decoded.attStmt) || !Buffer.isBuffer(decoded.authData)) {
      throw new Error("invalid attestation shape");
    }
    assertExactKeys(decoded.attStmt, ["x5c", "receipt"]);
    const certificates = decoded.attStmt.x5c;
    if (!Array.isArray(certificates) || certificates.length !== 2 || !certificates.every(Buffer.isBuffer)) {
      throw new Error("invalid certificate chain");
    }
    for (const rawCertificate of certificates as Buffer[]) {
      const certificate = new X509Certificate(rawCertificate);
      if (input.now < new Date(certificate.validFrom) || input.now > new Date(certificate.validTo)) {
        throw new Error("certificate outside validity period");
      }
    }

    const extensions = parseAttestationAuthenticatorExtensions(decoded.authData);
    const core = verifyCoreAttestation({
      attestation: input.attestation,
      challenge: input.challenge,
      keyId: input.keyId,
      bundleIdentifier: input.config.bundleIdentifier,
      teamIdentifier: input.config.teamIdentifier,
      allowDevelopmentEnvironment: input.config.environment === "development"
    }) as { publicKey: string; receipt: Buffer; environment: string };

    if (core.environment !== input.config.environment) {
      throw new Error("wrong App Attest environment");
    }
    if (extensions) enforceExtensionPolicy(extensions, input.config);
    return {
      publicKeyPem: core.publicKey,
      receiptBase64: Buffer.from(core.receipt).toString("base64"),
      environment: core.environment,
      validationCategory: extensions?.validationCategory ?? null,
      bundleVersion: extensions?.bundleVersion ?? null
    };
  }

  async verifyAssertion(input: {
    assertion: Buffer;
    clientData: Buffer;
    publicKeyPem: string;
    previousCounter: number;
    config: AppAttestRuntimeConfig;
  }): Promise<VerifiedAssertion> {
    const decoded = decodeSingleObject(input.assertion, "assertion");
    assertExactKeys(decoded, ["signature", "authenticatorData"]);
    if (!Buffer.isBuffer(decoded.signature) || !Buffer.isBuffer(decoded.authenticatorData)) {
      throw new Error("invalid assertion shape");
    }
    const authData = decoded.authenticatorData;
    const extensions = parseAssertionAuthenticatorExtensions(authData);

    const expectedRpId = createHash("sha256")
      .update(`${input.config.teamIdentifier}.${input.config.bundleIdentifier}`)
      .digest();
    const actualRpId = authData.subarray(0, 32);
    if (actualRpId.length !== expectedRpId.length || !timingSafeEqual(actualRpId, expectedRpId)) {
      throw new Error("wrong app identifier");
    }

    const counter = authData.readUInt32BE(33);
    if (counter === 0 || counter <= input.previousCounter) {
      throw new Error("counter did not increase");
    }
    const clientDataHash = createHash("sha256").update(input.clientData).digest();
    const nonce = createHash("sha256").update(Buffer.concat([authData, clientDataHash])).digest();
    if (!verify("sha256", nonce, input.publicKeyPem, decoded.signature)) {
      throw new Error("invalid assertion signature");
    }

    if (extensions) enforceExtensionPolicy(extensions, input.config);
    return {
      counter,
      validationCategory: extensions?.validationCategory ?? null,
      bundleVersion: extensions?.bundleVersion ?? null
    };
  }
}

export type AppAttestExtensions = { validationCategory: number; bundleVersion: string };

export function parseAttestationAuthenticatorExtensions(authData: Buffer): AppAttestExtensions | null {
  if (authData.length < 55 || (authData[32]! & 0x40) === 0) {
    throw new Error("invalid attestation authenticator data");
  }
  const credentialLength = authData.readUInt16BE(53);
  const credentialEnd = 55 + credentialLength;
  if (credentialLength !== 32 || credentialEnd >= authData.length) {
    throw new Error("invalid credential identifier");
  }
  const trailingObjects = decodeAllSync(authData.subarray(credentialEnd)) as unknown[];
  const hasExtensions = (authData[32]! & 0x80) !== 0;
  if (trailingObjects.length !== (hasExtensions ? 2 : 1)) {
    throw new Error("invalid attestation extension encoding");
  }
  return hasExtensions ? parseExtensionMap(trailingObjects[1]) : null;
}

export function parseAssertionAuthenticatorExtensions(authData: Buffer): AppAttestExtensions | null {
  if (authData.length < 37) throw new Error("invalid assertion authenticator data");
  const hasExtensions = (authData[32]! & 0x80) !== 0;
  if (!hasExtensions) {
    if (authData.length !== 37) throw new Error("unexpected assertion authenticator data");
    return null;
  }
  if (authData.length === 37) throw new Error("missing assertion extensions");
  const objects = decodeAllSync(authData.subarray(37)) as unknown[];
  if (objects.length !== 1) throw new Error("invalid assertion extension encoding");
  return parseExtensionMap(objects[0]);
}

function parseExtensionMap(value: unknown): AppAttestExtensions {
  const map = value instanceof Map ? value : isRecord(value) ? new Map(Object.entries(value)) : null;
  if (!map || map.size !== 2) throw new Error("invalid App Attest extensions");
  return {
    validationCategory: parseValidationCategory(map.get("apple_validation_category_01")),
    bundleVersion: parseBundleVersion(map.get("apple_bundle_version_01"))
  };
}

function parseValidationCategory(value: unknown): number {
  if (typeof value === "number" && Number.isInteger(value)) return value;
  if (Buffer.isBuffer(value) && value.length === 4) return value.readUInt32LE(0);
  throw new Error("invalid validation category");
}

function parseBundleVersion(value: unknown): string {
  const version = typeof value === "string" ? value : Buffer.isBuffer(value) ? value.toString("utf8") : "";
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(version)) throw new Error("invalid bundle version");
  return version;
}

function enforceExtensionPolicy(extensions: AppAttestExtensions, config: AppAttestRuntimeConfig): void {
  if (!config.allowedValidationCategories.has(extensions.validationCategory)) {
    throw new Error("validation category not allowed");
  }
  if (!config.allowedBundleVersions.has(extensions.bundleVersion)) {
    throw new Error("bundle version not allowed");
  }
}

function decodeSingleObject(bytes: Buffer, label: string): Record<string, unknown> {
  let values: unknown[];
  try {
    values = decodeAllSync(bytes) as unknown[];
  } catch {
    throw new Error(`invalid ${label} CBOR`);
  }
  if (values.length !== 1 || !isRecord(values[0])) throw new Error(`invalid ${label} CBOR shape`);
  return values[0];
}

function assertExactKeys(value: Record<string, unknown>, expected: string[]): void {
  const actual = Object.keys(value).sort();
  const sortedExpected = [...expected].sort();
  if (actual.length !== sortedExpected.length || actual.some((key, index) => key !== sortedExpected[index])) {
    throw new Error("unexpected CBOR fields");
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value) && !(value instanceof Map);
}
