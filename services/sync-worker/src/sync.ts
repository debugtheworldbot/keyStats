import { activeDeviceCount } from "./auth";
import { sha256Base64Url, validateEnvelope, validateRecord } from "./crypto";
import type { Env, ServiceLimits } from "./env";
import { ApiError, isoTime } from "./http";
import {
  currentRecord,
  hasArchivedRecord,
  readHistoryPage,
  storeHistoryRecords,
  validateHistoryRecords,
} from "./history";
import type { AuthContext, DeviceRow, EncryptedEnvelope, EncryptedRecord } from "./types";
import {
  assertExactProperties,
  canonicalJson,
  optionalBoolean,
  requiredArray,
  requiredNonNegativeInteger,
  validateSyncReason,
  validator,
  validatorAsync,
} from "./validation";

export const MAX_ARCHIVES_PER_SYNC = 16;
export const MAX_EXEMPT_SYNC_PAGES = 256;
export const MAX_REPORTED_DAILY_SYNCS = 8;

export function remainingDailySyncs(serviceLimits: ServiceLimits, used: number): number {
  if (serviceLimits.dailySyncLimit === 0) return MAX_REPORTED_DAILY_SYNCS;
  return Math.min(
    MAX_REPORTED_DAILY_SYNCS,
    Math.max(0, serviceLimits.dailySyncLimit - used),
  );
}

interface ParsedSyncRequest {
  reason: "manual" | "automatic" | "bootstrap" | "pairing" | "recovery";
  historyCursor: number;
  currentSnapshot: EncryptedRecord | null;
  archives: EncryptedRecord[];
  encryptedDeviceProfile: EncryptedEnvelope | null;
  bootstrapComplete: boolean;
}

interface SyncAttempt {
  replay: boolean;
  exempt: boolean;
  pairingSessionId: string | null;
  bodyHash: string;
  idempotencyKey: string;
  device: DeviceRow;
}

interface SyncMutation {
  nextCurrent: EncryptedRecord | null;
  currentChanged: boolean;
  profile: EncryptedEnvelope | null;
  archives: EncryptedRecord[];
  rolloverArchive: EncryptedRecord | null;
}

interface PairingBypassRow {
  id: string;
}

export async function handleSync(
  request: Request,
  env: Env,
  auth: AuthContext,
  body: Record<string, unknown>,
  serviceLimits: ServiceLimits,
  now: number,
): Promise<Record<string, unknown>> {
  const parsed = await parseSyncRequest(body, auth.device.id);
  const idempotencyKey = request.headers.get("idempotency-key") ?? "";
  if (!/^[A-Za-z0-9_-]{8,128}$/.test(idempotencyKey)) {
    throw new ApiError(400, "invalid_idempotency_key", "Idempotency-Key is required");
  }
  const bodyHash = await sha256Base64Url(canonicalJson(body));
  const attempt = await prepareSyncAttempt(
    env,
    auth,
    parsed.reason,
    idempotencyKey,
    bodyHash,
    serviceLimits,
    now,
  );

  if (attempt.replay) {
    // The device row is the single-write reservation. If an R2/D1 history
    // write failed after that reservation, an exact replay finishes the
    // idempotent archive work without consuming another sync quota write.
    await storeHistoryRecords(env, auth.vault.id, auth.device.id, parsed.archives, now);
  } else {
    const mutation = await prepareSyncMutation(env, auth.vault.id, attempt.device, parsed);
    // Preserve the previous current envelope before changing the device row.
    // If either R2 or D1 fails, the row still contains the complete envelope
    // and an exact retry can safely repeat this idempotent handoff.
    if (mutation.rolloverArchive) {
      await storeHistoryRecords(env, auth.vault.id, auth.device.id, [mutation.rolloverArchive], now);
    }
    await finalizeSync(env, attempt, mutation, parsed.bootstrapComplete, serviceLimits, now);
    await storeHistoryRecords(env, auth.vault.id, auth.device.id, mutation.archives, now);
  }
  return buildSyncResponse(env, auth.vault.id, auth.device.id, parsed.historyCursor, serviceLimits, now);
}

