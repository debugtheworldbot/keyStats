import { activeDeviceCount, authenticate, enforceHourlyLimit } from "./auth";
import {
  keyedHash,
  randomSecret,
  sha256Base64Url,
  validateDeviceToken,
  validateEnvelope,
  validateRawPublicKey,
  validateRecoveryAuthToken,
  validateUuid,
} from "./crypto";
import type { Env } from "./env";
import { limits, syncEnabled } from "./env";
import { ApiError, isoTime, json, noContent, objectBody, readJson } from "./http";
import { currentRecord, readHistoryPage, storeHistoryRecords } from "./history";
import { handleSync } from "./sync";
import type { DeviceRow, EncryptedEnvelope, PairingRow, VaultRow } from "./types";
import { canonicalJson, requiredString, validator } from "./validation";

const PAIRING_TTL_MS = 10 * 60 * 1_000;
const VAULT_DELETION_RECEIPT_TTL_MS = 30 * 24 * 60 * 60 * 1_000;

export async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const path = normalizedPath(url.pathname);
  const now = Date.now();

  if (path === "/healthz" && request.method === "GET") {
    return json({ ok: true, syncEnabled: syncEnabled(env), serverTime: isoTime(now) });
  }
  const deletionRequest = request.method === "DELETE" && (path === "/v1/vault" || path.startsWith("/v1/devices/"));
  if (!syncEnabled(env) && !deletionRequest) {
    throw new ApiError(503, "sync_disabled", "The sync service is temporarily disabled", { "retry-after": "3600" });
  }

  if (path === "/v1/vaults" && request.method === "POST") return createVault(request, env, now);
  if (path === "/v1/pairing-sessions" && request.method === "POST") return createPairingSession(request, env, now);
  if (path === "/v1/recover" && request.method === "POST") return recoverVault(request, env, now);
  if (path === "/v1/state" && request.method === "GET") return state(request, env, now);
  if (path === "/v1/sync" && request.method === "POST") return sync(request, env, now);
  if (path === "/v1/history" && request.method === "GET") return history(request, env);
  if (path === "/v1/vault" && request.method === "DELETE") return deleteVault(request, env, now);

  const joinMatch = path.match(/^\/v1\/pairing-sessions\/(\d{6})\/join$/);
  if (joinMatch && request.method === "POST") return joinPairingSession(request, env, joinMatch[1]!, now);
  const approveMatch = path.match(/^\/v1\/pairing-sessions\/([0-9a-f-]{36})\/approve$/i);
  if (approveMatch && request.method === "POST") return approvePairingSession(request, env, approveMatch[1]!, now);
  const completeMatch = path.match(/^\/v1\/pairing-sessions\/([0-9a-f-]{36})\/complete$/i);
  if (completeMatch && request.method === "POST") return completePairingSession(request, env, completeMatch[1]!, now);
  const deviceMatch = path.match(/^\/v1\/devices\/([0-9a-f-]{36})$/i);
  if (deviceMatch && request.method === "DELETE") return deleteDevice(request, env, deviceMatch[1]!, now);

  throw new ApiError(404, "not_found", "The requested endpoint does not exist");
}

