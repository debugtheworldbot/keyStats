import { decodeBase64 } from "./crypto";
import type { Env } from "./env";
import { ApiError } from "./http";
import type { DeviceRow, EncryptedRecord, HistoryRow, StoredHistoryPack } from "./types";

const HISTORY_PAGE_SIZE = 100;

export interface WireHistoryChange {
  cursor: number;
  recordId: string;
  tombstone: boolean;
  record?: EncryptedRecord;
}

export interface HistoryPage {
  changes: WireHistoryChange[];
  cursor: number;
  hasMore: boolean;
}

export function currentRecord(device: DeviceRow): EncryptedRecord | null {
  if (
    !device.current_record_id || device.current_revision === null || !device.current_nonce ||
    !device.current_ciphertext || !device.current_tag || !device.current_ciphertext_hash
  ) {
    return null;
  }
  return {
    schemaVersion: 1,
    recordId: device.current_record_id,
    deviceId: device.id,
    revision: device.current_revision,
    nonce: device.current_nonce,
    ciphertext: device.current_ciphertext,
    tag: device.current_tag,
    ciphertextHash: device.current_ciphertext_hash,
  };
}

export async function ensureRecordCanBeArchived(
  env: Env,
  vaultId: string,
  record: EncryptedRecord,
): Promise<"insert" | "unchanged"> {
  const latest = await env.DB.prepare(
    `SELECT revision, ciphertext_hash
       FROM history_changes
      WHERE vault_id = ?1 AND record_id = ?2
      ORDER BY revision DESC, cursor DESC
      LIMIT 1`,
  ).bind(vaultId, record.recordId).first<{ revision: number; ciphertext_hash: string | null }>();
  if (!latest) return "insert";
  if (record.revision < latest.revision) {
    throw new ApiError(409, "stale_revision", "An archived record has an older revision");
  }
  if (record.revision === latest.revision) {
    if (latest.ciphertext_hash === record.ciphertextHash) return "unchanged";
    throw new ApiError(409, "revision_conflict", "The same revision has different encrypted content");
  }
  return "insert";
}

export async function hasArchivedRecord(env: Env, vaultId: string, recordId: string): Promise<boolean> {
  const row = await env.DB.prepare(
    "SELECT 1 AS present FROM history_changes WHERE vault_id = ?1 AND record_id = ?2 LIMIT 1",
  ).bind(vaultId, recordId).first<{ present: number }>();
  return Boolean(row);
}

export async function storeHistoryRecords(
  env: Env,
  vaultId: string,
  deviceId: string,
  records: EncryptedRecord[],
  now: number,
): Promise<void> {
  assertUniqueHistoryRecords(records);
  for (const record of records) {
    if (await ensureRecordCanBeArchived(env, vaultId, record) === "unchanged") continue;
    // Each revision owns an independent object. This lets retention remove a
    // superseded revision after seven days without keeping or rewriting a pack
    // that also contains live revisions.
    const pack: StoredHistoryPack = { schemaVersion: 1, records: [record] };
    const payload = JSON.stringify(pack);
    // The content hash makes exact concurrent/idempotent writes converge on
    // one object without allowing a conflicting same-revision envelope to
    // overwrite the accepted payload.
    const r2Key = `history/${vaultId}/${deviceId}/${record.recordId}/${record.revision}-${record.ciphertextHash}.json`;
    await env.HISTORY.put(r2Key, payload, {
      httpMetadata: { contentType: "application/json" },
      customMetadata: { schemaVersion: "1", recordCount: "1" },
    });
    try {
      await env.DB.prepare(
        `INSERT INTO history_changes(
           vault_id, device_id, record_id, revision, tombstone,
           nonce, tag, ciphertext_hash, ciphertext_size,
           r2_key, r2_entry_index, created_at
         ) VALUES (?1, ?2, ?3, ?4, 0, ?5, ?6, ?7, ?8, ?9, 0, ?10)`,
      ).bind(
        vaultId,
        deviceId,
        record.recordId,
        record.revision,
        record.nonce,
        record.tag,
        record.ciphertextHash,
        decodeBase64(record.ciphertext, "record.ciphertext", 65_536).length,
        r2Key,
        now,
      ).run();
    } catch (error) {
      const latest = await env.DB.prepare(
        `SELECT revision, ciphertext_hash
           FROM history_changes
          WHERE vault_id = ?1 AND record_id = ?2
          ORDER BY revision DESC, cursor DESC
          LIMIT 1`,
      ).bind(vaultId, record.recordId).first<{ revision: number; ciphertext_hash: string | null }>();
      if (latest?.revision === record.revision && latest.ciphertext_hash === record.ciphertextHash) continue;
      if (latest && record.revision < latest.revision) {
        throw new ApiError(409, "stale_revision", "An archived record has an older revision");
      }
      if (latest?.revision === record.revision && latest.ciphertext_hash !== record.ciphertextHash) {
        throw new ApiError(409, "revision_conflict", "The same revision has different encrypted content");
      }
      // The object is deliberately left for the 24-hour orphan cleanup. Do not
      // risk deleting an object while classifying a concurrent successful write.
      throw error;
    }
  }
}