async function parseSyncRequest(body: Record<string, unknown>, deviceId: string): Promise<ParsedSyncRequest> {
  assertExactProperties(body, "sync", [
    "reason",
    "historyCursor",
    "currentSnapshot",
    "archives",
    "encryptedDeviceProfile",
    "bootstrapComplete",
  ]);
  const reason = validateSyncReason(body.reason);
  const historyCursor = requiredNonNegativeInteger(body.historyCursor, "historyCursor");
  const currentSnapshot = body.currentSnapshot === undefined || body.currentSnapshot === null
    ? null
    : await validatorAsync(() => validateRecord(body.currentSnapshot, deviceId));
  const archivesRaw = requiredArray(body.archives, "archives", MAX_ARCHIVES_PER_SYNC);
  const archives: EncryptedRecord[] = [];
  for (const value of archivesRaw) archives.push(await validatorAsync(() => validateRecord(value, deviceId)));
  const encryptedDeviceProfile = body.encryptedDeviceProfile === undefined || body.encryptedDeviceProfile === null
    ? null
    : validator(() => validateEnvelope(body.encryptedDeviceProfile, "encryptedDeviceProfile", 2_048));
  const bootstrapComplete = optionalBoolean(body.bootstrapComplete, "bootstrapComplete", true);
  if (!bootstrapComplete && (reason === "manual" || reason === "automatic")) {
    throw new ApiError(400, "invalid_request", "bootstrapComplete can only paginate a cooldown-exempt sync");
  }
  if (currentSnapshot && archives.some((record) => record.recordId === currentSnapshot.recordId)) {
    throw new ApiError(400, "duplicate_record", "The current record cannot also be an archive");
  }
  return { reason, historyCursor, currentSnapshot, archives, encryptedDeviceProfile, bootstrapComplete };
}

async function prepareSyncAttempt(
  env: Env,
  auth: AuthContext,
  reason: ParsedSyncRequest["reason"],
  idempotencyKey: string,
  bodyHash: string,
  serviceLimits: ServiceLimits,
  now: number,
): Promise<SyncAttempt> {
  const device = await env.DB.prepare("SELECT * FROM devices WHERE id = ?1 AND revoked_at IS NULL")
    .bind(auth.device.id).first<DeviceRow>();
  if (!device) throw new ApiError(401, "invalid_token", "The device token is invalid");

  if (device.last_idempotency_key === idempotencyKey) {
    if (device.last_idempotency_hash !== bodyHash) {
      throw new ApiError(409, "idempotency_conflict", "The idempotency key was reused with a different request");
    }
    return { replay: true, exempt: false, pairingSessionId: null, bodyHash, idempotencyKey, device };
  }
  const exemption = await isExemptReason(env, device, reason, now);
  if (exemption.exempt && (device.exempt_sync_page_count ?? 0) >= MAX_EXEMPT_SYNC_PAGES) {
    throw new ApiError(409, "bootstrap_page_limit", "The cooldown-exempt upload has too many pages");
  }
  if (!exemption.exempt) {
    const count = await activeDeviceCount(env, device.vault_id);
    if (count < 2) {
      throw new ApiError(
        409,
        "single_device_sync_disabled",
        "Ordinary sync is disabled for a single-device vault",
        {},
        { activeDeviceCount: count },
      );
    }
    enforceOrdinaryLimits(device, serviceLimits, now);
  }

  return {
    replay: false,
    exempt: exemption.exempt,
    pairingSessionId: exemption.pairingSessionId,
    bodyHash,
    idempotencyKey,
    device,
  };
}

async function isExemptReason(
  env: Env,
  device: DeviceRow,
  reason: ParsedSyncRequest["reason"],
  now: number,
): Promise<{ exempt: boolean; pairingSessionId: string | null }> {
  if (reason === "manual" || reason === "automatic") return { exempt: false, pairingSessionId: null };
  if (device.bootstrap_consumed_at === null) return { exempt: true, pairingSessionId: null };
  if (reason === "pairing") {
    const session = await env.DB.prepare(
      `SELECT session.id
         FROM pairing_sessions session
         JOIN devices pending
           ON pending.id = session.pending_device_id
          AND pending.vault_id = session.vault_id
          AND pending.revoked_at IS NULL
        WHERE session.approver_device_id = ?1
          AND session.approved_at >= ?2
          AND session.approver_sync_consumed_at IS NULL
          AND session.status = 'completed'
          AND pending.bootstrap_consumed_at IS NOT NULL
        ORDER BY session.approved_at DESC
        LIMIT 1`,
    ).bind(device.id, now - 10 * 60 * 1_000).first<PairingBypassRow>();
    if (session) return { exempt: true, pairingSessionId: session.id };
  }
  throw new ApiError(409, "bootstrap_already_consumed", "This cooldown-exempt sync reason is no longer available");
}

function enforceOrdinaryLimits(device: DeviceRow, serviceLimits: ServiceLimits, now: number): void {
  if (serviceLimits.minimumSyncIntervalSeconds > 0 && device.last_sync_at !== null) {
    const nextAllowed = device.last_sync_at + serviceLimits.minimumSyncIntervalSeconds * 1_000;
    if (now < nextAllowed) throw rateLimitError(nextAllowed, now, "The device sync cooldown has not elapsed");
  }
  const utcDay = new Date(now).toISOString().slice(0, 10);
  if (serviceLimits.dailySyncLimit > 0 &&
      device.sync_utc_day === utcDay && device.sync_count >= serviceLimits.dailySyncLimit) {
    const nextDay = Date.parse(`${utcDay}T00:00:00.000Z`) + 24 * 60 * 60 * 1_000;
    throw rateLimitError(nextDay, now, "The daily sync limit has been reached");
  }
}