async function createVault(request: Request, env: Env, now: number): Promise<Response> {
  const body = objectBody(await readJson(request, 32_768));
  const vaultId = validator(() => validateUuid(body.vaultId, "vaultId"));
  const deviceId = validator(() => validateUuid(body.deviceId, "deviceId"));
  const deviceToken = validator(() => validateDeviceToken(body.deviceToken, deviceId));
  const recoveryAuthToken = validator(() => validateRecoveryAuthToken(body.recoveryAuthToken));
  const profile = validator(() => validateEnvelope(body.encryptedDeviceProfile, "encryptedDeviceProfile", 2_048));
  const recoveryHash = await keyedHash(env.TOKEN_HASH_KEY, `recovery:${recoveryAuthToken}`);
  const tokenHash = await keyedHash(env.TOKEN_HASH_KEY, `device-token:${deviceToken}`);
  const replay = await isExactVaultCreationReplay(env, vaultId, deviceId, recoveryHash, tokenHash, profile);
  if (replay) return createVaultResponse(vaultId, deviceId, deviceToken, now);

  await enforceHourlyLimit(request, env, "vault_create", 5, now);
  const collision = await env.DB.prepare(
    `SELECT 1 AS present
       FROM vaults
      WHERE id = ?1 OR recovery_auth_hash = ?2
      UNION ALL
     SELECT 1 AS present
       FROM devices
      WHERE id = ?3 OR token_hash = ?4
      LIMIT 1`,
  ).bind(vaultId, recoveryHash, deviceId, tokenHash).first<{ present: number }>();
  if (collision) throw new ApiError(409, "vault_conflict", "The vault or recovery credential already exists");
  try {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO vaults(id, recovery_auth_hash, created_at) VALUES (?1, ?2, ?3)",
      ).bind(vaultId, recoveryHash, now),
      env.DB.prepare(
        `INSERT INTO devices(
           id, vault_id, profile_nonce, profile_ciphertext, profile_tag, token_hash, created_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
      ).bind(deviceId, vaultId, profile.nonce, profile.ciphertext, profile.tag, tokenHash, now),
    ]);
  } catch {
    if (await isExactVaultCreationReplay(env, vaultId, deviceId, recoveryHash, tokenHash, profile)) {
      return createVaultResponse(vaultId, deviceId, deviceToken, now);
    }
    throw new ApiError(409, "vault_conflict", "The vault or recovery credential already exists");
  }
  return createVaultResponse(vaultId, deviceId, deviceToken, now);
}

async function createPairingSession(request: Request, env: Env, now: number): Promise<Response> {
  await enforceHourlyLimit(request, env, "pairing_create", 5, now);
  const body = objectBody(await readJson(request, 16_384));
  const pendingDeviceId = validator(() => validateUuid(body.deviceId, "deviceId"));
  const joiningPublicKey = validator(() => validateRawPublicKey(body.joiningPublicKey, "joiningPublicKey"));
  const existingSession = await env.DB.prepare(
    "SELECT 1 AS present FROM pairing_sessions WHERE pending_device_id = ?1 AND status IN ('waiting', 'joined', 'approved') LIMIT 1",
  ).bind(pendingDeviceId).first<{ present: number }>();
  if (existingSession) throw new ApiError(409, "pairing_exists", "A pairing session already exists for this device");

  const sessionId = crypto.randomUUID();
  const completionToken = randomSecret(32);
  const completionTokenHash = await keyedHash(env.TOKEN_HASH_KEY, `pairing-completion:${completionToken}`);
  const expiresAt = now + PAIRING_TTL_MS;
  let code = "";
  let inserted = false;
  for (let attempt = 0; attempt < 8 && !inserted; attempt += 1) {
    code = randomPairingCode();
    const codeHash = await keyedHash(env.TOKEN_HASH_KEY, `pairing-code:${code}`);
    try {
      await env.DB.prepare(
        `INSERT INTO pairing_sessions(
           id, code_hash, pending_device_id, joining_public_key,
           completion_token_hash, status, created_at, expires_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, 'waiting', ?6, ?7)`,
      ).bind(sessionId, codeHash, pendingDeviceId, joiningPublicKey, completionTokenHash, now, expiresAt).run();
      inserted = true;
    } catch (error) {
      if (attempt === 7) throw error;
    }
  }
  return json({ sessionId, code, completionToken, expiresAt: isoTime(expiresAt) }, 201);
}

async function joinPairingSession(
  request: Request,
  env: Env,
  code: string,
  now: number,
): Promise<Response> {
  await enforceHourlyLimit(request, env, "pairing_join", 5, now);
  const auth = await authenticate(request, env);
  const body = objectBody(await readJson(request, 16_384));
  const approvingPublicKey = validator(() => validateRawPublicKey(body.approvingPublicKey, "approvingPublicKey"));
  const codeHash = await keyedHash(env.TOKEN_HASH_KEY, `pairing-code:${code}`);
  const session = await env.DB.prepare("SELECT * FROM pairing_sessions WHERE code_hash = ?1 LIMIT 1")
    .bind(codeHash).first<PairingRow>();
  if (!session) throw new ApiError(404, "pairing_not_found", "The pairing session was not found");
  if (session.expires_at <= now) {
    await env.DB.prepare("UPDATE pairing_sessions SET status = 'expired' WHERE id = ?1").bind(session.id).run();
    throw new ApiError(410, "pairing_expired", "The pairing session has expired");
  }
  if (session.pending_device_id === auth.device.id) {
    throw new ApiError(409, "same_device_pairing", "A device cannot pair with itself");
  }
  if (session.status === "joined" && session.approver_device_id === auth.device.id &&
      session.approving_public_key === approvingPublicKey) {
    return json(joinPairingResponse(session));
  }
  const existingDevice = await env.DB.prepare("SELECT * FROM devices WHERE id = ?1 LIMIT 1")
    .bind(session.pending_device_id).first<DeviceRow>();
  if (existingDevice && existingDevice.vault_id !== auth.vault.id) {
    throw new ApiError(409, "device_conflict", "The proposed device identifier is already in use");
  }
  const replacesExistingDevice = Boolean(existingDevice);
  const count = await activeDeviceCount(env, auth.vault.id);
  const wouldAddActiveDevice = !existingDevice || existingDevice.revoked_at !== null;
  if (wouldAddActiveDevice && count >= limits(env).maximumDevicesPerVault) {
    throw new ApiError(409, "maximum_devices", "The vault already has the maximum number of devices");
  }

  if (session.status !== "waiting") throw new ApiError(409, "pairing_unavailable", "The pairing session is no longer available");
  const update = await env.DB.prepare(
    `UPDATE pairing_sessions
        SET vault_id = ?1,
            approver_device_id = ?2,
            approving_public_key = ?3,
            replaces_existing_device = ?4,
            status = 'joined',
            join_attempts = join_attempts + 1
      WHERE id = ?5 AND status = 'waiting' AND expires_at > ?6`,
  ).bind(auth.vault.id, auth.device.id, approvingPublicKey, replacesExistingDevice ? 1 : 0, session.id, now).run();
  if (Number(update.meta.changes ?? 0) !== 1) throw new ApiError(409, "pairing_unavailable", "The pairing session changed");
  return json({
    sessionId: session.id,
    joiningDeviceId: session.pending_device_id,
    joiningPublicKey: session.joining_public_key,
    replacedExistingDevice: replacesExistingDevice,
    expiresAt: isoTime(session.expires_at),
  });
}

async function approvePairingSession(
  request: Request,
  env: Env,
  rawSessionId: string,
  now: number,
): Promise<Response> {
  const sessionId = validator(() => validateUuid(rawSessionId, "sessionId"));
  const auth = await authenticate(request, env);
  const body = objectBody(await readJson(request, 32_768));
  const approvingPublicKey = validator(() => validateRawPublicKey(body.approvingPublicKey, "approvingPublicKey"));
  const encryptedGrant = validator(() => validateEnvelope(body.encryptedGrant, "encryptedGrant", 4_096));
  const newDeviceToken = requiredString(body.newDeviceToken, "newDeviceToken", 40, 160);
  const session = await env.DB.prepare("SELECT * FROM pairing_sessions WHERE id = ?1 LIMIT 1")
    .bind(sessionId).first<PairingRow>();
  if (!session || session.vault_id !== auth.vault.id || session.approver_device_id !== auth.device.id) {
    throw new ApiError(404, "pairing_not_found", "The pairing session was not found");
  }
  if (session.expires_at <= now) throw new ApiError(410, "pairing_expired", "The pairing session has expired");
  if (session.approving_public_key !== approvingPublicKey) {
    throw new ApiError(409, "pairing_unavailable", "The pairing session cannot be approved");
  }
  const expectedPrefix = `${session.pending_device_id}.`;
  if (!newDeviceToken.toLowerCase().startsWith(expectedPrefix.toLowerCase()) ||
      !/^[A-Za-z0-9_-]{43}$/.test(newDeviceToken.slice(expectedPrefix.length))) {
    throw new ApiError(400, "invalid_device_token", "The new device token is not bound to the joining device");
  }
  const tokenHash = await keyedHash(env.TOKEN_HASH_KEY, `device-token:${newDeviceToken}`);
  const grantHash = await sha256Base64Url(canonicalJson(encryptedGrant));
  if ((session.status === "approved" || session.status === "completed") &&
      session.new_device_token_hash === tokenHash && session.grant_hash === grantHash &&
      session.key_envelope_nonce === encryptedGrant.nonce &&
      session.key_envelope_ciphertext === encryptedGrant.ciphertext &&
      session.key_envelope_tag === encryptedGrant.tag) {
    return noContent();
  }
  if (session.status !== "joined") {
    throw new ApiError(409, "pairing_unavailable", "The pairing session cannot be approved");
  }
  try {
    const update = await env.DB.prepare(
      `UPDATE pairing_sessions
          SET status = 'approved',
              new_device_token_hash = ?1,
              key_envelope_nonce = ?2,
              key_envelope_ciphertext = ?3,
              key_envelope_tag = ?4,
              grant_hash = ?5,
              approved_at = ?6
        WHERE id = ?7 AND status = 'joined'`,
    ).bind(
      tokenHash,
      encryptedGrant.nonce,
      encryptedGrant.ciphertext,
      encryptedGrant.tag,
      grantHash,
      now,
      session.id,
    ).run();
    if (Number(update.meta.changes ?? 0) !== 1) throw new Error("Pairing state changed");
  } catch {
    throw new ApiError(409, "pairing_unavailable", "The pairing session could not be approved");
  }
  return noContent();
}

async function completePairingSession(
  request: Request,
  env: Env,
  rawSessionId: string,
  now: number,
): Promise<Response> {
  const sessionId = validator(() => validateUuid(rawSessionId, "sessionId"));
  const body = objectBody(await readJson(request, 32_768));
  const completionToken = requiredString(body.completionToken, "completionToken", 32, 128);
  const completionHash = await keyedHash(env.TOKEN_HASH_KEY, `pairing-completion:${completionToken}`);
  const session = await env.DB.prepare("SELECT * FROM pairing_sessions WHERE id = ?1 AND completion_token_hash = ?2 LIMIT 1")
    .bind(sessionId, completionHash).first<PairingRow>();
  if (!session) throw new ApiError(404, "pairing_not_found", "The pairing session was not found");
  if (session.expires_at <= now) {
    await env.DB.prepare("UPDATE pairing_sessions SET status = 'expired' WHERE id = ?1 AND status <> 'expired'")
      .bind(session.id).run();
    throw new ApiError(410, "pairing_expired", "The pairing session has expired");
  }
  if (session.status === "waiting" || session.status === "joined") {
    return json({ pending: true, requiresProfile: false, serverTime: isoTime(now) });
  }
  if (session.status === "expired") throw new ApiError(410, "pairing_expired", "The pairing session has expired");
  if (session.status === "completed") {
    if (!session.vault_id) throw new Error("Completed pairing session has no vault");
    if (body.encryptedDeviceProfile !== undefined && body.encryptedDeviceProfile !== null) {
      const profile = validator(() => validateEnvelope(body.encryptedDeviceProfile, "encryptedDeviceProfile", 2_048));
      const device = await env.DB.prepare(
        "SELECT * FROM devices WHERE id = ?1 AND vault_id = ?2 LIMIT 1",
      ).bind(session.pending_device_id, session.vault_id).first<DeviceRow>();
      if (!device || !profilesEqual(device, profile)) {
        throw new ApiError(409, "pairing_profile_conflict", "The completed pairing profile does not match");
      }
    }
    return json(pairingGrantResponse(
      session,
      await activeDeviceCount(env, session.vault_id),
      false,
      now,
    ));
  }
  if (!session.vault_id || !session.approving_public_key || !session.new_device_token_hash ||
      !session.key_envelope_nonce || !session.key_envelope_ciphertext || !session.key_envelope_tag) {
    throw new Error("Approved pairing session is incomplete");
  }
  if (body.encryptedDeviceProfile === undefined || body.encryptedDeviceProfile === null) {
    return json(pairingGrantResponse(
      session,
      await activeDeviceCount(env, session.vault_id),
      true,
      now,
    ));
  }
  const profile = validator(() => validateEnvelope(body.encryptedDeviceProfile, "encryptedDeviceProfile", 2_048));
  const count = await activeDeviceCount(env, session.vault_id);
  const replacesExistingDevice = session.replaces_existing_device === 1;
  const existingDevice = await env.DB.prepare("SELECT * FROM devices WHERE id = ?1 LIMIT 1")
    .bind(session.pending_device_id).first<DeviceRow>();
  if (replacesExistingDevice && (!existingDevice || existingDevice.vault_id !== session.vault_id)) {
    throw new ApiError(409, "pairing_unavailable", "The device selected for pairing takeover is unavailable");
  }
  if (!replacesExistingDevice && existingDevice) {
    throw new ApiError(409, "device_conflict", "The proposed device identifier is already in use");
  }
  const wouldAddActiveDevice = !replacesExistingDevice || existingDevice!.revoked_at !== null;
  if (wouldAddActiveDevice && count >= limits(env).maximumDevicesPerVault) {
    throw new ApiError(409, "maximum_devices", "The vault has too many devices");
  }
  try {
    const registerDevice = replacesExistingDevice
      ? env.DB.prepare(
        `UPDATE devices
            SET profile_nonce = ?1,
                profile_ciphertext = ?2,
                profile_tag = ?3,
                token_hash = ?4,
                revoked_at = NULL,
                last_seen_at = ?5,
                bootstrap_consumed_at = NULL,
                exempt_sync_page_count = 0,
                last_idempotency_key = NULL,
                last_idempotency_hash = NULL,
                last_idempotency_at = NULL
          WHERE id = ?6
            AND vault_id = ?7
            AND EXISTS (
              SELECT 1
                FROM pairing_sessions session
                JOIN vaults vault ON vault.id = session.vault_id
               WHERE session.id = ?8
                 AND session.status = 'approved'
                 AND vault.deleted_at IS NULL
            )`,
      ).bind(
        profile.nonce,
        profile.ciphertext,
        profile.tag,
        session.new_device_token_hash,
        now,
        session.pending_device_id,
        session.vault_id,
        session.id,
      )
      : env.DB.prepare(
        `INSERT INTO devices(
           id, vault_id, profile_nonce, profile_ciphertext, profile_tag, token_hash, created_at
         )
         SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7
          WHERE EXISTS (
            SELECT 1
              FROM pairing_sessions session
              JOIN vaults vault ON vault.id = session.vault_id
             WHERE session.id = ?8
               AND session.status = 'approved'
               AND vault.deleted_at IS NULL
          )`,
      ).bind(
        session.pending_device_id,
        session.vault_id,
        profile.nonce,
        profile.ciphertext,
        profile.tag,
        session.new_device_token_hash,
        now,
        session.id,
      );
    const results = await env.DB.batch([
      registerDevice,
      env.DB.prepare(
        `UPDATE pairing_sessions
            SET status = 'completed', completed_at = ?1
          WHERE id = ?2
            AND status = 'approved'
            AND EXISTS (
              SELECT 1 FROM vaults WHERE id = pairing_sessions.vault_id AND deleted_at IS NULL
            )`,
      ).bind(now, session.id),
    ]);
    if (Number(results[0]?.meta.changes ?? 0) !== 1 || Number(results[1]?.meta.changes ?? 0) !== 1) {
      throw new Error("Pairing completion state changed");
    }
  } catch {
    const completedSession = await env.DB.prepare(
      "SELECT * FROM pairing_sessions WHERE id = ?1 LIMIT 1",
    ).bind(session.id).first<PairingRow>();
    const completedDevice = await env.DB.prepare(
      "SELECT * FROM devices WHERE id = ?1 AND vault_id = ?2 LIMIT 1",
    ).bind(session.pending_device_id, session.vault_id).first<DeviceRow>();
    if (completedSession?.status === "completed" && completedDevice &&
        completedSession.new_device_token_hash === completedDevice.token_hash) {
      if (!profilesEqual(completedDevice, profile)) {
        throw new ApiError(409, "pairing_profile_conflict", "The completed pairing profile does not match");
      }
      return json(pairingGrantResponse(
        completedSession,
        await activeDeviceCount(env, session.vault_id),
        false,
        now,
      ));
    }
    if (wouldAddActiveDevice && await activeDeviceCount(env, session.vault_id) >= limits(env).maximumDevicesPerVault) {
      throw new ApiError(409, "maximum_devices", "The vault has too many devices");
    }
    throw new ApiError(409, "pairing_unavailable", "The joining device could not be registered");
  }
  return json(pairingGrantResponse(
    session,
    await activeDeviceCount(env, session.vault_id),
    false,
    now,
  ));
}

async function recoverVault(request: Request, env: Env, now: number): Promise<Response> {
  const body = objectBody(await readJson(request, 16_384));
  const recoveryAuthToken = validator(() => validateRecoveryAuthToken(body.recoveryAuthToken));
  const deviceId = validator(() => validateUuid(body.deviceId, "deviceId"));
  const deviceToken = validator(() => validateDeviceToken(body.deviceToken, deviceId));
  const replaceDeviceId = body.replaceDeviceId === undefined
    ? null
    : validator(() => validateUuid(body.replaceDeviceId, "replaceDeviceId"));
  if (replaceDeviceId !== null && replaceDeviceId !== deviceId) {
    throw new ApiError(400, "invalid_request", "replaceDeviceId must equal deviceId to preserve the device identity");
  }
  const recoveryHash = await keyedHash(env.TOKEN_HASH_KEY, `recovery:${recoveryAuthToken}`);
  const tokenHash = await keyedHash(env.TOKEN_HASH_KEY, `device-token:${deviceToken}`);
  const vault = await env.DB.prepare(
    "SELECT * FROM vaults WHERE recovery_auth_hash = ?1 AND deleted_at IS NULL LIMIT 1",
  ).bind(recoveryHash).first<VaultRow>();
  if (!vault) {
    await enforceHourlyLimit(request, env, "recovery_ip", 5, now);
    throw new ApiError(401, "recovery_failed", "The recovery credential is invalid");
  }

  const existingDevice = await env.DB.prepare("SELECT * FROM devices WHERE id = ?1 LIMIT 1")
    .bind(deviceId).first<DeviceRow>();
  if (existingDevice?.vault_id === vault.id && existingDevice.revoked_at === null && existingDevice.token_hash === tokenHash) {
    return recoveryResponse(vault, existingDevice, deviceToken, await activeDeviceCount(env, vault.id), now);
  }

  await enforceHourlyLimit(request, env, "recovery_ip", 5, now);
  await enforceHourlyLimit(request, env, "recovery_vault", 5, now, vault.id);
  const count = await activeDeviceCount(env, vault.id);

  if (replaceDeviceId !== null) {
    if (!existingDevice || existingDevice.vault_id !== vault.id) {
      throw new ApiError(
        409,
        "replace_device_not_found",
        "The selected device does not belong to this recovery vault",
      );
    }
    if (existingDevice.revoked_at !== null && count >= limits(env).maximumDevicesPerVault) {
      throw await maximumDevicesError(env, vault.id);
    }
    try {
      const update = await env.DB.prepare(
        `UPDATE devices
            SET token_hash = ?1,
                revoked_at = NULL,
                last_seen_at = ?2,
                bootstrap_consumed_at = NULL,
                exempt_sync_page_count = 0,
                last_idempotency_key = NULL,
                last_idempotency_hash = NULL,
                last_idempotency_at = NULL
          WHERE id = ?3
            AND vault_id = ?4
            AND token_hash = ?5
            AND revoked_at IS ?6
            AND EXISTS (
              SELECT 1 FROM vaults WHERE id = ?4 AND deleted_at IS NULL
            )`,
      ).bind(tokenHash, now, existingDevice.id, vault.id, existingDevice.token_hash, existingDevice.revoked_at).run();
      if (Number(update.meta.changes ?? 0) !== 1) throw new Error("Recovery target changed");
    } catch {
      const refreshed = await env.DB.prepare(
        "SELECT * FROM devices WHERE id = ?1 AND vault_id = ?2 LIMIT 1",
      ).bind(deviceId, vault.id).first<DeviceRow>();
      if (refreshed?.revoked_at === null && refreshed.token_hash === tokenHash) {
        return recoveryResponse(vault, refreshed, deviceToken, await activeDeviceCount(env, vault.id), now);
      }
      if (!await isVaultActive(env, vault.id)) {
        throw new ApiError(401, "recovery_failed", "The recovery credential is invalid");
      }
      if (await activeDeviceCount(env, vault.id) >= limits(env).maximumDevicesPerVault && existingDevice.revoked_at !== null) {
        throw await maximumDevicesError(env, vault.id);
      }
      throw new ApiError(409, "recovery_state_changed", "The selected device changed during recovery");
    }
    const recovered = await env.DB.prepare(
      "SELECT * FROM devices WHERE id = ?1 AND vault_id = ?2 LIMIT 1",
    ).bind(deviceId, vault.id).first<DeviceRow>();
    if (!recovered) throw new Error("Recovered device disappeared");
    return recoveryResponse(
      vault,
      recovered,
      deviceToken,
      await activeDeviceCount(env, vault.id),
      now,
    );
  }

  if (existingDevice) {
    throw new ApiError(409, "device_conflict", "The proposed device identifier is already in use");
  }
  if (count >= limits(env).maximumDevicesPerVault) throw await maximumDevicesError(env, vault.id);
  try {
    const insert = await env.DB.prepare(
      `INSERT INTO devices(id, vault_id, token_hash, created_at)
       SELECT ?1, ?2, ?3, ?4
        WHERE EXISTS (SELECT 1 FROM vaults WHERE id = ?2 AND deleted_at IS NULL)`,
    ).bind(deviceId, vault.id, tokenHash, now).run();
    if (Number(insert.meta.changes ?? 0) !== 1) throw new Error("Recovery vault changed");
  } catch {
    const replay = await env.DB.prepare(
      "SELECT * FROM devices WHERE id = ?1 AND vault_id = ?2 AND token_hash = ?3 AND revoked_at IS NULL LIMIT 1",
    ).bind(deviceId, vault.id, tokenHash).first<DeviceRow>();
    if (replay) {
      return recoveryResponse(vault, replay, deviceToken, await activeDeviceCount(env, vault.id), now);
    }
    if (!await isVaultActive(env, vault.id)) {
      throw new ApiError(401, "recovery_failed", "The recovery credential is invalid");
    }
    if (await activeDeviceCount(env, vault.id) >= limits(env).maximumDevicesPerVault) {
      throw await maximumDevicesError(env, vault.id);
    }
    throw new ApiError(409, "device_conflict", "The proposed device identifier is already in use");
  }
  const created = await env.DB.prepare("SELECT * FROM devices WHERE id = ?1 LIMIT 1")
    .bind(deviceId).first<DeviceRow>();
  if (!created) throw new Error("Recovered device disappeared");
  return recoveryResponse(vault, created, deviceToken, await activeDeviceCount(env, vault.id), now);
}

async function sync(request: Request, env: Env, now: number): Promise<Response> {
  const auth = await authenticate(request, env);
  const body = objectBody(await readJson(request, 2 * 1_024 * 1_024));
  return json(await handleSync(request, env, auth, body, limits(env), now));
}

async function history(request: Request, env: Env): Promise<Response> {
  const auth = await authenticate(request, env);
  const rawCursor = new URL(request.url).searchParams.get("cursor") ?? "0";
  if (!/^\d{1,16}$/.test(rawCursor)) throw new ApiError(400, "invalid_cursor", "cursor must be a non-negative integer");
  const cursor = Number(rawCursor);
  if (!Number.isSafeInteger(cursor)) throw new ApiError(400, "invalid_cursor", "cursor is too large");
  const page = await readHistoryPage(env, auth.vault.id, cursor, auth.vault.changes_pruned_through);
  return json(page);
}

async function state(request: Request, env: Env, now: number): Promise<Response> {
  const auth = await authenticate(request, env);
  const devices = await activeDevices(env, auth.vault.id);
  return json({
    serverTime: isoTime(now),
    activeDeviceCount: devices.length,
    currentSnapshots: devices.map(currentRecord).filter((record) => record !== null),
    devices: devices.map(wireDeviceDescriptor),
  });
}

async function deleteDevice(request: Request, env: Env, rawDeviceId: string, now: number): Promise<Response> {
  const deviceId = validator(() => validateUuid(rawDeviceId, "deviceId"));
  const vaultId = await authorizeDeviceDeletion(request, env, deviceId);
  let target = await env.DB.prepare(
    "SELECT * FROM devices WHERE id = ?1 AND vault_id = ?2 LIMIT 1",
  ).bind(deviceId, vaultId).first<DeviceRow>();
  if (!target) throw new ApiError(404, "device_not_found", "The device was not found");

  // Revocation is the linearization point with an in-flight sync. Keep the
  // current record on the revoked row until it has been durably archived, so a
  // failed R2/D1 write can be resumed by an idempotent DELETE retry.
  if (target.revoked_at === null) {
    await env.DB.prepare(
      "UPDATE devices SET revoked_at = ?1 WHERE id = ?2 AND vault_id = ?3 AND revoked_at IS NULL",
    ).bind(now, target.id, vaultId).run();
  }

  target = await env.DB.prepare(
    "SELECT * FROM devices WHERE id = ?1 AND vault_id = ?2 AND revoked_at IS NOT NULL LIMIT 1",
  ).bind(deviceId, vaultId).first<DeviceRow>();
  if (!target) throw new ApiError(409, "device_state_changed", "The device revocation state changed");

  await env.DB.prepare(
    `UPDATE pairing_sessions
        SET status = 'expired'
      WHERE status IN ('waiting', 'joined', 'approved')
        AND (approver_device_id = ?1 OR pending_device_id = ?1)`,
  ).bind(target.id).run();

  for (let attempt = 0; attempt < 3; attempt += 1) {
    const record = currentRecord(target);
    if (!record) {
      if (hasPartialCurrentRecord(target)) {
        throw new Error("A revoked device has an incomplete current record");
      }
      return noContent();
    }

    await storeHistoryRecords(env, vaultId, target.id, [record], now);
    const cleared = await env.DB.prepare(
      `UPDATE devices
          SET current_record_id = NULL,
              current_revision = NULL,
              current_nonce = NULL,
              current_ciphertext = NULL,
              current_tag = NULL,
              current_ciphertext_hash = NULL,
              current_updated_at = NULL
        WHERE id = ?1
          AND vault_id = ?2
          AND revoked_at IS NOT NULL
          AND current_record_id IS ?3
          AND current_revision IS ?4
          AND current_nonce IS ?5
          AND current_ciphertext IS ?6
          AND current_tag IS ?7
          AND current_ciphertext_hash IS ?8`,
    ).bind(
      target.id,
      vaultId,
      record.recordId,
      record.revision,
      record.nonce,
      record.ciphertext,
      record.tag,
      record.ciphertextHash,
    ).run();
    if (Number(cleared.meta.changes ?? 0) === 1) return noContent();

    const refreshed = await env.DB.prepare(
      "SELECT * FROM devices WHERE id = ?1 AND vault_id = ?2 AND revoked_at IS NOT NULL LIMIT 1",
    ).bind(deviceId, vaultId).first<DeviceRow>();
    if (!refreshed) throw new ApiError(409, "device_state_changed", "The device revocation state changed");
    target = refreshed;
  }
  throw new ApiError(409, "device_state_changed", "The device current record kept changing during revocation");
}

async function authorizeDeviceDeletion(request: Request, env: Env, targetDeviceId: string): Promise<string> {
  try {
    return (await authenticate(request, env)).vault.id;
  } catch (error) {
    if (!(error instanceof ApiError) || error.status !== 401) throw error;

    // A device that revoked itself cannot pass normal authentication on retry.
    // Its old token may only finish DELETE for that same device; it cannot read
    // history, revoke another device, or act after the vault is deleted.
    const authorization = request.headers.get("authorization") ?? "";
    if (!authorization.startsWith("Bearer ")) throw error;
    const token = authorization.slice(7);
    if (token.length < 40 || token.length > 160 || token.includes("\n")) throw error;
    const tokenHash = await keyedHash(env.TOKEN_HASH_KEY, `device-token:${token}`);
    const row = await env.DB.prepare(
      `SELECT d.vault_id
         FROM devices d
         JOIN vaults v ON v.id = d.vault_id
        WHERE d.id = ?1
          AND d.token_hash = ?2
          AND d.revoked_at IS NOT NULL
          AND v.deleted_at IS NULL
        LIMIT 1`,
    ).bind(targetDeviceId, tokenHash).first<{ vault_id: string }>();
    if (!row) throw error;
    return row.vault_id;
  }
}

function hasPartialCurrentRecord(device: DeviceRow): boolean {
  return device.current_record_id !== null ||
    device.current_revision !== null ||
    device.current_nonce !== null ||
    device.current_ciphertext !== null ||
    device.current_tag !== null ||
    device.current_ciphertext_hash !== null;
}

async function deleteVault(request: Request, env: Env, now: number): Promise<Response> {
  const { vaultId, tokenHash, alreadyDeleted, needsLegacyReceipt } =
    await authorizeVaultDeletion(request, env, now);
  if (needsLegacyReceipt) {
    await storeVaultDeletionReceipt(env, tokenHash, now);
    return noContent();
  }
  if (alreadyDeleted) return noContent();
  if (!vaultId) throw new Error("An active vault deletion has no vault identifier");
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO vault_deletion_receipts(token_hash, created_at, expires_at)
       VALUES (?1, ?2, ?3)
       ON CONFLICT(token_hash) DO UPDATE SET
         created_at = excluded.created_at,
         expires_at = excluded.expires_at`,
    ).bind(tokenHash, now, now + VAULT_DELETION_RECEIPT_TTL_MS),
    env.DB.prepare("UPDATE vaults SET deleted_at = ?1 WHERE id = ?2 AND deleted_at IS NULL")
      .bind(now, vaultId),
    env.DB.prepare(
      "UPDATE pairing_sessions SET status = 'expired' WHERE vault_id = ?1 AND status <> 'expired'",
    ).bind(vaultId),
  ]);
  return noContent();
}

