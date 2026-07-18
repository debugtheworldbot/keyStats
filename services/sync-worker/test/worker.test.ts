import { env, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { enforceHourlyLimit } from "../src/auth";
import { CLEANUP_SUBREQUEST_BUDGET, runCleanup } from "../src/cleanup";
import { validateEnvelope } from "../src/crypto";
import { hourlyRateLimitsEnabled, limits, type Env } from "../src/env";
import { ApiError, readJson } from "../src/http";
import { remainingDailySyncs } from "../src/sync";
import type { EncryptedEnvelope, EncryptedRecord } from "../src/types";
import { RequestValidationError, validator } from "../src/validation";

const VAULT_A = "11111111-1111-4111-8111-111111111111";
const DEVICE_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const DEVICE_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const VAULT_C = "33333333-3333-4333-8333-333333333333";
const DEVICE_C = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const RECOVERY_A = base64Url(new Uint8Array(32).fill(7));
const RECOVERY_C = base64Url(new Uint8Array(32).fill(9));

interface VaultResponse {
  vaultId: string;
  deviceId: string;
  deviceToken: string;
  activeDeviceCount: number;
}

interface PairingResponse {
  sessionId: string;
  code: string;
  completionToken: string;
}

describe("sync Worker", () => {
  it("only exposes expected request validation failures as client errors", () => {
    let validationFailure: unknown;
    try {
      validator(() => {
        throw new RequestValidationError("field is invalid");
      });
    } catch (error) {
      validationFailure = error;
    }
    expect(validationFailure).toBeInstanceOf(ApiError);
    expect(validationFailure).toMatchObject({
      status: 400,
      code: "invalid_request",
    });
    expect((validationFailure as ApiError).message).toBe("field is invalid");

    const internalFailure = new Error("internal crypto detail");
    expect(() => validator(() => {
      throw internalFailure;
    })).toThrow(internalFailure);
  });

  it("supports disabling staging sync rate limits", async () => {
    const stagingEnv = {
      HOURLY_RATE_LIMITS_ENABLED: "false",
      MIN_SYNC_INTERVAL_SECONDS: "0",
      DAILY_SYNC_LIMIT: "0",
    } as unknown as Env;
    const serviceLimits = limits(stagingEnv);

    expect(hourlyRateLimitsEnabled(stagingEnv)).toBe(false);
    expect(serviceLimits.minimumSyncIntervalSeconds).toBe(0);
    expect(serviceLimits.dailySyncLimit).toBe(0);
    expect(remainingDailySyncs(serviceLimits, 0)).toBe(8);
    expect(remainingDailySyncs(serviceLimits, 20)).toBe(8);
    await expect(enforceHourlyLimit(
      new Request("https://sync.test/v1/pairing-sessions"),
      stagingEnv,
      "pairing_create",
      5,
      Date.now(),
    )).resolves.toBeUndefined();
  });

  it("cancels an oversized streaming body before reading the remainder", async () => {
    let cancelled = false;
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode("123456789"));
      },
      cancel() {
        cancelled = true;
      },
    });
    const request = new Request("https://sync.test/unit", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body,
    });
    let thrown: unknown;
    try {
      await readJson(request, 8);
    } catch (error) {
      thrown = error;
    }
    expect(thrown).toBeInstanceOf(ApiError);
    expect((thrown as ApiError).status).toBe(413);
    expect(cancelled).toBe(true);
  });

  it("rejects a sync request body above two MiB", async () => {
    const created = await createVault(VAULT_A, DEVICE_A, RECOVERY_A);
    const response = await SELF.fetch("https://sync.test/v1/sync", {
      method: "POST",
      headers: {
        authorization: `Bearer ${created.deviceToken}`,
        "content-type": "application/json",
        "idempotency-key": "oversized-sync-body",
      },
      body: `{"padding":"${"x".repeat(2 * 1_024 * 1_024)}"}`,
    });
    expect(response.status).toBe(413);
  });

  it("strictly validates request properties, required sync fields, limits, and safe integers", async () => {
    const created = await createVault(VAULT_A, DEVICE_A, RECOVERY_A);
    const invalidTopLevel = await post("/v1/vaults", {
      vaultId: VAULT_C,
      deviceId: DEVICE_C,
      deviceToken: tokenFor(DEVICE_C),
      recoveryAuthToken: RECOVERY_C,
      encryptedDeviceProfile: envelope([1]),
      unexpected: true,
    });
    expect(invalidTopLevel.status).toBe(400);
    expect(await errorCode(invalidTopLevel)).toBe("invalid_request");

    const invalidProfile = await post("/v1/vaults", {
      vaultId: VAULT_C,
      deviceId: DEVICE_C,
      deviceToken: tokenFor(DEVICE_C),
      recoveryAuthToken: RECOVERY_C,
      encryptedDeviceProfile: { ...envelope([1]), unexpected: true },
    });
    expect(invalidProfile.status).toBe(400);
    expect(() => validateEnvelope({ ...envelope([1]), unexpected: true }, "encryptedGrant", 4_096)).toThrow(
      "encryptedGrant.unexpected is not allowed",
    );

    for (const invalidBody of [
      { reason: "bootstrap", archives: [] },
      { reason: "bootstrap", historyCursor: 0 },
      { reason: "bootstrap", historyCursor: 0, archives: [], unexpected: true },
      { reason: "manual", historyCursor: 0, archives: [], bootstrapComplete: false },
    ]) {
      const response = await sync(created.deviceToken, `invalid-${crypto.randomUUID()}`, invalidBody);
      expect(response.status).toBe(400);
      expect(await errorCode(response)).toBe("invalid_request");
    }

    const unsafe = await encryptedRecord(DEVICE_A, recordId(90), Number.MAX_SAFE_INTEGER, [1]);
    const unsafeRevision = await sync(created.deviceToken, "unsafe-revision", {
      reason: "bootstrap",
      historyCursor: 0,
      archives: [{ ...unsafe, revision: Number.MAX_SAFE_INTEGER + 1 }],
    });
    expect(unsafeRevision.status).toBe(400);

    const recordWithExtra = { ...await encryptedRecord(DEVICE_A, recordId(91), 1, [1]), unexpected: true };
    const extraRecordProperty = await sync(created.deviceToken, "extra-record", {
      reason: "bootstrap",
      historyCursor: 0,
      archives: [recordWithExtra],
    });
    expect(extraRecordProperty.status).toBe(400);

    const tooManyArchives = await Promise.all(Array.from({ length: 17 }, (_, index) =>
      encryptedRecord(DEVICE_A, recordId(index + 100), 1, [index])));
    const archiveLimit = await sync(created.deviceToken, "archive-limit", {
      reason: "bootstrap",
      historyCursor: 0,
      archives: tooManyArchives,
    });
    expect(archiveLimit.status).toBe(400);

    await env.DB.prepare("UPDATE devices SET exempt_sync_page_count = 256 WHERE id = ?1")
      .bind(DEVICE_A).run();
    const pageLimit = await sync(created.deviceToken, "bootstrap-page-limit", {
      reason: "bootstrap",
      historyCursor: 0,
      archives: [],
      bootstrapComplete: true,
    });
    expect(pageLimit.status).toBe(409);
    expect(await errorCode(pageLimit)).toBe("bootstrap_page_limit");
  });

  it("binds client-generated vault tokens and replays an exact create after response loss", async () => {
    const requestBody = {
      vaultId: VAULT_A,
      deviceId: DEVICE_A,
      deviceToken: tokenFor(DEVICE_A, 11),
      recoveryAuthToken: RECOVERY_A,
      encryptedDeviceProfile: envelope([11, 12, 13]),
    };
    const first = await post("/v1/vaults", requestBody);
    expect(first.status).toBe(201);
    expect(await first.json()).toMatchObject({ deviceToken: requestBody.deviceToken });

    const replay = await post("/v1/vaults", requestBody);
    expect(replay.status).toBe(201);
    expect(await replay.json()).toMatchObject({ deviceToken: requestBody.deviceToken });
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM devices").first("count")).toBe(1);
    expect(await env.DB.prepare(
      "SELECT request_count FROM rate_limits WHERE endpoint = 'vault_create'",
    ).first("request_count")).toBe(1);

    const wrongBinding = await post("/v1/vaults", {
      ...requestBody,
      vaultId: VAULT_C,
      deviceToken: tokenFor(DEVICE_C, 11),
    });
    expect(wrongBinding.status).toBe(400);
    expect(await errorCode(wrongBinding)).toBe("invalid_request");

    const conflictingReplay = await post("/v1/vaults", {
      ...requestBody,
      encryptedDeviceProfile: envelope([99]),
    });
    expect(conflictingReplay.status).toBe(409);
    expect(await errorCode(conflictingReplay)).toBe("vault_conflict");
  });

  it("allows the one-time bootstrap but blocks ordinary single-device sync", async () => {
    const created = await createVault(VAULT_A, DEVICE_A, RECOVERY_A);
    const manual = await sync(created.deviceToken, "manual-one", { reason: "manual", historyCursor: 0, archives: [] });
    expect(manual.status).toBe(409);
    expect(await manual.json()).toMatchObject({
      code: "single_device_sync_disabled",
      activeDeviceCount: 1,
    });

    const record = await encryptedRecord(DEVICE_A, recordId(1), 1, [1, 2, 3]);
    const body = { reason: "bootstrap", historyCursor: 0, currentSnapshot: record, archives: [] };
    const bootstrap = await sync(created.deviceToken, "bootstrap-one", body);
    expect(bootstrap.status).toBe(200);
    expect((await bootstrap.json() as { activeDeviceCount: number }).activeDeviceCount).toBe(1);

    const replay = await sync(created.deviceToken, "bootstrap-one", body);
    expect(replay.status).toBe(200);
    const repeatedBootstrap = await sync(created.deviceToken, "bootstrap-two", body);
    expect(repeatedBootstrap.status).toBe(409);
    expect(await errorCode(repeatedBootstrap)).toBe("bootstrap_already_consumed");
  });

  it("pairs a second device and enforces idempotency, cooldown, and the UTC daily cap", async () => {
    const created = await createVault(VAULT_A, DEVICE_A, RECOVERY_A);
    const paired = await pairDevice(created.deviceToken, DEVICE_B);
    expect(paired.activeDeviceCount).toBe(2);

    const first = await sync(created.deviceToken, "ordinary-01", { reason: "manual", historyCursor: 0, archives: [] });
    expect(first.status).toBe(200);
    const replay = await sync(created.deviceToken, "ordinary-01", { reason: "manual", historyCursor: 0, archives: [] });
    expect(replay.status).toBe(200);
    const cooldown = await sync(created.deviceToken, "ordinary-02", { reason: "manual", historyCursor: 0, archives: [] });
    expect(cooldown.status).toBe(429);
    expect(Number(cooldown.headers.get("retry-after"))).toBeGreaterThan(0);

    for (let index = 2; index <= 8; index += 1) {
      await env.DB.prepare("UPDATE devices SET last_sync_at = 0 WHERE id = ?1").bind(DEVICE_A).run();
      const response = await sync(
        created.deviceToken,
        `ordinary-${String(index).padStart(2, "0")}`,
        { reason: "manual", historyCursor: 0, archives: [] },
      );
      expect(response.status).toBe(200);
    }
    await env.DB.prepare("UPDATE devices SET last_sync_at = 0 WHERE id = ?1").bind(DEVICE_A).run();
    const ninth = await sync(created.deviceToken, "ordinary-09", { reason: "manual", historyCursor: 0, archives: [] });
    expect(ninth.status).toBe(429);
    expect(await errorCode(ninth)).toBe("rate_limited");
  });

  it("opens the approver pairing refresh only after the joining device finishes bootstrap", async () => {
    const created = await createVault(VAULT_A, DEVICE_A, RECOVERY_A);
    expect((await sync(created.deviceToken, "approver-initial-bootstrap", {
      reason: "bootstrap",
      historyCursor: 0,
      archives: [],
    })).status).toBe(200);
    const paired = await pairDevice(created.deviceToken, DEVICE_B);

    const tooEarly = await sync(created.deviceToken, "approver-refresh-too-early", {
      reason: "pairing",
      historyCursor: 0,
      archives: [],
    });
    expect(tooEarly.status).toBe(409);
    expect(await errorCode(tooEarly)).toBe("bootstrap_already_consumed");

    expect((await sync(paired.newDeviceToken, "joining-device-bootstrap", {
      reason: "bootstrap",
      historyCursor: 0,
      archives: [],
    })).status).toBe(200);
    expect((await sync(created.deviceToken, "approver-refresh-after-bootstrap", {
      reason: "pairing",
      historyCursor: 0,
      archives: [],
    })).status).toBe(200);

    const repeated = await sync(created.deviceToken, "approver-refresh-repeated", {
      reason: "pairing",
      historyCursor: 0,
      archives: [],
    });
    expect(repeated.status).toBe(409);
    expect(await errorCode(repeated)).toBe("bootstrap_already_consumed");
  });

  it("pairs over an existing same-vault identity without duplicating it and replays the completed grant", async () => {
    const created = await createVault(VAULT_A, DEVICE_A, RECOVERY_A);
    const paired = await pairDevice(created.deviceToken, DEVICE_B);
    const acceptedCurrent = await encryptedRecord(DEVICE_A, recordId(75), 3, [7, 5]);
    expect((await sync(created.deviceToken, "pair-takeover-bootstrap", {
      reason: "bootstrap",
      historyCursor: 0,
      currentSnapshot: acceptedCurrent,
      archives: [],
    })).status).toBe(200);

    const joiningPublicKey = btoa(String.fromCharCode(...new Uint8Array(32).fill(6)));
    const approvingPublicKey = btoa(String.fromCharCode(...new Uint8Array(32).fill(7)));
    const create = await post("/v1/pairing-sessions", { deviceId: DEVICE_A, joiningPublicKey });
    expect(create.status).toBe(201);
    const session = await create.json() as PairingResponse;
    const join = await post(`/v1/pairing-sessions/${session.code}/join`, {
      approvingPublicKey,
    }, paired.newDeviceToken);
    expect(join.status).toBe(200);
    expect(await join.json()).toMatchObject({ replacedExistingDevice: true, joiningDeviceId: DEVICE_A });

    const replacementToken = tokenFor(DEVICE_A, 77);
    expect((await post(`/v1/pairing-sessions/${session.sessionId}/approve`, {
      approvingPublicKey,
      encryptedGrant: envelope([77]),
      newDeviceToken: replacementToken,
    }, paired.newDeviceToken)).status).toBe(204);
    const completionBody = {
      completionToken: session.completionToken,
      encryptedDeviceProfile: envelope([78]),
    };
    const completed = await post(`/v1/pairing-sessions/${session.sessionId}/complete`, completionBody);
    expect(completed.status).toBe(200);
    expect(await completed.json()).toMatchObject({
      replacedExistingDevice: true,
      activeDeviceCount: 2,
      approvingPublicKey,
      encryptedGrant: envelope([77]),
    });
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM devices WHERE vault_id = ?1 AND revoked_at IS NULL",
    ).bind(VAULT_A).first("count")).toBe(2);
    expect((await SELF.fetch("https://sync.test/v1/state", {
      headers: { authorization: `Bearer ${created.deviceToken}` },
    })).status).toBe(401);

    const newState = await SELF.fetch("https://sync.test/v1/state", {
      headers: { authorization: `Bearer ${replacementToken}` },
    });
    expect(newState.status).toBe(200);
    expect((await newState.json() as { currentSnapshots: EncryptedRecord[] }).currentSnapshots)
      .toContainEqual(acceptedCurrent);
    expect(await env.DB.prepare(
      "SELECT bootstrap_consumed_at FROM devices WHERE id = ?1",
    ).bind(DEVICE_A).first("bootstrap_consumed_at")).toBeNull();

    const replay = await post(`/v1/pairing-sessions/${session.sessionId}/complete`, completionBody);
    expect(replay.status).toBe(200);
    expect(await replay.json()).toMatchObject({
      approvingPublicKey,
      encryptedGrant: envelope([77]),
      replacedExistingDevice: true,
    });
    const conflictingProfile = await post(`/v1/pairing-sessions/${session.sessionId}/complete`, {
      completionToken: session.completionToken,
      encryptedDeviceProfile: envelope([79]),
    });
    expect(conflictingProfile.status).toBe(409);
    expect(await errorCode(conflictingProfile)).toBe("pairing_profile_conflict");

    await createVault(VAULT_C, DEVICE_C, RECOVERY_C);
    const crossVaultSession = await post("/v1/pairing-sessions", { deviceId: DEVICE_C, joiningPublicKey });
    expect(crossVaultSession.status).toBe(201);
    const crossVault = await crossVaultSession.json() as PairingResponse;
    const rejectedCollision = await post(`/v1/pairing-sessions/${crossVault.code}/join`, {
      approvingPublicKey,
    }, replacementToken);
    expect(rejectedCollision.status).toBe(409);
    expect(await errorCode(rejectedCollision)).toBe("device_conflict");

    await env.DB.prepare("UPDATE pairing_sessions SET expires_at = 1 WHERE id = ?1")
      .bind(session.sessionId).run();
    const expiredReplay = await post(`/v1/pairing-sessions/${session.sessionId}/complete`, {
      completionToken: session.completionToken,
    });
    expect(expiredReplay.status).toBe(410);
    expect(await errorCode(expiredReplay)).toBe("pairing_expired");
  });

  it("archives replaced current records, rejects revision conflicts, and isolates vault tokens", async () => {
    const created = await createVault(VAULT_A, DEVICE_A, RECOVERY_A);
    const paired = await pairDevice(created.deviceToken, DEVICE_B);
    const dayOne = await encryptedRecord(DEVICE_A, recordId(1), 1, [4, 5, 6]);
    expect((await sync(created.deviceToken, "bootstrap-a", {
      reason: "bootstrap",
      historyCursor: 0,
      currentSnapshot: dayOne,
      archives: [],
    })).status).toBe(200);

    const conflict = await encryptedRecord(DEVICE_A, dayOne.recordId, 1, [8, 8, 8]);
    await env.DB.prepare("UPDATE devices SET last_sync_at = 0 WHERE id = ?1").bind(DEVICE_A).run();
    const conflictResponse = await sync(created.deviceToken, "conflict-a", {
      reason: "manual",
      historyCursor: 0,
      currentSnapshot: conflict,
      archives: [],
    });
    expect(conflictResponse.status).toBe(409);
    expect(await errorCode(conflictResponse)).toBe("revision_conflict");

    await env.DB.prepare("UPDATE devices SET last_sync_at = 0 WHERE id = ?1").bind(DEVICE_A).run();
    const dayTwo = await encryptedRecord(DEVICE_A, recordId(2), 1, [9, 10]);
    const replacementRequest = {
      reason: "manual",
      historyCursor: 0,
      currentSnapshot: dayTwo,
      archives: [dayOne],
    };
    const replacement = await sync(created.deviceToken, "replace-a", replacementRequest);
    expect(replacement.status).toBe(200);
    const replacementBody = await replacement.json() as { historyChanges: Array<{ recordId: string }> };
    expect(replacementBody.historyChanges.map((change) => change.recordId)).toContain(dayOne.recordId);

    const history = await SELF.fetch("https://sync.test/v1/history?cursor=0", {
      headers: { authorization: `Bearer ${created.deviceToken}` },
    });
    expect(history.status).toBe(200);
    expect((await history.json() as { changes: Array<{ record: EncryptedRecord }> }).changes[0]?.record).toEqual(dayOne);

    const syncCount = await env.DB.prepare("SELECT sync_count FROM devices WHERE id = ?1")
      .bind(DEVICE_A).first<number>("sync_count");
    await env.DB.prepare("DELETE FROM history_changes WHERE vault_id = ?1 AND record_id = ?2")
      .bind(VAULT_A, dayOne.recordId).run();
    expect((await sync(created.deviceToken, "replace-a", replacementRequest)).status).toBe(200);
    expect(await env.DB.prepare("SELECT sync_count FROM devices WHERE id = ?1")
      .bind(DEVICE_A).first("sync_count")).toBe(syncCount);
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM history_changes WHERE vault_id = ?1 AND record_id = ?2",
    ).bind(VAULT_A, dayOne.recordId).first("count")).toBe(1);

    const otherVault = await createVault(VAULT_C, DEVICE_C, RECOVERY_C);
    const crossVaultDelete = await SELF.fetch(`https://sync.test/v1/devices/${DEVICE_B}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${otherVault.deviceToken}` },
    });
    expect(crossVaultDelete.status).toBe(404);

    const revoke = await SELF.fetch(`https://sync.test/v1/devices/${DEVICE_B}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${created.deviceToken}` },
    });
    expect(revoke.status).toBe(204);
    const revokedAuth = await SELF.fetch("https://sync.test/v1/history?cursor=0", {
      headers: { authorization: `Bearer ${paired.newDeviceToken}` },
    });
    expect(revokedAuth.status).toBe(401);

    await env.DB.prepare("UPDATE devices SET last_sync_at = 0 WHERE id = ?1").bind(DEVICE_A).run();
    const learnedSingleDevice = await sync(created.deviceToken, "single-after-revoke", {
      reason: "manual",
      historyCursor: 0,
      archives: [],
    });
    expect(learnedSingleDevice.status).toBe(409);
    expect(await learnedSingleDevice.json()).toMatchObject({
      code: "single_device_sync_disabled",
      activeDeviceCount: 1,
    });
  });

  it("archives the persisted previous current even when a full archive page omits it", async () => {
    const created = await createVault(VAULT_A, DEVICE_A, RECOVERY_A);
    await pairDevice(created.deviceToken, DEVICE_B);
    const previousCurrent = await encryptedRecord(DEVICE_A, recordId(60), 3, [6, 0]);
    expect((await sync(created.deviceToken, "rollover-server-bootstrap", {
      reason: "bootstrap",
      historyCursor: 0,
      currentSnapshot: previousCurrent,
      archives: [],
    })).status).toBe(200);

    const backlog = await Promise.all(Array.from({ length: 16 }, (_, index) =>
      encryptedRecord(DEVICE_A, recordId(70 + index), 1, [index])));
    const nextCurrent = await encryptedRecord(DEVICE_A, recordId(61), 1, [6, 1]);
    await env.DB.prepare("UPDATE devices SET last_sync_at = 0 WHERE id = ?1").bind(DEVICE_A).run();
    const rollover = await sync(created.deviceToken, "rollover-server-handoff", {
      reason: "manual",
      historyCursor: 0,
      currentSnapshot: nextCurrent,
      archives: backlog,
    });
    expect(rollover.status).toBe(200);
    const response = await rollover.json() as { historyChanges: Array<{ recordId: string }> };
    expect(response.historyChanges.map((change) => change.recordId)).toContain(previousCurrent.recordId);
    expect(await env.DB.prepare(
      "SELECT current_record_id, current_revision FROM devices WHERE id = ?1",
    ).bind(DEVICE_A).first()).toEqual({ current_record_id: nextCurrent.recordId, current_revision: 1 });
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM history_changes WHERE vault_id = ?1",
    ).bind(VAULT_A).first("count")).toBe(17);
  });

  it("rejects a stale previous-current archive before replacing the current record", async () => {
    const created = await createVault(VAULT_A, DEVICE_A, RECOVERY_A);
    await pairDevice(created.deviceToken, DEVICE_B);
    const serverCurrent = await encryptedRecord(DEVICE_A, recordId(31), 2, [2]);
    expect((await sync(created.deviceToken, "stale-rollover-bootstrap", {
      reason: "bootstrap",
      historyCursor: 0,
      currentSnapshot: serverCurrent,
      archives: [],
    })).status).toBe(200);

    await env.DB.prepare("UPDATE devices SET last_sync_at = 0 WHERE id = ?1").bind(DEVICE_A).run();
    const stalePrevious = await encryptedRecord(DEVICE_A, serverCurrent.recordId, 1, [1]);
    const nextCurrent = await encryptedRecord(DEVICE_A, recordId(32), 1, [3]);
    const rejected = await sync(created.deviceToken, "stale-rollover", {
      reason: "manual",
      historyCursor: 0,
      currentSnapshot: nextCurrent,
      archives: [stalePrevious],
    });
    expect(rejected.status).toBe(409);
    expect(await errorCode(rejected)).toBe("stale_revision");
    expect(await env.DB.prepare(
      "SELECT current_record_id, current_revision FROM devices WHERE id = ?1",
    ).bind(DEVICE_A).first()).toEqual({
      current_record_id: serverCurrent.recordId,
      current_revision: 2,
    });
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM history_changes WHERE vault_id = ?1",
    ).bind(VAULT_A).first("count")).toBe(0);
  });

  it("resumes an interrupted self-revocation with the revoked device token", async () => {
    const created = await createVault(VAULT_A, DEVICE_A, RECOVERY_A);
    const paired = await pairDevice(created.deviceToken, DEVICE_B);
    const current = await encryptedRecord(DEVICE_A, recordId(35), 1, [3, 5]);
    expect((await sync(created.deviceToken, "revoke-resume-bootstrap", {
      reason: "bootstrap",
      historyCursor: 0,
      currentSnapshot: current,
      archives: [],
    })).status).toBe(200);

    // Model a request that reached the durable revocation point and then lost
    // its R2 write/response. The normal authenticator now rejects this token;
    // DELETE for the same device must still be able to finish the archive.
    await env.DB.prepare("UPDATE devices SET revoked_at = 1 WHERE id = ?1").bind(DEVICE_A).run();
    const resumed = await SELF.fetch(`https://sync.test/v1/devices/${DEVICE_A}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${created.deviceToken}` },
    });
    expect(resumed.status).toBe(204);
    expect(await env.DB.prepare(
      `SELECT revoked_at, current_record_id, current_revision, current_ciphertext
         FROM devices WHERE id = ?1`,
    ).bind(DEVICE_A).first()).toEqual({
      revoked_at: 1,
      current_record_id: null,
      current_revision: null,
      current_ciphertext: null,
    });
    expect(await env.DB.prepare(
      "SELECT revision FROM history_changes WHERE vault_id = ?1 AND record_id = ?2",
    ).bind(VAULT_A, current.recordId).first("revision")).toBe(1);

    const repeated = await SELF.fetch(`https://sync.test/v1/devices/${DEVICE_A}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${created.deviceToken}` },
    });
    expect(repeated.status).toBe(204);
    expect((await SELF.fetch("https://sync.test/v1/history?cursor=0", {
      headers: { authorization: `Bearer ${paired.newDeviceToken}` },
    })).status).toBe(200);
    expect((await SELF.fetch("https://sync.test/v1/history?cursor=0", {
      headers: { authorization: `Bearer ${created.deviceToken}` },
    })).status).toBe(401);
  });

  it("does not lose the winning current revision when sync races revocation", async () => {
    const created = await createVault(VAULT_A, DEVICE_A, RECOVERY_A);
    const paired = await pairDevice(created.deviceToken, DEVICE_B);
    const first = await encryptedRecord(DEVICE_A, recordId(36), 1, [1]);
    expect((await sync(created.deviceToken, "revoke-race-bootstrap", {
      reason: "bootstrap",
      historyCursor: 0,
      currentSnapshot: first,
      archives: [],
    })).status).toBe(200);
    await env.DB.prepare("UPDATE devices SET last_sync_at = 0 WHERE id = ?1").bind(DEVICE_A).run();

    const second = await encryptedRecord(DEVICE_A, first.recordId, 2, [2]);
    const idempotencyKey = "revoke-race-sync";
    const [syncResponse, revokeResponse] = await Promise.all([
      sync(created.deviceToken, idempotencyKey, {
        reason: "manual",
        historyCursor: 0,
        currentSnapshot: second,
        archives: [],
      }),
      SELF.fetch(`https://sync.test/v1/devices/${DEVICE_A}`, {
        method: "DELETE",
        headers: { authorization: `Bearer ${paired.newDeviceToken}` },
      }),
    ]);
    expect([200, 401, 409, 429]).toContain(syncResponse.status);
    expect(revokeResponse.status).toBe(204);

    const device = await env.DB.prepare(
      `SELECT revoked_at, current_record_id, last_idempotency_key
         FROM devices WHERE id = ?1`,
    ).bind(DEVICE_A).first<{
      revoked_at: number | null;
      current_record_id: string | null;
      last_idempotency_key: string | null;
    }>();
    expect(device?.revoked_at).not.toBeNull();
    expect(device?.current_record_id).toBeNull();
    const expectedRevision = device?.last_idempotency_key === idempotencyKey ? 2 : 1;
    expect(await env.DB.prepare(
      `SELECT MAX(revision) AS revision
         FROM history_changes WHERE vault_id = ?1 AND record_id = ?2`,
    ).bind(VAULT_A, first.recordId).first("revision")).toBe(expectedRevision);
  });

  it("reserves a concurrent sync before writing its history records", async () => {
    const created = await createVault(VAULT_A, DEVICE_A, RECOVERY_A);
    await pairDevice(created.deviceToken, DEVICE_B);
    const previous = await encryptedRecord(DEVICE_A, recordId(41), 1, [1]);
    expect((await sync(created.deviceToken, "concurrent-bootstrap", {
      reason: "bootstrap",
      historyCursor: 0,
      currentSnapshot: previous,
      archives: [],
    })).status).toBe(200);
    await env.DB.prepare("UPDATE devices SET last_sync_at = 0 WHERE id = ?1").bind(DEVICE_A).run();

    const candidates = await Promise.all([42, 43].map(async (value) => ({
      idempotencyKey: `concurrent-${value}`,
      body: {
        reason: "manual",
        historyCursor: 0,
        currentSnapshot: await encryptedRecord(DEVICE_A, recordId(value), 1, [value]),
        archives: [previous],
      },
    })));
    const responses = await Promise.all(candidates.map((candidate) =>
      sync(created.deviceToken, candidate.idempotencyKey, candidate.body)));
    expect(responses.filter((response) => response.status === 200)).toHaveLength(1);
    expect(responses.filter((response) => response.status !== 200)).toHaveLength(1);
    expect([409, 429]).toContain(responses.find((response) => response.status !== 200)?.status);
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM history_changes WHERE vault_id = ?1",
    ).bind(VAULT_A).first("count")).toBe(1);
    expect((await env.HISTORY.list({ prefix: `history/${VAULT_A}/` })).objects).toHaveLength(1);
    expect(await env.DB.prepare("SELECT sync_count FROM devices WHERE id = ?1")
      .bind(DEVICE_A).first("sync_count")).toBe(1);
  });

  it("rate-limits recovery attempts without exposing whether a vault exists", async () => {
    await createVault(VAULT_A, DEVICE_A, RECOVERY_A);
    const invalidRecovery = base64Url(new Uint8Array(32).fill(99));
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const deviceId = `0000000${attempt}-0000-4000-8000-00000000000${attempt}`;
      const response = await post("/v1/recover", {
        recoveryAuthToken: invalidRecovery,
        deviceId,
        deviceToken: tokenFor(deviceId, attempt + 20),
      });
      expect(response.status).toBe(401);
    }
    const limited = await post("/v1/recover", {
      recoveryAuthToken: RECOVERY_A,
      deviceId: DEVICE_B,
      deviceToken: tokenFor(DEVICE_B),
    });
    expect(limited.status).toBe(429);
    expect(Number(limited.headers.get("retry-after"))).toBeGreaterThan(0);
    for (let attempt = 0; attempt < 20; attempt += 1) {
      expect((await post("/v1/recover", {
        recoveryAuthToken: RECOVERY_A,
        deviceId: DEVICE_B,
        deviceToken: tokenFor(DEVICE_B),
      })).status).toBe(429);
    }
    expect(await env.DB.prepare(
      "SELECT request_count FROM rate_limits WHERE endpoint = 'recovery_ip'",
    ).first("request_count")).toBe(5);
  });

  it("recovers an existing identity in place, preserves its current revision, and exposes read-only state", async () => {
    const created = await createVault(VAULT_A, DEVICE_A, RECOVERY_A);
    const paired = await pairDevice(created.deviceToken, DEVICE_B);
    const acceptedCurrent = await encryptedRecord(DEVICE_A, recordId(71), 7, [7, 1]);
    expect((await sync(created.deviceToken, "recovery-current-bootstrap", {
      reason: "bootstrap",
      historyCursor: 0,
      currentSnapshot: acceptedCurrent,
      archives: [],
    })).status).toBe(200);

    const replacementToken = tokenFor(DEVICE_A, 71);
    const recoveryRequest = {
      recoveryAuthToken: RECOVERY_A,
      deviceId: DEVICE_A,
      deviceToken: replacementToken,
      replaceDeviceId: DEVICE_A,
    };
    const recovered = await post("/v1/recover", recoveryRequest);
    expect(recovered.status).toBe(200);
    expect(await recovered.json()).toMatchObject({
      vaultId: VAULT_A,
      deviceId: DEVICE_A,
      deviceToken: replacementToken,
      activeDeviceCount: 2,
      cursor: 0,
      currentSnapshot: acceptedCurrent,
    });
    expect((await SELF.fetch("https://sync.test/v1/state", {
      headers: { authorization: `Bearer ${created.deviceToken}` },
    })).status).toBe(401);

    const beforeState = await env.DB.prepare(
      "SELECT sync_count, last_sync_at FROM devices WHERE id = ?1",
    ).bind(DEVICE_A).first();
    const stateResponse = await SELF.fetch("https://sync.test/v1/state", {
      headers: { authorization: `Bearer ${replacementToken}` },
    });
    expect(stateResponse.status).toBe(200);
    const stateBody = await stateResponse.json() as {
      activeDeviceCount: number;
      currentSnapshots: EncryptedRecord[];
      devices: Array<{ deviceId: string }>;
    };
    expect(stateBody.activeDeviceCount).toBe(2);
    expect(stateBody.currentSnapshots).toContainEqual(acceptedCurrent);
    expect(stateBody.devices.map((device) => device.deviceId).sort()).toEqual([DEVICE_A, DEVICE_B].sort());
    expect(await env.DB.prepare(
      "SELECT sync_count, last_sync_at FROM devices WHERE id = ?1",
    ).bind(DEVICE_A).first()).toEqual(beforeState);

    expect((await sync(replacementToken, "recovery-bootstrap-after-takeover", {
      reason: "recovery",
      historyCursor: 0,
      archives: [],
      encryptedDeviceProfile: envelope([71]),
    })).status).toBe(200);
    const consumedAt = await env.DB.prepare(
      "SELECT bootstrap_consumed_at FROM devices WHERE id = ?1",
    ).bind(DEVICE_A).first<number>("bootstrap_consumed_at");
    expect(consumedAt).not.toBeNull();

    const lostResponseReplay = await post("/v1/recover", recoveryRequest);
    expect(lostResponseReplay.status).toBe(200);
    expect(await env.DB.prepare(
      "SELECT bootstrap_consumed_at FROM devices WHERE id = ?1",
    ).bind(DEVICE_A).first("bootstrap_consumed_at")).toBe(consumedAt);
    expect(await env.DB.prepare(
      "SELECT request_count FROM rate_limits WHERE endpoint = 'recovery_vault'",
    ).first("request_count")).toBe(1);

    const unknownId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    const missingReplacement = await post("/v1/recover", {
      recoveryAuthToken: RECOVERY_A,
      deviceId: unknownId,
      deviceToken: tokenFor(unknownId, 72),
      replaceDeviceId: unknownId,
    });
    expect(missingReplacement.status).toBe(409);
    expect(await errorCode(missingReplacement)).toBe("replace_device_not_found");

    expect((await SELF.fetch(`https://sync.test/v1/devices/${DEVICE_B}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${replacementToken}` },
    })).status).toBe(204);
    const reactivatedToken = tokenFor(DEVICE_B, 73);
    const reactivated = await post("/v1/recover", {
      recoveryAuthToken: RECOVERY_A,
      deviceId: DEVICE_B,
      deviceToken: reactivatedToken,
      replaceDeviceId: DEVICE_B,
    });
    expect(reactivated.status).toBe(200);
    expect(await reactivated.json()).toMatchObject({ activeDeviceCount: 2, deviceId: DEVICE_B });
    expect((await SELF.fetch("https://sync.test/v1/state", {
      headers: { authorization: `Bearer ${paired.newDeviceToken}` },
    })).status).toBe(401);
    expect((await SELF.fetch("https://sync.test/v1/state", {
      headers: { authorization: `Bearer ${reactivatedToken}` },
    })).status).toBe(200);
  });

  it("keeps the five-device limit under concurrent recovery", async () => {
    await createVault(VAULT_A, DEVICE_A, RECOVERY_A);
    for (let index = 1; index <= 3; index += 1) {
      const deviceId = `0000000${index}-0000-4000-8000-00000000000${index}`;
      const response = await post("/v1/recover", {
        recoveryAuthToken: RECOVERY_A,
        deviceId,
        deviceToken: tokenFor(deviceId, index + 30),
      });
      expect(response.status).toBe(200);
    }

    const raced = await Promise.all([4, 5].map((index) => {
      const deviceId = `0000000${index}-0000-4000-8000-00000000000${index}`;
      return post("/v1/recover", {
        recoveryAuthToken: RECOVERY_A,
        deviceId,
        deviceToken: tokenFor(deviceId, index + 30),
      });
    }));
    expect(raced.map((response) => response.status).sort()).toEqual([200, 409]);
    const rejected = raced.find((response) => response.status === 409);
    expect(rejected).toBeDefined();
    const rejectedBody = await rejected!.json() as {
      code: string;
      vaultId: string;
      activeDeviceCount: number;
      devices: Array<{ deviceId: string; revoked: boolean }>;
    };
    expect(rejectedBody.code).toBe("maximum_devices");
    expect(rejectedBody.vaultId).toBe(VAULT_A);
    expect(rejectedBody.activeDeviceCount).toBe(5);
    expect(rejectedBody.devices).toHaveLength(5);
    expect(rejectedBody.devices.every((device) => device.revoked === false)).toBe(true);
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM devices WHERE vault_id = ?1 AND revoked_at IS NULL",
    ).bind(VAULT_A).first("count")).toBe(5);

    await env.DB.prepare("DELETE FROM rate_limits WHERE endpoint IN ('recovery_ip', 'recovery_vault')").run();
    const replacementToken = tokenFor(DEVICE_A, 88);
    const takeoverAtCapacity = await post("/v1/recover", {
      recoveryAuthToken: RECOVERY_A,
      deviceId: DEVICE_A,
      deviceToken: replacementToken,
      replaceDeviceId: DEVICE_A,
    });
    expect(takeoverAtCapacity.status).toBe(200);
    expect(await takeoverAtCapacity.json()).toMatchObject({ activeDeviceCount: 5, deviceId: DEVICE_A });
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM devices WHERE vault_id = ?1 AND revoked_at IS NULL",
    ).bind(VAULT_A).first("count")).toBe(5);

    const revokedId = "00000001-0000-4000-8000-000000000001";
    expect((await SELF.fetch(`https://sync.test/v1/devices/${revokedId}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${replacementToken}` },
    })).status).toBe(204);
    const sixthId = "00000006-0000-4000-8000-000000000006";
    expect((await post("/v1/recover", {
      recoveryAuthToken: RECOVERY_A,
      deviceId: sixthId,
      deviceToken: tokenFor(sixthId, 96),
    })).status).toBe(200);
    const blockedReactivation = await post("/v1/recover", {
      recoveryAuthToken: RECOVERY_A,
      deviceId: revokedId,
      deviceToken: tokenFor(revokedId, 97),
      replaceDeviceId: revokedId,
    });
    expect(blockedReactivation.status).toBe(409);
    expect(await blockedReactivation.json()).toMatchObject({
      code: "maximum_devices",
      vaultId: VAULT_A,
      activeDeviceCount: 5,
    });
  });

  it("invalidates every vault token immediately and deletes every tombstoned vault on the next cron", async () => {
    const created = await createVault(VAULT_A, DEVICE_A, RECOVERY_A);
    const recoveredResponse = await post("/v1/recover", {
      recoveryAuthToken: RECOVERY_A,
      deviceId: DEVICE_B,
      deviceToken: tokenFor(DEVICE_B),
    });
    expect(recoveredResponse.status).toBe(200);
    const recovered = await recoveredResponse.json() as VaultResponse;
    const deletion = await SELF.fetch("https://sync.test/v1/vault", {
      method: "DELETE",
      headers: { authorization: `Bearer ${created.deviceToken}` },
    });
    expect(deletion.status).toBe(204);
    const exactRetry = await SELF.fetch("https://sync.test/v1/vault", {
      method: "DELETE",
      headers: { authorization: `Bearer ${created.deviceToken}` },
    });
    expect(exactRetry.status).toBe(204);
    const differentVaultToken = await SELF.fetch("https://sync.test/v1/vault", {
      method: "DELETE",
      headers: { authorization: `Bearer ${recovered.deviceToken}` },
    });
    expect(differentVaultToken.status).toBe(401);
    const otherDelete = await SELF.fetch(`https://sync.test/v1/devices/${DEVICE_B}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${created.deviceToken}` },
    });
    expect(otherDelete.status).toBe(401);
    for (const token of [created.deviceToken, recovered.deviceToken]) {
      const rejected = await SELF.fetch("https://sync.test/v1/history?cursor=0", {
        headers: { authorization: `Bearer ${token}` },
      });
      expect(rejected.status).toBe(401);
    }
    await env.HISTORY.put(`history/${VAULT_A}/object.json`, "ciphertext");
    const now = Date.now();
    for (let index = 0; index < 140; index += 1) {
      const id = `9${String(index).padStart(7, "0")}-9999-4999-8999-${String(index).padStart(12, "0")}`;
      await env.DB.prepare(
        "INSERT INTO vaults(id, recovery_auth_hash, created_at, deleted_at) VALUES (?1, ?2, ?3, ?3)",
      ).bind(id, `deleted-${index}`, now).run();
    }
    const firstCleanup = await runCleanup(env, now);
    expect(firstCleanup.operationsUsed).toBeLessThanOrEqual(CLEANUP_SUBREQUEST_BUDGET);
    expect(await env.DB.prepare("SELECT id FROM vaults WHERE id = ?1").bind(VAULT_A).first()).toBeNull();
    expect((await SELF.fetch("https://sync.test/v1/vault", {
      method: "DELETE",
      headers: { authorization: `Bearer ${created.deviceToken}` },
    })).status).toBe(204);
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM vaults WHERE deleted_at IS NOT NULL",
    ).first<number>("count")).toBeGreaterThan(0);
    const secondCleanup = await runCleanup(env, now + 24 * 60 * 60 * 1_000);
    expect(secondCleanup.operationsUsed).toBeLessThanOrEqual(CLEANUP_SUBREQUEST_BUDGET);
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM vaults WHERE deleted_at IS NOT NULL",
    ).first("count")).toBe(0);
    expect(await env.HISTORY.get(`history/${VAULT_A}/object.json`)).toBeNull();
  });

  it("persists bounded deletion receipts across concurrent delete, physical cleanup, and expiry", async () => {
    const created = await createVault(VAULT_A, DEVICE_A, RECOVERY_A);
    const deleteRequest = () => SELF.fetch("https://sync.test/v1/vault", {
      method: "DELETE",
      headers: { authorization: `Bearer ${created.deviceToken}` },
    });
    const concurrent = await Promise.all([deleteRequest(), deleteRequest()]);
    expect(concurrent.map((response) => response.status)).toEqual([204, 204]);
    const receipt = await env.DB.prepare(
      "SELECT token_hash, created_at, expires_at FROM vault_deletion_receipts LIMIT 1",
    ).first<{ token_hash: string; created_at: number; expires_at: number }>();
    expect(receipt).not.toBeNull();
    expect(receipt!.expires_at - receipt!.created_at).toBe(30 * 24 * 60 * 60 * 1_000);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM vault_deletion_receipts")
      .first("count")).toBe(1);

    const now = Date.now();
    await runCleanup(env, now);
    expect(await env.DB.prepare("SELECT id FROM vaults WHERE id = ?1").bind(VAULT_A).first()).toBeNull();
    expect((await deleteRequest()).status).toBe(204);
    expect((await SELF.fetch("https://sync.test/v1/state", {
      headers: { authorization: `Bearer ${created.deviceToken}` },
    })).status).toBe(401);

    await env.DB.prepare(
      "UPDATE vault_deletion_receipts SET created_at = 0, expires_at = 1 WHERE token_hash = ?1",
    ).bind(receipt!.token_hash).run();
    for (let offset = 0; offset < 150; offset += 50) {
      await env.DB.batch(Array.from({ length: 50 }, (_, index) => env.DB.prepare(
        "INSERT INTO vault_deletion_receipts(token_hash, created_at, expires_at) VALUES (?1, 0, 1)",
      ).bind(`zz-expired-${String(offset + index).padStart(3, "0")}`)));
    }
    const bounded = await runCleanup(env, now + 31 * 24 * 60 * 60 * 1_000);
    expect(bounded.operationsUsed).toBeLessThanOrEqual(CLEANUP_SUBREQUEST_BUDGET);
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM vault_deletion_receipts",
    ).first("count")).toBe(51);
    expect(await env.DB.prepare(
      "SELECT token_hash FROM vault_deletion_receipts WHERE token_hash = ?1",
    ).bind(receipt!.token_hash).first()).toBeNull();
    expect((await deleteRequest()).status).toBe(401);

    await runCleanup(env, now + 32 * 24 * 60 * 60 * 1_000);
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM vault_deletion_receipts",
    ).first("count")).toBe(0);
  });

  it("bounds orphan cleanup and resumes from its persisted R2 cursor", async () => {
    for (let index = 0; index < 81; index += 1) {
      await env.HISTORY.put(`history/orphan/${String(index).padStart(3, "0")}.json`, "ciphertext");
    }
    const now = Date.now() + 2 * 24 * 60 * 60 * 1_000;
    const firstCleanup = await runCleanup(env, now);
    expect(firstCleanup.operationsUsed).toBeLessThanOrEqual(CLEANUP_SUBREQUEST_BUDGET);
    expect((await env.HISTORY.list({ prefix: "history/orphan/" })).objects).toHaveLength(1);
    expect(await env.DB.prepare(
      "SELECT value FROM maintenance_state WHERE key = 'orphan-r2-cursor-v1'",
    ).first()).not.toBeNull();

    const secondCleanup = await runCleanup(env, now + 24 * 60 * 60 * 1_000);
    expect(secondCleanup.operationsUsed).toBeLessThanOrEqual(CLEANUP_SUBREQUEST_BUDGET);
    expect((await env.HISTORY.list({ prefix: "history/orphan/" })).objects).toHaveLength(0);
    expect(await env.DB.prepare(
      "SELECT value FROM maintenance_state WHERE key = 'orphan-r2-cursor-v1'",
    ).first()).toBeNull();
  });

  it("keeps change metadata for 90 days while pruning superseded ciphertext after seven", async () => {
    const created = await createVault(VAULT_A, DEVICE_A, RECOVERY_A);
    await pairDevice(created.deviceToken, DEVICE_B);
    const firstRevision = await encryptedRecord(DEVICE_A, recordId(21), 1, [1]);
    const current = await encryptedRecord(DEVICE_A, recordId(22), 1, [2]);
    expect((await sync(created.deviceToken, "retention-bootstrap", {
      reason: "bootstrap",
      historyCursor: 0,
      currentSnapshot: firstRevision,
      archives: [],
    })).status).toBe(200);
    await env.DB.prepare("UPDATE devices SET last_sync_at = 0 WHERE id = ?1").bind(DEVICE_A).run();
    expect((await sync(created.deviceToken, "retention-rollover", {
      reason: "manual",
      historyCursor: 0,
      currentSnapshot: current,
      archives: [firstRevision],
    })).status).toBe(200);
    const secondRevision = await encryptedRecord(DEVICE_A, firstRevision.recordId, 2, [3]);
    await env.DB.prepare("UPDATE devices SET last_sync_at = 0 WHERE id = ?1").bind(DEVICE_A).run();
    expect((await sync(created.deviceToken, "retention-revision", {
      reason: "manual",
      historyCursor: 0,
      currentSnapshot: current,
      archives: [secondRevision],
    })).status).toBe(200);

    const revisionObjects = await env.DB.prepare(
      `SELECT revision, r2_key
         FROM history_changes
        WHERE vault_id = ?1 AND record_id = ?2
        ORDER BY revision ASC`,
    ).bind(VAULT_A, firstRevision.recordId).all<{ revision: number; r2_key: string }>();
    expect(revisionObjects.results).toHaveLength(2);
    const firstKey = revisionObjects.results[0]!.r2_key;
    const secondKey = revisionObjects.results[1]!.r2_key;
    expect(firstKey).not.toBe(secondKey);
    expect(await env.HISTORY.get(firstKey)).not.toBeNull();
    expect(await env.HISTORY.get(secondKey)).not.toBeNull();

    const now = Date.now();
    await env.DB.prepare(
      "UPDATE history_changes SET created_at = ?1 WHERE vault_id = ?2 AND record_id = ?3 AND revision = 1",
    ).bind(now - 30 * 24 * 60 * 60 * 1_000, VAULT_A, firstRevision.recordId).run();
    await runCleanup(env, now);
    expect(await env.DB.prepare(
      "SELECT payload_pruned, r2_key FROM history_changes WHERE vault_id = ?1 AND record_id = ?2 AND revision = 1",
    ).bind(VAULT_A, firstRevision.recordId).first()).toEqual({ payload_pruned: 0, r2_key: firstKey });
    expect(await env.HISTORY.get(firstKey)).not.toBeNull();

    await runCleanup(env, now + 8 * 24 * 60 * 60 * 1_000);
    const retained = await env.DB.prepare(
      "SELECT payload_pruned, r2_key FROM history_changes WHERE vault_id = ?1 AND record_id = ?2 AND revision = 1",
    ).bind(VAULT_A, firstRevision.recordId).first<{ payload_pruned: number; r2_key: string | null }>();
    expect(retained).toEqual({ payload_pruned: 1, r2_key: null });
    expect(await env.HISTORY.get(firstKey)).toBeNull();
    expect(await env.HISTORY.get(secondKey)).not.toBeNull();
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM history_changes WHERE vault_id = ?1 AND record_id = ?2",
    ).bind(VAULT_A, firstRevision.recordId).first("count")).toBe(2);

    await runCleanup(env, now + 83 * 24 * 60 * 60 * 1_000);
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM history_changes WHERE vault_id = ?1 AND record_id = ?2",
    ).bind(VAULT_A, firstRevision.recordId).first("count")).toBe(1);
  });

  it("advances through a stale-cursor manifest that spans more than one page", async () => {
    const created = await createVault(VAULT_A, DEVICE_A, RECOVERY_A);
    const archives = await Promise.all(Array.from({ length: 101 }, (_, index) =>
      encryptedRecord(DEVICE_A, recordId(index + 101), 1, [index & 0xff])));
    await env.DB.prepare("UPDATE vaults SET changes_pruned_through = ?1 WHERE id = ?2")
      .bind(1_000_000, VAULT_A).run();

    let first: Response | null = null;
    for (let offset = 0; offset < archives.length; offset += 16) {
      const finalPage = offset + 16 >= archives.length;
      const response = await sync(created.deviceToken, `manifest-bootstrap-${offset / 16}`, {
        reason: "bootstrap",
        historyCursor: 0,
        archives: archives.slice(offset, offset + 16),
        bootstrapComplete: finalPage,
      });
      expect(response.status).toBe(200);
      if (!finalPage) {
        expect(await env.DB.prepare("SELECT bootstrap_consumed_at FROM devices WHERE id = ?1")
          .bind(DEVICE_A).first("bootstrap_consumed_at")).toBeNull();
      }
      first = response;
    }
    expect(await env.DB.prepare("SELECT bootstrap_consumed_at FROM devices WHERE id = ?1")
      .bind(DEVICE_A).first("bootstrap_consumed_at")).not.toBeNull();
    expect(first).not.toBeNull();
    const firstPage = await first!.json() as {
      historyChanges: Array<{ recordId: string }>;
      historyHasMore: boolean;
      cursor: number;
    };
    expect(firstPage.historyChanges).toHaveLength(100);
    expect(firstPage.historyHasMore).toBe(true);
    expect(firstPage.cursor).toBeGreaterThan(0);

    const second = await SELF.fetch(`https://sync.test/v1/history?cursor=${firstPage.cursor}`, {
      headers: { authorization: `Bearer ${created.deviceToken}` },
    });
    expect(second.status).toBe(200);
    const secondPage = await second.json() as {
      changes: Array<{ recordId: string }>;
      hasMore: boolean;
    };
    expect(secondPage.changes).toHaveLength(1);
    expect(secondPage.hasMore).toBe(false);
    expect(secondPage.changes[0]?.recordId).not.toBe(firstPage.historyChanges[0]?.recordId);
  }, 10_000);
});