async function prepareSyncMutation(
  env: Env,
  vaultId: string,
  device: DeviceRow,
  request: ParsedSyncRequest,
): Promise<SyncMutation> {
  const archives = [...request.archives];
  const previousCurrent = currentRecord(device);
  let nextCurrent = previousCurrent;
  let rolloverArchive: EncryptedRecord | null = null;

  if (request.currentSnapshot) {
    if (previousCurrent?.recordId === request.currentSnapshot.recordId) {
      if (request.currentSnapshot.revision < previousCurrent.revision) {
        throw new ApiError(409, "stale_revision", "The current snapshot has an older revision");
      }
      if (request.currentSnapshot.revision === previousCurrent.revision &&
          request.currentSnapshot.ciphertextHash !== previousCurrent.ciphertextHash) {
        throw new ApiError(409, "revision_conflict", "The same revision has different encrypted content");
      }
      if (request.currentSnapshot.revision > previousCurrent.revision) nextCurrent = request.currentSnapshot;
    } else {
      if (await hasArchivedRecord(env, vaultId, request.currentSnapshot.recordId)) {
        throw new ApiError(409, "archived_record_cannot_be_current", "An archived record cannot become current again");
      }
      if (previousCurrent) {
        const suppliedPrevious = archives.find((record) => record.recordId === previousCurrent.recordId);
        if (suppliedPrevious && suppliedPrevious.revision < previousCurrent.revision) {
          throw new ApiError(409, "stale_revision", "The previous current snapshot has an older revision");
        }
        if (suppliedPrevious?.revision === previousCurrent.revision &&
            suppliedPrevious.ciphertextHash !== previousCurrent.ciphertextHash) {
          throw new ApiError(409, "revision_conflict", "The previous current revision has different encrypted content");
        }
        rolloverArchive = previousCurrent;
      }
      nextCurrent = request.currentSnapshot;
    }
  }

  if (!request.currentSnapshot && previousCurrent && archives.some((record) => record.recordId === previousCurrent.recordId)) {
    throw new ApiError(409, "current_record_cannot_be_archived", "A current record needs a replacement before it can be archived");
  }
  await validateHistoryRecords(env, vaultId, archives);
  if (rolloverArchive) await validateHistoryRecords(env, vaultId, [rolloverArchive]);
  return {
    nextCurrent,
    currentChanged: nextCurrent !== previousCurrent,
    profile: request.encryptedDeviceProfile,
    archives,
    rolloverArchive,
  };
}

async function finalizeSync(
  env: Env,
  attempt: SyncAttempt,
  mutation: SyncMutation,
  bootstrapComplete: boolean,
  serviceLimits: ServiceLimits,
  now: number,
): Promise<void> {
  const utcDay = new Date(now).toISOString().slice(0, 10);
  const ordinaryCount = attempt.exempt
    ? attempt.device.sync_count
    : attempt.device.sync_utc_day === utcDay ? attempt.device.sync_count + 1 : 1;
  const ordinaryDay = attempt.exempt ? attempt.device.sync_utc_day : utcDay;
  const update = await env.DB.prepare(
    `UPDATE devices
        SET profile_nonce = CASE WHEN ?1 IS NULL THEN profile_nonce ELSE ?1 END,
            profile_ciphertext = CASE WHEN ?2 IS NULL THEN profile_ciphertext ELSE ?2 END,
            profile_tag = CASE WHEN ?3 IS NULL THEN profile_tag ELSE ?3 END,
            current_record_id = ?4,
            current_revision = ?5,
            current_nonce = ?6,
            current_ciphertext = ?7,
            current_tag = ?8,
            current_ciphertext_hash = ?9,
            current_updated_at = CASE WHEN ?10 = 1 THEN ?11 ELSE current_updated_at END,
            last_seen_at = ?11,
            last_sync_at = ?11,
            sync_utc_day = ?12,
            sync_count = ?13,
            bootstrap_consumed_at = CASE
              WHEN ?14 = 1 THEN COALESCE(bootstrap_consumed_at, ?11)
              ELSE bootstrap_consumed_at
            END,
            exempt_sync_page_count = CASE
              WHEN ?15 = 1 THEN exempt_sync_page_count + 1
              ELSE exempt_sync_page_count
            END,
            last_idempotency_key = ?16,
            last_idempotency_hash = ?17,
            last_idempotency_at = ?11
      WHERE id = ?18
        AND revoked_at IS NULL
        AND last_sync_at IS ?19
        AND sync_utc_day IS ?20
        AND sync_count = ?21
        AND exempt_sync_page_count = ?22`,
  ).bind(
    mutation.profile?.nonce ?? null,
    mutation.profile?.ciphertext ?? null,
    mutation.profile?.tag ?? null,
    mutation.nextCurrent?.recordId ?? null,
    mutation.nextCurrent?.revision ?? null,
    mutation.nextCurrent?.nonce ?? null,
    mutation.nextCurrent?.ciphertext ?? null,
    mutation.nextCurrent?.tag ?? null,
    mutation.nextCurrent?.ciphertextHash ?? null,
    mutation.currentChanged ? 1 : 0,
    now,
    ordinaryDay,
    ordinaryCount,
    attempt.exempt && bootstrapComplete ? 1 : 0,
    attempt.exempt ? 1 : 0,
    attempt.idempotencyKey,
    attempt.bodyHash,
    attempt.device.id,
    attempt.device.last_sync_at,
    attempt.device.sync_utc_day,
    attempt.device.sync_count,
    attempt.device.exempt_sync_page_count ?? 0,
  ).run();
  if (Number(update.meta.changes ?? 0) !== 1) {
    const current = await env.DB.prepare("SELECT * FROM devices WHERE id = ?1 AND revoked_at IS NULL")
      .bind(attempt.device.id).first<DeviceRow>();
    if (current?.last_idempotency_key === attempt.idempotencyKey && current.last_idempotency_hash === attempt.bodyHash) {
      return;
    }
    if (!attempt.exempt && current) enforceOrdinaryLimits(current, serviceLimits, now);
    throw rateLimitError(now + 5_000, now, "The sync state changed; retry the request");
  }
  if (attempt.pairingSessionId && bootstrapComplete) {
    await env.DB.prepare(
      "UPDATE pairing_sessions SET approver_sync_consumed_at = ?1 WHERE id = ?2 AND approver_sync_consumed_at IS NULL",
    ).bind(now, attempt.pairingSessionId).run();
  }
}