async function authorizeVaultDeletion(
  request: Request,
  env: Env,
  now: number,
): Promise<{
    vaultId: string | null;
    tokenHash: string;
    alreadyDeleted: boolean;
    needsLegacyReceipt: boolean;
  }> {
  try {
    const auth = await authenticate(request, env);
    return {
      vaultId: auth.vault.id,
      tokenHash: auth.device.token_hash,
      alreadyDeleted: false,
      needsLegacyReceipt: false,
    };
  } catch (error) {
    if (!(error instanceof ApiError) || error.status !== 401) throw error;
    const authorization = request.headers.get("authorization") ?? "";
    if (!authorization.startsWith("Bearer ")) throw error;
    const token = authorization.slice(7);
    if (token.length < 40 || token.length > 160 || token.includes("\n")) throw error;
    const tokenHash = await keyedHash(env.TOKEN_HASH_KEY, `device-token:${token}`);
    const receipt = await env.DB.prepare(
      `SELECT 1 AS present
         FROM vault_deletion_receipts
        WHERE token_hash = ?1 AND expires_at > ?2
        LIMIT 1`,
    ).bind(tokenHash, now).first<{ present: number }>();
    if (receipt) {
      return { vaultId: null, tokenHash, alreadyDeleted: true, needsLegacyReceipt: false };
    }
    const row = await env.DB.prepare(
      `SELECT d.vault_id,
              v.deleted_at,
              EXISTS (
                SELECT 1
                  FROM devices sibling
                  JOIN vault_deletion_receipts receipt ON receipt.token_hash = sibling.token_hash
                 WHERE sibling.vault_id = d.vault_id
              ) AS vault_has_receipt
         FROM devices d
         JOIN vaults v ON v.id = d.vault_id
        WHERE d.token_hash = ?1
          AND v.deleted_at IS NOT NULL
        LIMIT 1`,
    ).bind(tokenHash).first<{ vault_id: string; deleted_at: number; vault_has_receipt: number }>();
    if (!row || row.vault_has_receipt !== 0 || row.deleted_at + VAULT_DELETION_RECEIPT_TTL_MS <= now) throw error;
    // Compatibility for a vault tombstoned by a pre-receipt Worker version.
    // Once any receipt exists for that vault, only that exact token can replay.
    return { vaultId: row.vault_id, tokenHash, alreadyDeleted: true, needsLegacyReceipt: true };
  }
}

