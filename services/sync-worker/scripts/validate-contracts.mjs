import assert from "node:assert/strict";
import {
  createCipheriv,
  createHash,
  createHmac,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  hkdfSync,
} from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import { parse as parseYaml } from "yaml";

const workerDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const contractDirectory = resolve(workerDirectory, "../../contracts/sync/v1");
const readJson = (relativePath) => JSON.parse(readFileSync(join(contractDirectory, relativePath), "utf8"));

const coreSchema = readJson("core-day-snapshot.schema.json");
const encryptedRecordSchema = readJson("encrypted-record.schema.json");
const apiSchema = readJson("api.schema.json");
const vectors = readJson("fixtures/crypto-vectors.json");
const normalization = readJson("fixtures/key-canonicalization.json");
const openApi = parseYaml(readFileSync(join(contractDirectory, "openapi.yaml"), "utf8"));

const ajv = new Ajv2020({ allErrors: true, strict: true });
ajv.addFormat("uuid", /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i);
ajv.addFormat("date", {
  type: "string",
  validate: isGregorianDate,
});
ajv.addFormat("date-time", {
  type: "string",
  validate: (value) => typeof value === "string" && Number.isFinite(Date.parse(value)) && /(?:Z|[+-][0-9]{2}:[0-9]{2})$/.test(value),
});
ajv.addSchema(encryptedRecordSchema);
ajv.addSchema(coreSchema);
ajv.addSchema(apiSchema);

const validateCore = ajv.getSchema(coreSchema.$id);
const validateRecord = ajv.getSchema(encryptedRecordSchema.$id);
const validateApiDefinitions = ajv.getSchema(apiSchema.$id);
assert(validateCore, "core snapshot schema did not compile");
assert(validateRecord, "encrypted record schema did not compile");
assert(validateApiDefinitions, "API definitions schema did not compile");
assert(validateCore(vectors.record.snapshot), ajv.errorsText(validateCore.errors));
assert(
  validateRecord({
    schemaVersion: 1,
    recordId: vectors.record.recordId,
    deviceId: vectors.record.deviceId,
    revision: vectors.record.revision,
    nonce: vectors.record.nonceBase64,
    ciphertext: vectors.record.ciphertextBase64,
    tag: vectors.record.tagBase64,
    ciphertextHash: vectors.record.ciphertextHashBase64Url,
  }),
  ajv.errorsText(validateRecord.errors),
);
validateSyncRequestSchema(ajv, apiSchema, vectors);

validateOpenApi(openApi);
validateNormalizationFixtures(normalization);
recomputeGoldenVectors(vectors);

console.log("Validated sync v1 JSON Schemas, OpenAPI contract, normalization fixtures, and cryptographic golden vectors.");

function validateOpenApi(document) {
  assert.equal(document.openapi, "3.1.0");
  assert(document.paths && document.components?.schemas && document.components?.responses);
  const requiredOperations = {
    "/v1/vaults": ["post"],
    "/v1/pairing-sessions": ["post"],
    "/v1/pairing-sessions/{code}/join": ["post"],
    "/v1/pairing-sessions/{sessionId}/approve": ["post"],
    "/v1/pairing-sessions/{sessionId}/complete": ["post"],
    "/v1/recover": ["post"],
    "/v1/sync": ["post"],
    "/v1/history": ["get"],
    "/v1/devices/{deviceId}": ["delete"],
    "/v1/vault": ["delete"],
  };
  for (const [path, methods] of Object.entries(requiredOperations)) {
    assert(document.paths[path], `OpenAPI is missing ${path}`);
    for (const method of methods) {
      assert(document.paths[path][method]?.responses, `OpenAPI is missing ${method.toUpperCase()} ${path}`);
    }
  }
  walkReferences(document, document);
  const protectedOperations = [
    ["/v1/pairing-sessions/{code}/join", "post"],
    ["/v1/pairing-sessions/{sessionId}/approve", "post"],
    ["/v1/sync", "post"],
    ["/v1/history", "get"],
    ["/v1/devices/{deviceId}", "delete"],
    ["/v1/vault", "delete"],
  ];
  for (const [path, method] of protectedOperations) {
    const security = document.paths[path][method].security;
    assert(Array.isArray(security) && security.some((entry) => Object.hasOwn(entry, "deviceToken")), `${method} ${path} must require a device token`);
  }
}