async function createVault(vaultId: string, deviceId: string, recoveryAuthToken: string): Promise<VaultResponse> {
  const response = await post("/v1/vaults", {
    vaultId,
    deviceId,
    deviceToken: tokenFor(deviceId),
    recoveryAuthToken,
    encryptedDeviceProfile: envelope([1, 2, 3]),
  });
  expect(response.status).toBe(201);
  return response.json() as Promise<VaultResponse>;
}

async function pairDevice(deviceToken: string, joiningDeviceId: string): Promise<{ activeDeviceCount: number; newDeviceToken: string }> {
  const joiningPublicKey = btoa(String.fromCharCode(...new Uint8Array(32).fill(2)));
  const approvingPublicKey = btoa(String.fromCharCode(...new Uint8Array(32).fill(3)));
  const create = await post("/v1/pairing-sessions", { deviceId: joiningDeviceId, joiningPublicKey });
  expect(create.status).toBe(201);
  const pairing = await create.json() as PairingResponse;
  const join = await post(`/v1/pairing-sessions/${pairing.code}/join`, { approvingPublicKey }, deviceToken);
  expect(join.status).toBe(200);
  const newDeviceToken = `${joiningDeviceId}.${base64Url(new Uint8Array(32).fill(4))}`;
  const approve = await post(`/v1/pairing-sessions/${pairing.sessionId}/approve`, {
    approvingPublicKey,
    encryptedGrant: envelope([5, 6, 7]),
    newDeviceToken,
  }, deviceToken);
  expect(approve.status).toBe(204);
  const preview = await post(`/v1/pairing-sessions/${pairing.sessionId}/complete`, {
    completionToken: pairing.completionToken,
  });
  expect(preview.status).toBe(200);
  expect((await preview.clone().json() as { requiresProfile: boolean }).requiresProfile).toBe(true);
  const completionBody = {
    completionToken: pairing.completionToken,
    encryptedDeviceProfile: envelope([8, 9, 10]),
  };
  const [complete, concurrentReplay] = await Promise.all([
    post(`/v1/pairing-sessions/${pairing.sessionId}/complete`, completionBody),
    post(`/v1/pairing-sessions/${pairing.sessionId}/complete`, completionBody),
  ]);
  expect(complete.status).toBe(200);
  expect(concurrentReplay.status).toBe(200);
  const completedBody = await complete.json() as {
    activeDeviceCount: number;
    approvingPublicKey: string;
    encryptedGrant: EncryptedEnvelope;
  };
  expect(completedBody).toMatchObject({ approvingPublicKey, encryptedGrant: envelope([5, 6, 7]) });
  expect(await concurrentReplay.json()).toMatchObject({
    approvingPublicKey,
    encryptedGrant: envelope([5, 6, 7]),
    requiresProfile: false,
  });
  const replay = await post(`/v1/pairing-sessions/${pairing.sessionId}/complete`, {
    completionToken: pairing.completionToken,
    encryptedDeviceProfile: envelope([8, 9, 10]),
  });
  expect(replay.status).toBe(200);
  expect(await replay.json()).toMatchObject({
    approvingPublicKey,
    encryptedGrant: envelope([5, 6, 7]),
    requiresProfile: false,
  });
  return { ...completedBody, newDeviceToken };
}

