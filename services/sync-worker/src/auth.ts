import { keyedHash } from "./crypto";
import { hourlyRateLimitsEnabled, type Env } from "./env";
import { ApiError } from "./http";
import type { AuthContext, DeviceRow, VaultRow } from "./types";

interface AuthQueryRow extends DeviceRow {
  recovery_auth_hash: string;
  vault_created_at: number;
  vault_deleted_at: number | null;
  changes_pruned_through: number;
}

interface RateLimitRow {
  request_count: number;
  window_started_at: number;
}

export async function authenticate(request: Request, env: Env): Promise<AuthContext> {
  const authorization = request.headers.get("authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) {
    throw new ApiError(401, "authentication_required", "A device bearer token is required", {
      "www-authenticate": "Bearer",
    });
  }
  const token = authorization.slice(7);
  if (token.length < 40 || token.length > 160 || token.includes("\n")) {
    throw new ApiError(401, "invalid_token", "The device token is invalid");
  }
  const tokenHash = await keyedHash(env.TOKEN_HASH_KEY, `device-token:${token}`);
  const row = await env.DB.prepare(
    `SELECT d.*,
            v.recovery_auth_hash,
            v.created_at AS vault_created_at,
            v.deleted_at AS vault_deleted_at,
            v.changes_pruned_through
       FROM devices d
       JOIN vaults v ON v.id = d.vault_id
      WHERE d.token_hash = ?1
      LIMIT 1`,
  ).bind(tokenHash).first<AuthQueryRow>();
  if (!row || row.revoked_at !== null || row.vault_deleted_at !== null) {
    throw new ApiError(401, "invalid_token", "The device token is invalid");
  }
  const vault: VaultRow = {
    id: row.vault_id,
    recovery_auth_hash: row.recovery_auth_hash,
    created_at: row.vault_created_at,
    deleted_at: row.vault_deleted_at,
    changes_pruned_through: row.changes_pruned_through,
  };
  const device: DeviceRow = {
    id: row.id,
    vault_id: row.vault_id,
    profile_nonce: row.profile_nonce,
    profile_ciphertext: row.profile_ciphertext,
    profile_tag: row.profile_tag,
    token_hash: row.token_hash,
    created_at: row.created_at,
    last_seen_at: row.last_seen_at,
    revoked_at: row.revoked_at,
    bootstrap_consumed_at: row.bootstrap_consumed_at,
    last_sync_at: row.last_sync_at,
    sync_utc_day: row.sync_utc_day,
    sync_count: row.sync_count,
    current_record_id: row.current_record_id,
    current_revision: row.current_revision,
    current_nonce: row.current_nonce,
    current_ciphertext: row.current_ciphertext,
    current_tag: row.current_tag,
    current_ciphertext_hash: row.current_ciphertext_hash,
    current_updated_at: row.current_updated_at,
    last_idempotency_key: row.last_idempotency_key,
    last_idempotency_hash: row.last_idempotency_hash,
    last_idempotency_at: row.last_idempotency_at,
  };
  return { device, vault };
}

export async function enforceHourlyLimit(
  request: Request,
  env: Env,
  endpoint: string,
  limit: number,
  now: number,
  extraScope = "",
): Promise<void> {
  if (!hourlyRateLimitsEnabled(env)) return;
  const address = request.headers.get("cf-connecting-ip") ?? "unknown";
  const keyHash = await keyedHash(env.TOKEN_HASH_KEY, `rate-limit:${endpoint}:${address}:${extraScope}`);
  const windowFloor = now - 3_600_000;
  const row = await env.DB.prepare(
    `INSERT INTO rate_limits(key_hash, endpoint, window_started_at, request_count)
     VALUES (?1, ?2, ?3, 1)
     ON CONFLICT(key_hash, endpoint) DO UPDATE SET
       window_started_at = CASE
         WHEN rate_limits.window_started_at <= ?4 THEN excluded.window_started_at
         ELSE rate_limits.window_started_at
       END,
       request_count = CASE
         WHEN rate_limits.window_started_at <= ?4 THEN 1
         ELSE rate_limits.request_count + 1
       END
     WHERE rate_limits.window_started_at <= ?4
        OR rate_limits.request_count < ?5
     RETURNING request_count, window_started_at`,
  ).bind(keyHash, endpoint, now, windowFloor, limit).first<RateLimitRow>();
  if (!row) {
    const blocked = await env.DB.prepare(
      "SELECT request_count, window_started_at FROM rate_limits WHERE key_hash = ?1 AND endpoint = ?2",
    ).bind(keyHash, endpoint).first<RateLimitRow>();
    if (!blocked) throw new Error("Rate limit state disappeared");
    const retryAt = blocked.window_started_at + 3_600_000;
    const retryAfter = Math.max(1, Math.ceil((retryAt - now) / 1_000));
    throw new ApiError(429, "rate_limited", "Too many requests", {
      "retry-after": String(retryAfter),
      "x-ratelimit-reset": new Date(retryAt).toISOString(),
    });
  }
}

export async function activeDeviceCount(env: Env, vaultId: string): Promise<number> {
  const row = await env.DB.prepare(
    "SELECT COUNT(*) AS count FROM devices WHERE vault_id = ?1 AND revoked_at IS NULL",
  ).bind(vaultId).first<{ count: number }>();
  return Number(row?.count ?? 0);
}
