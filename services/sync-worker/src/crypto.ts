import type { EncryptedEnvelope, EncryptedRecord } from "./types";
import { RequestValidationError } from "./validation";

const encoder = new TextEncoder();
const SHA256_BASE64URL_RE = /^[A-Za-z0-9_-]{43}$/;
const BASE64_RE = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

export function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export function randomSecret(byteCount = 32): string {
  return bytesToBase64Url(crypto.getRandomValues(new Uint8Array(byteCount)));
}

export function validateDeviceToken(value: unknown, expectedDeviceId: string, field = "deviceToken"): string {
  if (typeof value !== "string" || value.length > 160 || value.includes("\n")) {
    throw new RequestValidationError(`${field} is not a valid device token`);
  }
  const separator = value.indexOf(".");
  if (separator <= 0 || value.indexOf(".", separator + 1) !== -1) {
    throw new RequestValidationError(`${field} is not a valid device token`);
  }
  const tokenDeviceId = value.slice(0, separator);
  const secret = value.slice(separator + 1);
  if (tokenDeviceId.toLowerCase() !== expectedDeviceId.toLowerCase() || !SHA256_BASE64URL_RE.test(secret)) {
    throw new RequestValidationError(`${field} must be bound to deviceId`);
  }
  return value;
}

export function decodeBase64(value: unknown, field: string, maxBytes: number): Uint8Array {
  if (typeof value !== "string" || value.length === 0 || value.length > Math.ceil(maxBytes / 3) * 4 + 4) {
    throw new RequestValidationError(`${field} is not a valid base64 value`);
  }
  if (!BASE64_RE.test(value)) throw new RequestValidationError(`${field} is not canonical base64`);
  let binary: string;
  try {
    binary = atob(value);
  } catch {
    throw new RequestValidationError(`${field} is not valid base64`);
  }
  if (binary.length > maxBytes) throw new RequestValidationError(`${field} exceeds ${maxBytes} bytes`);
  const output = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) output[index] = binary.charCodeAt(index);
  if (bytesToBase64(output) !== value) throw new RequestValidationError(`${field} is not canonical base64`);
  return output;
}

export function validateEnvelope(value: unknown, field = "envelope", maxCiphertextBytes = 16_384): EncryptedEnvelope {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new RequestValidationError(`${field} must be an object`);
  }
  const candidate = value as Record<string, unknown>;
  assertExactKeys(candidate, field, ["nonce", "ciphertext", "tag"]);
  const nonce = decodeBase64(candidate.nonce, `${field}.nonce`, 12);
  if (nonce.length !== 12) throw new RequestValidationError(`${field}.nonce must decode to 12 bytes`);
  const ciphertext = decodeBase64(candidate.ciphertext, `${field}.ciphertext`, maxCiphertextBytes);
  if (ciphertext.length === 0) throw new RequestValidationError(`${field}.ciphertext cannot be empty`);
  const tag = decodeBase64(candidate.tag, `${field}.tag`, 16);
  if (tag.length !== 16) throw new RequestValidationError(`${field}.tag must decode to 16 bytes`);
  return {
    nonce: candidate.nonce as string,
    ciphertext: candidate.ciphertext as string,
    tag: candidate.tag as string,
  };
}

export async function sha256Hex(input: Uint8Array | string): Promise<string> {
  const bytes = typeof input === "string" ? encoder.encode(input) : input;
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", ownedBuffer(bytes)));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function sha256Base64Url(input: Uint8Array | string): Promise<string> {
  const bytes = typeof input === "string" ? encoder.encode(input) : input;
  return bytesToBase64Url(new Uint8Array(await crypto.subtle.digest("SHA-256", ownedBuffer(bytes))));
}

function ownedBuffer(bytes: Uint8Array): ArrayBuffer {
  return Uint8Array.from(bytes).buffer;
}

export async function keyedHash(pepper: string, value: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(pepper),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(value)));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function timingSafeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

export async function validateRecord(value: unknown, expectedDeviceId: string): Promise<EncryptedRecord> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new RequestValidationError("record must be an object");
  }
  const candidate = value as Record<string, unknown>;
  assertExactKeys(candidate, "record", [
    "schemaVersion",
    "recordId",
    "deviceId",
    "revision",
    "nonce",
    "ciphertext",
    "tag",
    "ciphertextHash",
  ]);
  if (candidate.schemaVersion !== 1) throw new RequestValidationError("record.schemaVersion must equal 1");
  if (typeof candidate.recordId !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(candidate.recordId)) {
    throw new RequestValidationError("record.recordId must be an opaque base64url identifier");
  }
  if (candidate.deviceId !== expectedDeviceId) {
    throw new RequestValidationError("record.deviceId must match the authenticated device");
  }
  if (!Number.isSafeInteger(candidate.revision) || (candidate.revision as number) < 1) {
    throw new RequestValidationError("record.revision must be a positive safe integer");
  }
  const envelope = validateEnvelope({
    nonce: candidate.nonce,
    ciphertext: candidate.ciphertext,
    tag: candidate.tag,
  }, "record", 65_536);
  if (typeof candidate.ciphertextHash !== "string" || !SHA256_BASE64URL_RE.test(candidate.ciphertextHash)) {
    throw new RequestValidationError("record.ciphertextHash must be a base64url SHA-256 digest without padding");
  }
  const nonce = decodeBase64(envelope.nonce, "record.nonce", 12);
  const ciphertext = decodeBase64(envelope.ciphertext, "record.ciphertext", 65_536);
  const tag = decodeBase64(envelope.tag, "record.tag", 16);
  const combined = new Uint8Array(nonce.length + ciphertext.length + tag.length);
  combined.set(nonce, 0);
  combined.set(ciphertext, nonce.length);
  combined.set(tag, nonce.length + ciphertext.length);
  const computedHash = await sha256Base64Url(combined);
  if (!timingSafeEqual(computedHash, candidate.ciphertextHash)) {
    throw new RequestValidationError("record.ciphertextHash does not match nonce || ciphertext || tag");
  }
  return {
    schemaVersion: 1,
    recordId: candidate.recordId,
    deviceId: expectedDeviceId,
    revision: candidate.revision as number,
    ...envelope,
    ciphertextHash: computedHash,
  };
}

export function validateRawPublicKey(value: unknown, field: string): string {
  const key = decodeBase64(value, field, 32);
  if (key.length !== 32) {
    throw new RequestValidationError(`${field} must decode to a raw 32-byte X25519 public key`);
  }
  return value as string;
}

export function validateRecoveryAuthToken(value: unknown): string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(value)) {
    throw new RequestValidationError("recoveryAuthToken must be a base64url-encoded 32-byte value without padding");
  }
  return value;
}

export function validateUuid(value: unknown, field: string): string {
  if (typeof value !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw new RequestValidationError(`${field} must be a UUID`);
  }
  return value.toLowerCase();
}

function assertExactKeys(candidate: Record<string, unknown>, field: string, allowedKeys: readonly string[]): void {
  const allowed = new Set(allowedKeys);
  const unexpected = Object.keys(candidate).find((key) => !allowed.has(key));
  if (unexpected) throw new RequestValidationError(`${field}.${unexpected} is not allowed`);
}