function validateSyncRequestSchema(schemaValidator, schema, fixture) {
  const validateSyncRequest = schemaValidator.compile({ $ref: `${schema.$id}#/$defs/syncRequest` });
  const record = {
    schemaVersion: 1,
    recordId: fixture.record.recordId,
    deviceId: fixture.record.deviceId,
    revision: fixture.record.revision,
    nonce: fixture.record.nonceBase64,
    ciphertext: fixture.record.ciphertextBase64,
    tag: fixture.record.tagBase64,
    ciphertextHash: fixture.record.ciphertextHashBase64Url,
  };
  assert(validateSyncRequest({ reason: "bootstrap", historyCursor: 0, archives: [record], bootstrapComplete: false }));
  assert(!validateSyncRequest({ reason: "bootstrap", archives: [] }), "sync historyCursor must be required");
  assert(!validateSyncRequest({ reason: "bootstrap", historyCursor: 0 }), "sync archives must be required");
  assert(!validateSyncRequest({ reason: "bootstrap", historyCursor: 0, archives: [], unknown: true }), "sync properties must be closed");
  assert(!validateSyncRequest({ reason: "bootstrap", historyCursor: 0, archives: Array(17).fill(record) }), "sync archives must be capped at 16");
  assert(!validateSyncRequest({
    reason: "bootstrap",
    historyCursor: 0,
    archives: [{ ...record, revision: Number.MAX_SAFE_INTEGER + 1 }],
  }), "record revisions must remain JSON-safe integers");
}

function walkReferences(value, root) {
  if (Array.isArray(value)) {
    for (const item of value) walkReferences(item, root);
    return;
  }
  if (!value || typeof value !== "object") return;
  if (typeof value.$ref === "string") {
    if (value.$ref.startsWith("#/")) {
      let target = root;
      for (const rawPart of value.$ref.slice(2).split("/")) {
        const part = rawPart.replaceAll("~1", "/").replaceAll("~0", "~");
        assert(Object.hasOwn(target, part), `Unresolved OpenAPI reference ${value.$ref}`);
        target = target[part];
      }
    } else if (value.$ref.startsWith("./")) {
      const [relativeFile] = value.$ref.split("#", 1);
      JSON.parse(readFileSync(join(contractDirectory, relativeFile), "utf8"));
    } else {
      assert.fail(`Unexpected remote OpenAPI reference ${value.$ref}`);
    }
  }
  for (const child of Object.values(value)) walkReferences(child, root);
}

function validateNormalizationFixtures(fixture) {
  assert.equal(fixture.schemaVersion, 1);
  assert.equal(fixture.separator, "+");
  assert(Array.isArray(fixture.cases) && fixture.cases.length >= 20);
  for (const testCase of fixture.cases) {
    assert(["mac", "windows"].includes(testCase.platform));
    assert.equal(typeof testCase.input, "string");
    assert.equal(typeof testCase.expected, "string");
    assert(Buffer.byteLength(testCase.expected, "utf8") <= 64, `fixture key exceeds 64 bytes: ${testCase.expected}`);
  }
  for (const day of fixture.validLocalDays) assert(isGregorianDate(day), `expected valid date: ${day}`);
  for (const day of fixture.invalidLocalDays) assert(!isGregorianDate(day), `expected invalid date: ${day}`);
}

