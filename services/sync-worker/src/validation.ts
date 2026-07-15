import { ApiError } from "./http";

export class RequestValidationError extends Error {}

export function requiredString(
  value: unknown,
  field: string,
  minimumLength = 1,
  maximumLength = 256,
): string {
  if (typeof value !== "string" || value.length < minimumLength || value.length > maximumLength) {
    throw new ApiError(400, "invalid_request", `${field} is invalid`);
  }
  return value;
}

export function optionalNonNegativeInteger(value: unknown, field: string, fallback = 0): number {
  if (value === undefined) return fallback;
  if (!Number.isSafeInteger(value) || (value as number) < 0) {
    throw new ApiError(400, "invalid_request", `${field} must be a non-negative safe integer`);
  }
  return value as number;
}

export function requiredNonNegativeInteger(value: unknown, field: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) {
    throw new ApiError(400, "invalid_request", `${field} must be a non-negative safe integer`);
  }
  return value as number;
}

export function optionalArray(value: unknown, field: string, maximumLength: number): unknown[] {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > maximumLength) {
    throw new ApiError(400, "invalid_request", `${field} must be an array with at most ${maximumLength} items`);
  }
  return value;
}

export function requiredArray(value: unknown, field: string, maximumLength: number): unknown[] {
  if (!Array.isArray(value) || value.length > maximumLength) {
    throw new ApiError(400, "invalid_request", `${field} must be an array with at most ${maximumLength} items`);
  }
  return value;
}

export function optionalBoolean(value: unknown, field: string, fallback: boolean): boolean {
  if (value === undefined) return fallback;
  if (typeof value !== "boolean") {
    throw new ApiError(400, "invalid_request", `${field} must be a boolean`);
  }
  return value;
}

export function assertExactProperties(
  value: Record<string, unknown>,
  field: string,
  allowedProperties: readonly string[],
): void {
  const allowed = new Set(allowedProperties);
  const unexpected = Object.keys(value).find((key) => !allowed.has(key));
  if (unexpected) {
    throw new ApiError(400, "invalid_request", `${field}.${unexpected} is not allowed`);
  }
}

export function validateSyncReason(value: unknown): "manual" | "automatic" | "bootstrap" | "pairing" | "recovery" {
  if (value === "manual" || value === "automatic" || value === "bootstrap" || value === "pairing" || value === "recovery") {
    return value;
  }
  throw new ApiError(400, "invalid_request", "reason is invalid");
}

export function validator<T>(operation: () => T): T {
  try {
    return operation();
  } catch (error) {
    if (error instanceof ApiError) throw error;
    if (error instanceof RequestValidationError) {
      throw new ApiError(400, "invalid_request", error.message);
    }
    throw error;
  }
}

export async function validatorAsync<T>(operation: () => Promise<T>): Promise<T> {
  try {
    return await operation();
  } catch (error) {
    if (error instanceof ApiError) throw error;
    if (error instanceof RequestValidationError) {
      throw new ApiError(400, "invalid_request", error.message);
    }
    throw error;
  }
}

export function canonicalJson(value: unknown): string {
  return JSON.stringify(canonicalValue(value));
}

function canonicalValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (value !== null && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, item]) => [key, canonicalValue(item)] as const);
    return Object.fromEntries(entries);
  }
  return value;
}
