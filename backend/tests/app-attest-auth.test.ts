import { describe, expect, it } from "vitest";
import { handleAttestation } from "../api/v1/auth/attestations.js";
import { handleChallenge } from "../api/v1/auth/challenges.js";
import { handleSession } from "../api/v1/auth/sessions.js";
import { handleDailyEntry } from "../api/v1/daily-entries.js";
import type { AppAttestRuntimeConfig } from "../src/config.js";
import {
  parseAssertionAuthenticatorExtensions,
  parseAttestationAuthenticatorExtensions,
  type AppAttestCryptographicVerifier,
  type VerifiedAssertion,
  type VerifiedAttestation
} from "../src/auth/app-attest-verifier.js";
import { AppAttestFlow } from "../src/auth/flow.js";
import { verifySessionToken } from "../src/auth/session-token.js";
import { MemoryAuthStateStore, type AuthStateStore } from "../src/auth/state-store.js";
import { requireProcessingAuthorization } from "../src/http/auth.js";

const baseTime = new Date("2026-08-03T20:00:00.000Z");
const keyId = Buffer.alloc(32, 7).toString("base64");

describe("App Attest installation sessions", () => {
  it("generates a challenge ID through the unbound-safe production UUID default", async () => {
    const flow = new AppAttestFlow({
      config: testConfig(),
      store: new MemoryAuthStateStore(),
      verifier: new FakeVerifier(),
      now: () => baseTime,
      randomChallenge: () => Buffer.alloc(32, 1)
    });

    const challenge = await flow.issueChallenge({
      purpose: "attestation",
      keyId: null,
      rateLimitIdentity: "network"
    });

    expect(challenge.challenge_id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  });

  it("issues an attestation-backed short-lived anonymous session and stores encrypted receipt state", async () => {
    const harness = makeHarness();
    const challenge = await harness.flow.issueChallenge({ purpose: "attestation", keyId: null, rateLimitIdentity: "network" });
    const response = await harness.flow.attest(attestationRequest(challenge));
    const claims = verifySessionToken(response.session_token, harness.config, baseTime);
    const key = await harness.store.getKey(harness.flow.keyReference(keyId));

    expect(claims.sub).toBe(harness.flow.keyReference(keyId));
    expect(claims.scope).toBe("processing");
    expect(response.expires_at).toBe("2026-08-03T20:10:00.000Z");
    expect(key?.counter).toBe(0);
    expect(key?.publicKeyPem).toContain("PUBLIC KEY");
    expect(key?.receiptCiphertext).toMatch(/^v1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
    expect(key?.receiptCiphertext).not.toContain(Buffer.from("receipt").toString("base64"));
    expect(key?.validationCategory).toBe(4);
    expect(key?.bundleVersion).toBe("1");
  });

  it("supports legacy enrollment and assertions without iOS 27 extensions", async () => {
    const harness = makeHarness();
    harness.verifier.attestationExtensions = null;
    harness.verifier.assertionExtensions = null;
    await register(harness);
    const key = await harness.store.getKey(harness.flow.keyReference(keyId));
    expect(key?.validationCategory).toBeNull();
    expect(key?.bundleVersion).toBeNull();

    harness.verifier.nextCounter = 1;
    await expect(harness.flow.createSession(sessionRequest(await assertionChallenge(harness))))
      .resolves.toMatchObject({ token_type: "Bearer" });
  });

  it("allows an extension-bearing assertion for a legacy enrollment", async () => {
    const harness = makeHarness();
    harness.verifier.attestationExtensions = null;
    await register(harness);
    harness.verifier.nextCounter = 1;
    await expect(harness.flow.createSession(sessionRequest(await assertionChallenge(harness))))
      .resolves.toMatchObject({ token_type: "Bearer" });
  });

  it("rejects partial extension state during enrollment", async () => {
    const harness = makeHarness();
    harness.verifier.attestationExtensions = { validationCategory: 4, bundleVersion: null };
    const challenge = await harness.flow.issueChallenge({ purpose: "attestation", keyId: null, rateLimitIdentity: "network" });
    await expect(harness.flow.attest(attestationRequest(challenge)))
      .rejects.toMatchObject({ code: "attestation_invalid", status: 401 });
  });

  it.each([
    ["extension downgrade", null, null],
    ["validation category mismatch", 5, "1"],
    ["bundle version mismatch", 4, "2"],
    ["partial extension state", 4, null]
  ])("rejects %s after an extension-bearing enrollment", async (_label, category, version) => {
    const harness = makeHarness({
      config: { ...testConfig(), allowedValidationCategories: new Set([4, 5]) }
    });
    await register(harness);
    harness.verifier.nextCounter = 1;
    harness.verifier.assertionExtensions = { validationCategory: category, bundleVersion: version };
    await expect(harness.flow.createSession(sessionRequest(await assertionChallenge(harness))))
      .rejects.toMatchObject({ code: "assertion_invalid", status: 401 });
  });

  it("atomically prevents challenge replay", async () => {
    const harness = makeHarness();
    const challenge = await harness.flow.issueChallenge({ purpose: "attestation", keyId: null, rateLimitIdentity: "network" });
    const request = attestationRequest(challenge);
    await harness.flow.attest(request);
    await expect(harness.flow.attest(request)).rejects.toMatchObject({ code: "challenge_replayed", status: 409 });
  });

  it("rejects expired challenges before cryptographic verification", async () => {
    let now = baseTime;
    const harness = makeHarness({ now: () => now });
    const challenge = await harness.flow.issueChallenge({ purpose: "attestation", keyId: null, rateLimitIdentity: "network" });
    now = new Date(baseTime.getTime() + 301_000);
    await expect(harness.flow.attest(attestationRequest(challenge))).rejects.toMatchObject({
      code: "challenge_expired",
      status: 410
    });
    expect(harness.verifier.attestationCalls).toBe(0);
  });

  it.each([
    ["wrong app", { bundleIdentifier: "com.attacker.app" }],
    ["wrong environment", { environment: "development" as const }]
  ])("fails closed for %s attestation policy", async (_label, override) => {
    const harness = makeHarness({ config: { ...testConfig(), ...override } });
    const challenge = await harness.flow.issueChallenge({ purpose: "attestation", keyId: null, rateLimitIdentity: "network" });
    await expect(harness.flow.attest(attestationRequest(challenge))).rejects.toMatchObject({
      code: "attestation_invalid",
      status: 401
    });
  });

  it("renews with a strictly increasing assertion counter and rejects replay", async () => {
    const harness = makeHarness();
    await register(harness);
    harness.verifier.nextCounter = 1;
    const first = await assertionChallenge(harness);
    await harness.flow.createSession(sessionRequest(first));
    expect((await harness.store.getKey(harness.flow.keyReference(keyId)))?.counter).toBe(1);

    const replay = await assertionChallenge(harness);
    await expect(harness.flow.createSession(sessionRequest(replay))).rejects.toMatchObject({
      code: "counter_replayed",
      status: 409
    });
  });

  it("allows exactly one concurrent counter advance", async () => {
    const harness = makeHarness();
    await register(harness);
    harness.verifier.nextCounter = 1;
    const first = await assertionChallenge(harness);
    const second = await assertionChallenge(harness);
    const results = await Promise.allSettled([
      harness.flow.createSession(sessionRequest(first)),
      harness.flow.createSession(sessionRequest(second))
    ]);

    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    const rejected = results.find((result): result is PromiseRejectedResult => result.status === "rejected");
    expect(rejected?.reason).toMatchObject({ code: "counter_replayed", status: 409 });
    expect((await harness.store.getKey(harness.flow.keyReference(keyId)))?.counter).toBe(1);
  });

  it("returns a key-rotation-specific error for an unknown server key", async () => {
    const harness = makeHarness();
    const challenge = await assertionChallenge(harness);
    await expect(harness.flow.createSession(sessionRequest(challenge))).rejects.toMatchObject({
      code: "app_attest_key_unknown",
      status: 401
    });
  });

  it("does not consume a challenge when verification fails before the atomic registration", async () => {
    const harness = makeHarness();
    const challenge = await harness.flow.issueChallenge({ purpose: "attestation", keyId: null, rateLimitIdentity: "network" });
    harness.verifier.failAttestation = true;
    await expect(harness.flow.attest(attestationRequest(challenge))).rejects.toMatchObject({ code: "attestation_invalid" });
    harness.verifier.failAttestation = false;
    await expect(harness.flow.attest(attestationRequest(challenge))).resolves.toMatchObject({ token_type: "Bearer" });
  });

  it("preserves the challenge when the atomic registration transaction fails", async () => {
    const store = new FailingOnceRegistrationStore();
    const harness = makeHarness({ store });
    const challenge = await harness.flow.issueChallenge({ purpose: "attestation", keyId: null, rateLimitIdentity: "network" });
    await expect(harness.flow.attest(attestationRequest(challenge))).rejects.toThrow("synthetic transaction failure");
    await expect(harness.flow.attest(attestationRequest(challenge))).resolves.toMatchObject({ token_type: "Bearer" });
  });

  it("rejects an expired session token", async () => {
    const harness = makeHarness();
    const session = await register(harness);
    expect(() => verifySessionToken(
      session.session_token,
      harness.config,
      new Date(baseTime.getTime() + 601_000)
    )).toThrow("expired session token");
  });

  it("authorizes processing with a registered session and rate-limits by opaque installation", async () => {
    const harness = makeHarness();
    const session = await register(harness);
    const request = new Request("https://lore.invalid/v1/transcriptions", {
      headers: { Authorization: `Bearer ${session.session_token}` }
    });
    const dependencies = { config: harness.config, store: harness.store, now: baseTime };

    await expect(requireProcessingAuthorization(request, dependencies)).resolves.toMatchObject({ kind: "session" });
    for (let index = 1; index < 120; index += 1) {
      await requireProcessingAuthorization(request, dependencies);
    }
    await expect(requireProcessingAuthorization(request, dependencies)).rejects.toMatchObject({
      code: "rate_limited",
      status: 429
    });
  });

  it("strictly rejects unknown request fields at auth routes", async () => {
    const harness = makeHarness();
    const response = await handleChallenge(jsonRequest("/v1/auth/app-attest/challenges", {
      schema_version: "1.0",
      purpose: "attestation",
      key_id: null,
      transcript: "must never enter auth state"
    }), routeDependencies(harness));
    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toMatchObject({ error: { code: "invalid_request" } });
  });

  it("rejects an oversized chunked auth body without relying on Content-Length", async () => {
    const harness = makeHarness();
    const request = new Request("https://lore.invalid/v1/auth/app-attest/challenges", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Forwarded-For": "192.0.2.1" },
      body: JSON.stringify({ padding: "x".repeat(3_000) })
    });
    expect(request.headers.get("content-length")).toBeNull();
    const response = await handleChallenge(request, routeDependencies(harness));
    expect(response.status).toBe(413);
    await expect(response.json()).resolves.toMatchObject({ error: { code: "payload_too_large" } });
  });

  it("exercises all three auth handlers without live Apple or database calls", async () => {
    const harness = makeHarness();
    const challengeResponse = await handleChallenge(jsonRequest("/v1/auth/app-attest/challenges", {
      schema_version: "1.0", purpose: "attestation", key_id: null
    }), routeDependencies(harness));
    const challenge = await challengeResponse.json() as ReturnType<typeof challengeShape>;
    const attestationResponse = await handleAttestation(jsonRequest("/v1/auth/app-attest/attestations", attestationRequest(challenge)), routeDependencies(harness));
    expect(attestationResponse.status).toBe(200);

    const assertion = await assertionChallenge(harness);
    harness.verifier.nextCounter = 1;
    const sessionResponse = await handleSession(jsonRequest("/v1/auth/app-attest/sessions", sessionRequest(assertion)), routeDependencies(harness));
    expect(sessionResponse.status).toBe(200);
  });

  it("rejects an arbitrary static bearer before provider invocation", async () => {
    const harness = makeHarness();
    let providerCalled = false;
    const response = await handleDailyEntry(jsonRequest("/v1/daily-entries", {}, {
      Authorization: "Bearer static-token"
    }), {
      auth: { config: harness.config, store: harness.store, now: baseTime },
      fetch: async () => { providerCalled = true; return new Response(); }
    });
    expect(response.status).toBe(401);
    expect(providerCalled).toBe(false);
  });
});

describe("App Attest authenticator extension compatibility", () => {
  it("accepts exactly one credential public-key object for legacy attestation data", () => {
    const legacy = attestationAuthenticatorData(false);
    expect(parseAttestationAuthenticatorExtensions(legacy)).toBeNull();
    expect(() => parseAttestationAuthenticatorExtensions(Buffer.concat([legacy, encodedExtraMap()])))
      .toThrow("invalid attestation extension encoding");
  });

  it("strictly parses iOS 27 attestation extensions", () => {
    expect(parseAttestationAuthenticatorExtensions(attestationAuthenticatorData(true))).toEqual({
      validationCategory: 4,
      bundleVersion: "1"
    });
  });

  it("accepts only the exact 37-byte legacy assertion form when ED is absent", () => {
    const legacy = Buffer.alloc(37);
    expect(parseAssertionAuthenticatorExtensions(legacy)).toBeNull();
    expect(() => parseAssertionAuthenticatorExtensions(Buffer.concat([legacy, encodedUnexpectedMap()])))
      .toThrow("unexpected assertion authenticator data");
  });

  it("requires and strictly parses extensions when assertion ED is set", () => {
    const missing = Buffer.alloc(37);
    missing[32] = 0x80;
    expect(() => parseAssertionAuthenticatorExtensions(missing)).toThrow("missing assertion extensions");

    const extensionData = Buffer.alloc(37);
    extensionData[32] = 0x80;
    const assertion = Buffer.concat([extensionData, encodedAppAttestExtensions()]);
    expect(parseAssertionAuthenticatorExtensions(assertion)).toEqual({ validationCategory: 4, bundleVersion: "1" });
  });
});

function attestationAuthenticatorData(hasExtensions: boolean): Buffer {
  const headerAndCredential = Buffer.alloc(87);
  headerAndCredential[32] = hasExtensions ? 0xc0 : 0x40;
  headerAndCredential.writeUInt16BE(32, 53);
  const publicKey = Buffer.from("a10102", "hex");
  return hasExtensions
    ? Buffer.concat([headerAndCredential, publicKey, encodedAppAttestExtensions()])
    : Buffer.concat([headerAndCredential, publicKey]);
}

function encodedAppAttestExtensions(): Buffer {
  return Buffer.from(
    "a2781c6170706c655f76616c69646174696f6e5f63617465676f72795f303104" +
    "776170706c655f62756e646c655f76657273696f6e5f30316131",
    "hex"
  );
}

function encodedExtraMap(): Buffer {
  return Buffer.from("a165657874726101", "hex");
}

function encodedUnexpectedMap(): Buffer {
  return Buffer.from("a16a756e6578706563746564f5", "hex");
}

class FakeVerifier implements AppAttestCryptographicVerifier {
  attestationCalls = 0;
  nextCounter = 1;
  failAttestation = false;
  attestationExtensions: { validationCategory: number | null; bundleVersion: string | null } | null = {
    validationCategory: 4,
    bundleVersion: "1"
  };
  assertionExtensions: { validationCategory: number | null; bundleVersion: string | null } | null = {
    validationCategory: 4,
    bundleVersion: "1"
  };

  async verifyAttestation(input: Parameters<AppAttestCryptographicVerifier["verifyAttestation"]>[0]): Promise<VerifiedAttestation> {
    this.attestationCalls += 1;
    if (this.failAttestation || input.config.bundleIdentifier !== "cascadianpines.lore" || input.config.environment !== "production") {
      throw new Error("policy mismatch");
    }
    return {
      publicKeyPem: "-----BEGIN PUBLIC KEY-----\ntest\n-----END PUBLIC KEY-----",
      receiptBase64: Buffer.from("receipt").toString("base64"),
      environment: "production",
      validationCategory: this.attestationExtensions?.validationCategory ?? null,
      bundleVersion: this.attestationExtensions?.bundleVersion ?? null
    };
  }

  async verifyAssertion(input: Parameters<AppAttestCryptographicVerifier["verifyAssertion"]>[0]): Promise<VerifiedAssertion> {
    return {
      counter: this.nextCounter,
      validationCategory: this.assertionExtensions?.validationCategory ?? null,
      bundleVersion: this.assertionExtensions?.bundleVersion ?? null
    };
  }
}

function makeHarness(overrides: {
  now?: () => Date;
  config?: AppAttestRuntimeConfig;
  store?: MemoryAuthStateStore;
} = {}) {
  const store = overrides.store ?? new MemoryAuthStateStore();
  const verifier = new FakeVerifier();
  const config = overrides.config ?? testConfig();
  let id = 0;
  const flow = new AppAttestFlow({
    config,
    store,
    verifier,
    now: overrides.now ?? (() => baseTime),
    randomChallenge: () => Buffer.alloc(32, ++id),
    randomId: () => `00000000-0000-4000-8000-${String(++id).padStart(12, "0")}`
  });
  return { flow, store, verifier, config };
}

class FailingOnceRegistrationStore extends MemoryAuthStateStore {
  private shouldFail = true;

  override async registerKeyWithChallenge(
    input: Parameters<MemoryAuthStateStore["registerKeyWithChallenge"]>[0]
  ): ReturnType<MemoryAuthStateStore["registerKeyWithChallenge"]> {
    if (this.shouldFail) {
      this.shouldFail = false;
      throw new Error("synthetic transaction failure");
    }
    return super.registerKeyWithChallenge(input);
  }
}

function testConfig(): AppAttestRuntimeConfig {
  return {
    teamIdentifier: "ABCDE12345",
    bundleIdentifier: "cascadianpines.lore",
    environment: "production",
    allowedValidationCategories: new Set([4]),
    sessionSigningSecret: "session-signing-secret-at-least-32-bytes",
    stateHmacSecret: "state-reference-secret-at-least-32-bytes",
    receiptEncryptionKey: Buffer.alloc(32, 9),
    databaseUrl: "postgresql://test.invalid/lore",
    sessionTtlSeconds: 600,
    challengeTtlSeconds: 300,
    processingLeaseTtlSeconds: 90
  };
}

async function register(harness: ReturnType<typeof makeHarness>) {
  const challenge = await harness.flow.issueChallenge({ purpose: "attestation", keyId: null, rateLimitIdentity: "network" });
  return harness.flow.attest(attestationRequest(challenge));
}

async function assertionChallenge(harness: ReturnType<typeof makeHarness>) {
  return harness.flow.issueChallenge({ purpose: "assertion", keyId, rateLimitIdentity: "network" });
}

function attestationRequest(challenge: { challenge_id: string; challenge: string }) {
  return {
    schema_version: "1.0" as const,
    challenge_id: challenge.challenge_id,
    challenge: challenge.challenge,
    key_id: keyId,
    attestation_object: Buffer.from("synthetic-attestation").toString("base64")
  };
}

function sessionRequest(challenge: { challenge_id: string; challenge: string }) {
  const clientData = {
    schema_version: "1.0",
    action: "create_session",
    challenge_id: challenge.challenge_id,
    challenge: challenge.challenge
  };
  return {
    schema_version: "1.0" as const,
    challenge_id: challenge.challenge_id,
    challenge: challenge.challenge,
    key_id: keyId,
    assertion_object: Buffer.from("synthetic-assertion").toString("base64"),
    client_data: Buffer.from(JSON.stringify(clientData)).toString("base64")
  };
}

function challengeShape() {
  return { schema_version: "1.0" as const, challenge_id: "", challenge: "", purpose: "attestation" as const, expires_at: "" };
}

function jsonRequest(path: string, body: unknown, headers: Record<string, string> = {}): Request {
  return new Request(`https://lore.invalid${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Forwarded-For": "192.0.2.1", ...headers },
    body: JSON.stringify(body)
  });
}

function routeDependencies(harness: ReturnType<typeof makeHarness>): {
  config: AppAttestRuntimeConfig;
  store: AuthStateStore;
  verifier: AppAttestCryptographicVerifier;
  now: () => Date;
  randomChallenge: () => Buffer;
  randomId: () => string;
} {
  let id = 100;
  return {
    config: harness.config,
    store: harness.store,
    verifier: harness.verifier,
    now: () => baseTime,
    randomChallenge: () => Buffer.alloc(32, ++id),
    randomId: () => `10000000-0000-4000-8000-${String(++id).padStart(12, "0")}`
  };
}