function recomputeGoldenVectors(fixture) {
  const seed = Buffer.from(fixture.recovery.seedHex, "hex");
  assert.equal(seed.length, 16);
  assert.equal(seed.toString("base64"), fixture.recovery.seedBase64);
  const recoveryCode = encodeRecoveryCode(seed, fixture.recovery.checksumDomainUtf8);
  assert.equal(recoveryCode, fixture.recovery.code);
  assert.equal(recoveryCode.match(/.{1,4}/g).join("-"), fixture.recovery.formattedCode);

  const encryptionKey = hkdf(seed, fixture.derivedKeys.encryptionInfoUtf8);
  const recordIndexKey = hkdf(seed, fixture.derivedKeys.recordIndexInfoUtf8);
  const recoveryAuthKey = hkdf(seed, fixture.derivedKeys.recoveryAuthInfoUtf8);
  assert.equal(encryptionKey.toString("hex"), fixture.derivedKeys.encryptionKeyHex);
  assert.equal(recordIndexKey.toString("hex"), fixture.derivedKeys.recordIndexKeyHex);
  assert.equal(recoveryAuthKey.toString("hex"), fixture.derivedKeys.recoveryAuthKeyHex);
  assert.equal(base64Url(recoveryAuthKey), fixture.derivedKeys.recoveryCredentialBase64Url);

  const record = fixture.record;
  const canonicalPlaintext = stableStringify(record.snapshot);
  assert.equal(canonicalPlaintext, record.plaintextUtf8);
  const indexInput = `${record.deviceId}\n${record.localDay}`;
  assert.equal(indexInput, record.recordIndexInputUtf8);
  const recordId = base64Url(createHmac("sha256", recordIndexKey).update(indexInput).digest());
  assert.equal(recordId, record.recordId);
  const aad = `1\n${record.vaultId}\n${record.deviceId}\n${record.recordId}\n${record.revision}`;
  assert.equal(aad, record.aadUtf8);
  assert.equal(Buffer.from(aad).toString("base64"), record.aadBase64);
  const encrypted = aesGcmEncrypt(
    encryptionKey,
    Buffer.from(record.nonceBase64, "base64"),
    Buffer.from(canonicalPlaintext),
    Buffer.from(aad),
  );
  assert.equal(encrypted.ciphertext.toString("base64"), record.ciphertextBase64);
  assert.equal(encrypted.tag.toString("base64"), record.tagBase64);
  assert.equal(
    base64Url(sha256(Buffer.concat([Buffer.from(record.nonceBase64, "base64"), encrypted.ciphertext, encrypted.tag]))),
    record.ciphertextHashBase64Url,
  );

  const pairing = fixture.pairing;
  const joiningPrivateKey = x25519PrivateKey(Buffer.from(pairing.joiningPrivateKeyHex, "hex"));
  const approvingPrivateKey = x25519PrivateKey(Buffer.from(pairing.approvingPrivateKeyHex, "hex"));
  const joiningPublicKey = rawX25519PublicKey(joiningPrivateKey);
  const approvingPublicKey = rawX25519PublicKey(approvingPrivateKey);
  assert.equal(joiningPublicKey.toString("base64"), pairing.joiningPublicKeyBase64);
  assert.equal(approvingPublicKey.toString("base64"), pairing.approvingPublicKeyBase64);
  const sharedSecret = diffieHellman({ privateKey: joiningPrivateKey, publicKey: createPublicKey(approvingPrivateKey) });
  assert.equal(sharedSecret.toString("hex"), pairing.sharedSecretHex);
  const orderedPublicKeys = [joiningPublicKey, approvingPublicKey].sort(Buffer.compare);
  const safetyDigest = sha256(Buffer.concat([
    Buffer.from(pairing.safetyTranscriptPrefixUtf8),
    ...orderedPublicKeys,
    sharedSecret,
  ]));
  assert.equal(String(safetyDigest.readUInt32BE(0) % 1_000_000).padStart(6, "0"), pairing.safetyCode);
  const wrapKey = hkdf(sharedSecret, pairing.wrapInfoUtf8);
  assert.equal(wrapKey.toString("hex"), pairing.wrapKeyHex);
  const grantPlaintext = stableStringify(pairing.grant);
  assert.equal(grantPlaintext, pairing.plaintextUtf8);
  const pairingAad = `1\n${pairing.sessionId}`;
  assert.equal(pairingAad, pairing.aadUtf8);
  const encryptedGrant = aesGcmEncrypt(
    wrapKey,
    Buffer.from(pairing.nonceBase64, "base64"),
    Buffer.from(grantPlaintext),
    Buffer.from(pairingAad),
  );
  assert.equal(encryptedGrant.ciphertext.toString("base64"), pairing.ciphertextBase64);
  assert.equal(encryptedGrant.tag.toString("base64"), pairing.tagBase64);
}

function hkdf(inputKeyMaterial, info) {
  return Buffer.from(hkdfSync("sha256", inputKeyMaterial, Buffer.alloc(0), Buffer.from(info), 32));
}

function sha256(value) {
  return createHash("sha256").update(value).digest();
}

function base64Url(value) {
  return Buffer.from(value).toString("base64url");
}

function aesGcmEncrypt(key, nonce, plaintext, aad) {
  assert.equal(nonce.length, 12);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  cipher.setAAD(aad);
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return { ciphertext, tag: cipher.getAuthTag() };
}

function x25519PrivateKey(rawKey) {
  assert.equal(rawKey.length, 32);
  const pkcs8Prefix = Buffer.from("302e020100300506032b656e04220420", "hex");
  return createPrivateKey({ key: Buffer.concat([pkcs8Prefix, rawKey]), format: "der", type: "pkcs8" });
}

function rawX25519PublicKey(privateKey) {
  const spki = createPublicKey(privateKey).export({ format: "der", type: "spki" });
  return Buffer.from(spki).subarray(-32);
}

function stableStringify(value) {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function encodeRecoveryCode(seed, checksumDomain) {
  const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
  let payload = "";
  let accumulator = 0;
  let bitCount = 0;
  for (const byte of seed) {
    accumulator = (accumulator << 8) | byte;
    bitCount += 8;
    while (bitCount >= 5) {
      bitCount -= 5;
      payload += alphabet[(accumulator >> bitCount) & 31];
      accumulator &= (1 << bitCount) - 1;
    }
  }
  if (bitCount > 0) payload += alphabet[(accumulator << (5 - bitCount)) & 31];
  payload = payload.slice(0, 26);
  const digest = sha256(Buffer.concat([Buffer.from(checksumDomain), seed]));
  const checksumValue = (digest[0] << 2) | (digest[1] >> 6);
  return payload + alphabet[(checksumValue >> 5) & 31] + alphabet[checksumValue & 31];
}

function isGregorianDate(value) {
  if (typeof value !== "string" || !/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(value)) return false;
  const [year, month, day] = value.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day;
}
