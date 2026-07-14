export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly headers: Record<string, string> = {},
    readonly details: ApiErrorDetails = {},
  ) {
    super(message);
  }
}

export interface ApiErrorDetails {
  activeDeviceCount?: number;
  vaultId?: string;
  devices?: Array<Record<string, unknown>>;
}

export function json(data: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return Response.json(data, {
    status,
    headers: {
      "cache-control": "no-store",
      ...headers,
    },
  });
}

export function noContent(): Response {
  return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
}

export const MAX_JSON_BODY_BYTES = 2 * 1_024 * 1_024;

export async function readJson(request: Request, maxBytes = 1_048_576): Promise<unknown> {
  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    throw new ApiError(415, "unsupported_media_type", "Content-Type must be application/json");
  }
  const effectiveMaximum = Math.min(maxBytes, MAX_JSON_BODY_BYTES);
  const contentLength = request.headers.get("content-length");
  if (contentLength && /^\d+$/.test(contentLength) && Number(contentLength) > effectiveMaximum) {
    await request.body?.cancel().catch(() => undefined);
    throw new ApiError(413, "payload_too_large", "Request body is too large");
  }

  const reader = request.body?.getReader();
  if (!reader) throw new ApiError(400, "invalid_json", "Request body is not valid JSON");
  const chunks: Uint8Array[] = [];
  let byteCount = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      byteCount += value.byteLength;
      if (byteCount > effectiveMaximum) {
        await reader.cancel().catch(() => undefined);
        throw new ApiError(413, "payload_too_large", "Request body is too large");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const bytes = new Uint8Array(byteCount);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new ApiError(400, "invalid_json", "Request body is not valid UTF-8 JSON");
  }
  try {
    const value = JSON.parse(text) as unknown;
    validateRequestShape(request, value);
    return value;
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(400, "invalid_json", "Request body is not valid JSON");
  }
}

interface RequestShape {
  allowed: readonly string[];
  required: readonly string[];
}

function validateRequestShape(request: Request, value: unknown): void {
  const shape = requestShape(request.method, new URL(request.url).pathname.replace(/\/+$/, "") || "/");
  if (!shape || !value || typeof value !== "object" || Array.isArray(value)) return;
  const body = value as Record<string, unknown>;
  const allowed = new Set(shape.allowed);
  const unexpected = Object.keys(body).find((key) => !allowed.has(key));
  if (unexpected) throw new ApiError(400, "invalid_request", `${unexpected} is not allowed`);
  const missing = shape.required.find((key) => !Object.hasOwn(body, key));
  if (missing) throw new ApiError(400, "invalid_request", `${missing} is required`);
}

function requestShape(method: string, path: string): RequestShape | null {
  if (method !== "POST") return null;
  if (path === "/v1/vaults") {
    return exact(["vaultId", "deviceId", "deviceToken", "recoveryAuthToken", "encryptedDeviceProfile"]);
  }
  if (path === "/v1/pairing-sessions") return exact(["deviceId", "joiningPublicKey"]);
  if (/^\/v1\/pairing-sessions\/\d{6}\/join$/.test(path)) return exact(["approvingPublicKey"]);
  if (/^\/v1\/pairing-sessions\/[0-9a-f-]{36}\/approve$/i.test(path)) {
    return exact(["approvingPublicKey", "encryptedGrant", "newDeviceToken"]);
  }
  if (/^\/v1\/pairing-sessions\/[0-9a-f-]{36}\/complete$/i.test(path)) {
    return {
      allowed: ["completionToken", "encryptedDeviceProfile"],
      required: ["completionToken"],
    };
  }
  if (path === "/v1/recover") {
    return {
      allowed: ["recoveryAuthToken", "deviceId", "deviceToken", "replaceDeviceId"],
      required: ["recoveryAuthToken", "deviceId", "deviceToken"],
    };
  }
  if (path === "/v1/sync") {
    return {
      allowed: [
        "reason",
        "historyCursor",
        "currentSnapshot",
        "archives",
        "encryptedDeviceProfile",
        "bootstrapComplete",
      ],
      required: ["reason", "historyCursor", "archives"],
    };
  }
  return null;
}

function exact(properties: readonly string[]): RequestShape {
  return { allowed: properties, required: properties };
}

export function objectBody(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ApiError(400, "invalid_request", "Request body must be a JSON object");
  }
  return value as Record<string, unknown>;
}

export function isoTime(epochMs: number): string {
  return new Date(epochMs).toISOString();
}