export async function validateHistoryRecords(
  env: Env,
  vaultId: string,
  records: EncryptedRecord[],
): Promise<void> {
  assertUniqueHistoryRecords(records);
  for (const record of records) {
    await ensureRecordCanBeArchived(env, vaultId, record);
  }
}

export async function readHistoryPage(
  env: Env,
  vaultId: string,
  requestedCursor: number,
  changesPrunedThrough: number,
): Promise<HistoryPage> {
  const staleCursor = requestedCursor < changesPrunedThrough;
  const query = staleCursor
    ? `SELECT h.*
         FROM history_changes h
         JOIN (
           SELECT record_id, MAX(revision) AS revision
             FROM history_changes
            WHERE vault_id = ?1
            GROUP BY record_id
         ) latest
           ON latest.record_id = h.record_id AND latest.revision = h.revision
        WHERE h.vault_id = ?1 AND h.cursor > ?2
        ORDER BY h.cursor ASC
        LIMIT ?3`
    : `SELECT *
         FROM history_changes
        WHERE vault_id = ?1 AND cursor > ?2
        ORDER BY cursor ASC
        LIMIT ?3`;
  const result = staleCursor
    ? await env.DB.prepare(query).bind(vaultId, requestedCursor, HISTORY_PAGE_SIZE + 1).all<HistoryRow>()
    : await env.DB.prepare(query).bind(vaultId, requestedCursor, HISTORY_PAGE_SIZE + 1).all<HistoryRow>();
  const rows = result.results;
  const hasMore = rows.length > HISTORY_PAGE_SIZE;
  const pageRows = rows.slice(0, HISTORY_PAGE_SIZE);
  const changes = await materializeHistoryRows(env, pageRows);
  const latestCursor = await maximumCursor(env, vaultId);
  const cursor = hasMore
    ? Math.max(requestedCursor, pageRows.at(-1)?.cursor ?? requestedCursor)
    : latestCursor;
  return { changes, cursor, hasMore };
}

export async function maximumCursor(env: Env, vaultId: string): Promise<number> {
  const row = await env.DB.prepare(
    "SELECT COALESCE(MAX(cursor), 0) AS cursor FROM history_changes WHERE vault_id = ?1",
  ).bind(vaultId).first<{ cursor: number }>();
  return Number(row?.cursor ?? 0);
}

async function materializeHistoryRows(env: Env, rows: HistoryRow[]): Promise<WireHistoryChange[]> {
  const packs = new Map<string, StoredHistoryPack>();
  const changes: WireHistoryChange[] = [];
  for (const row of rows) {
    if (row.payload_pruned === 1) continue;
    if (row.tombstone === 1) {
      changes.push({ cursor: row.cursor, recordId: row.record_id, tombstone: true });
      continue;
    }
    if (!row.r2_key || row.r2_entry_index === null) {
      throw new Error("A non-tombstone history row has no object location");
    }
    let pack = packs.get(row.r2_key);
    if (!pack) {
      const object = await env.HISTORY.get(row.r2_key);
      if (!object) throw new Error("A referenced history object is missing");
      const value: unknown = await object.json();
      if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("History object is invalid");
      const candidate = value as Partial<StoredHistoryPack>;
      if (candidate.schemaVersion !== 1 || !Array.isArray(candidate.records)) throw new Error("History object schema is invalid");
      pack = candidate as StoredHistoryPack;
      packs.set(row.r2_key, pack);
    }
    const record = pack.records[row.r2_entry_index];
    if (!record || record.recordId !== row.record_id || record.revision !== row.revision) {
      throw new Error("History object index does not match its D1 row");
    }
    changes.push({ cursor: row.cursor, recordId: row.record_id, tombstone: false, record });
  }
  return changes;
}

function assertUniqueHistoryRecords(records: EncryptedRecord[]): void {
  const uniqueRecordIds = new Set<string>();
  for (const record of records) {
    if (uniqueRecordIds.has(record.recordId)) {
      throw new ApiError(400, "duplicate_record", "A history request contains the same record more than once");
    }
    uniqueRecordIds.add(record.recordId);
  }
}