async function buildSyncResponse(
  env: Env,
  vaultId: string,
  ownDeviceId: string,
  historyCursor: number,
  serviceLimits: ServiceLimits,
  now: number,
): Promise<Record<string, unknown>> {
  const vault = await env.DB.prepare("SELECT changes_pruned_through FROM vaults WHERE id = ?1")
    .bind(vaultId).first<{ changes_pruned_through: number }>();
  const devices = await env.DB.prepare(
    "SELECT * FROM devices WHERE vault_id = ?1 AND revoked_at IS NULL ORDER BY created_at ASC",
  ).bind(vaultId).all<DeviceRow>();
  const ownDevice = devices.results.find((device) => device.id === ownDeviceId);
  if (!ownDevice) throw new ApiError(401, "invalid_token", "The device token is invalid");
  const history = await readHistoryPage(env, vaultId, historyCursor, Number(vault?.changes_pruned_through ?? 0));
  const utcDay = new Date(now).toISOString().slice(0, 10);
  const used = ownDevice.sync_utc_day === utcDay ? ownDevice.sync_count : 0;
  let nextAllowed = ownDevice.last_sync_at === null
    ? now
    : ownDevice.last_sync_at + serviceLimits.minimumSyncIntervalSeconds * 1_000;
  if (serviceLimits.dailySyncLimit > 0 && used >= serviceLimits.dailySyncLimit) {
    nextAllowed = Math.max(nextAllowed, Date.parse(`${utcDay}T00:00:00.000Z`) + 24 * 60 * 60 * 1_000);
  }
  const currentSnapshots = devices.results
    .filter((device) => device.id !== ownDeviceId)
    .map(currentRecord)
    .filter((record): record is EncryptedRecord => record !== null);
  const wireDevices = devices.results.map((device) => {
    const wire: Record<string, unknown> = {
      deviceId: device.id,
      lastSyncAt: device.last_sync_at === null ? null : isoTime(device.last_sync_at),
      revoked: false,
    };
    if (device.profile_nonce && device.profile_ciphertext && device.profile_tag) {
      wire.encryptedDeviceProfile = {
        nonce: device.profile_nonce,
        ciphertext: device.profile_ciphertext,
        tag: device.profile_tag,
      };
    }
    return wire;
  });
  return {
    serverTime: isoTime(now),
    nextAllowedSyncAt: isoTime(nextAllowed),
    remainingDailySyncs: remainingDailySyncs(serviceLimits, used),
    activeDeviceCount: devices.results.length,
    currentSnapshots,
    historyChanges: history.changes,
    historyHasMore: history.hasMore,
    cursor: history.cursor,
    devices: wireDevices,
  };
}

function rateLimitError(retryAt: number, now: number, message: string): ApiError {
  return new ApiError(429, "rate_limited", message, {
    "retry-after": String(Math.max(1, Math.ceil((retryAt - now) / 1_000))),
    "x-ratelimit-reset": isoTime(retryAt),
  });
}