async function storeVaultDeletionReceipt(env: Env, tokenHash: string, now: number): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO vault_deletion_receipts(token_hash, created_at, expires_at)
     VALUES (?1, ?2, ?3)
     ON CONFLICT(token_hash) DO NOTHING`,
  ).bind(tokenHash, now, now + VAULT_DELETION_RECEIPT_TTL_MS).run();
}

function normalizedPath(path: string): string {
  if (path.length > 1 && path.endsWith("/")) return path.slice(0, -1);
  return path;
}

function randomPairingCode(): string {
  const range = 1_000_000;
  const maximum = Math.floor(0x1_0000_0000 / range) * range;
  const buffer = new Uint32Array(1);
  do crypto.getRandomValues(buffer); while (buffer[0]! >= maximum);
  return String(buffer[0]! % range).padStart(6, "0");
}

function joinPairingResponse(session: PairingRow): Record<string, unknown> {
  return {
    sessionId: session.id,
    joiningDeviceId: session.pending_device_id,
    joiningPublicKey: session.joining_public_key,
    replacedExistingDevice: session.replaces_existing_device === 1,
    expiresAt: isoTime(session.expires_at),
  };
}

function pairingGrantResponse(
  session: PairingRow,
  deviceCount: number,
  requiresProfile: boolean,
  now: number,
): Record<string, unknown> {
  if (!session.approving_public_key || !session.key_envelope_nonce ||
      !session.key_envelope_ciphertext || !session.key_envelope_tag) {
    throw new Error("Approved pairing session is incomplete");
  }
  return {
    pending: false,
    requiresProfile,
    approvingPublicKey: session.approving_public_key,
    encryptedGrant: {
      nonce: session.key_envelope_nonce,
      ciphertext: session.key_envelope_ciphertext,
      tag: session.key_envelope_tag,
    },
    replacedExistingDevice: session.replaces_existing_device === 1,
    activeDeviceCount: deviceCount,
    serverTime: isoTime(now),
  };
}

async function isExactVaultCreationReplay(
  env: Env,
  vaultId: string,
  deviceId: string,
  recoveryHash: string,
  tokenHash: string,
  profile: EncryptedEnvelope,
): Promise<boolean> {
  const vault = await env.DB.prepare(
    "SELECT * FROM vaults WHERE id = ?1 AND recovery_auth_hash = ?2 AND deleted_at IS NULL LIMIT 1",
  ).bind(vaultId, recoveryHash).first<VaultRow>();
  if (!vault) return false;
  const device = await env.DB.prepare(
    "SELECT * FROM devices WHERE id = ?1 AND vault_id = ?2 AND token_hash = ?3 AND revoked_at IS NULL LIMIT 1",
  ).bind(deviceId, vaultId, tokenHash).first<DeviceRow>();
  return Boolean(device && profilesEqual(device, profile));
}

function createVaultResponse(vaultId: string, deviceId: string, deviceToken: string, now: number): Response {
  return json({ vaultId, deviceId, deviceToken, activeDeviceCount: 1, serverTime: isoTime(now) }, 201);
}

function profilesEqual(device: DeviceRow, profile: EncryptedEnvelope): boolean {
  return device.profile_nonce === profile.nonce &&
    device.profile_ciphertext === profile.ciphertext &&
    device.profile_tag === profile.tag;
}

async function activeDevices(env: Env, vaultId: string): Promise<DeviceRow[]> {
  const result = await env.DB.prepare(
    "SELECT * FROM devices WHERE vault_id = ?1 AND revoked_at IS NULL ORDER BY created_at ASC, id ASC",
  ).bind(vaultId).all<DeviceRow>();
  return result.results;
}

async function isVaultActive(env: Env, vaultId: string): Promise<boolean> {
  const row = await env.DB.prepare(
    "SELECT 1 AS present FROM vaults WHERE id = ?1 AND deleted_at IS NULL LIMIT 1",
  ).bind(vaultId).first<{ present: number }>();
  return Boolean(row);
}

function wireDeviceDescriptor(device: DeviceRow): Record<string, unknown> {
  const descriptor: Record<string, unknown> = {
    deviceId: device.id,
    lastSyncAt: device.last_sync_at === null ? null : isoTime(device.last_sync_at),
    revoked: device.revoked_at !== null,
  };
  if (device.profile_nonce && device.profile_ciphertext && device.profile_tag) {
    descriptor.encryptedDeviceProfile = {
      nonce: device.profile_nonce,
      ciphertext: device.profile_ciphertext,
      tag: device.profile_tag,
    };
  }
  return descriptor;
}

async function maximumDevicesError(env: Env, vaultId: string): Promise<ApiError> {
  const devices = await activeDevices(env, vaultId);
  return new ApiError(
    409,
    "maximum_devices",
    "The vault has too many devices",
    {},
    { vaultId, activeDeviceCount: devices.length, devices: devices.map(wireDeviceDescriptor) },
  );
}

function recoveryResponse(
  vault: VaultRow,
  device: DeviceRow,
  deviceToken: string,
  deviceCount: number,
  now: number,
): Response {
  const response: Record<string, unknown> = {
    vaultId: vault.id,
    deviceId: device.id,
    deviceToken,
    activeDeviceCount: deviceCount,
    serverTime: isoTime(now),
    cursor: 0,
  };
  const current = currentRecord(device);
  if (current) response.currentSnapshot = current;
  return json(response);
}