async function sync(token: string, idempotencyKey: string, body: unknown): Promise<Response> {
  return post("/v1/sync", body, token, { "idempotency-key": idempotencyKey });
}

async function post(
  path: string,
  body: unknown,
  token?: string,
  extraHeaders: Record<string, string> = {},
): Promise<Response> {
  const headers: Record<string, string> = { "content-type": "application/json", ...extraHeaders };
  if (token) headers.authorization = `Bearer ${token}`;
  return SELF.fetch(`https://sync.test${path}`, { method: "POST", headers, body: JSON.stringify(body) });
}

async function encryptedRecord(
  deviceId: string,
  recordId: string,
  revision: number,
  plaintextBytes: number[],
): Promise<EncryptedRecord> {
  const value = envelope(plaintextBytes);
  const combined = new Uint8Array([
    ...fromBase64(value.nonce),
    ...fromBase64(value.ciphertext),
    ...fromBase64(value.tag),
  ]);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", combined));
  return { schemaVersion: 1, recordId, deviceId, revision, ...value, ciphertextHash: base64Url(digest) };
}

function envelope(bytes: number[]): EncryptedEnvelope {
  return {
    nonce: btoa(String.fromCharCode(...new Uint8Array(12).fill(1))),
    ciphertext: btoa(String.fromCharCode(...bytes)),
    tag: btoa(String.fromCharCode(...new Uint8Array(16).fill(2))),
  };
}

function fromBase64(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
}

function base64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function recordId(value: number): string {
  return base64Url(new Uint8Array(32).fill(value));
}

function tokenFor(deviceId: string, value = 4): string {
  return `${deviceId}.${base64Url(new Uint8Array(32).fill(value))}`;
}

async function errorCode(response: Response): Promise<string> {
  return (await response.json() as { code: string }).code;
}
