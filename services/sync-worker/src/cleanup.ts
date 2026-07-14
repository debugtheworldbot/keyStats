import type { Env } from "./env";

const DAY_MS = 24 * 60 * 60 * 1_000;
export const CLEANUP_SUBREQUEST_BUDGET = 800;

const TOMBSTONED_VAULT_BUDGET = 220;
const SUPERSEDED_PAYLOAD_BUDGET = 140;
const EXPIRED_CHANGE_BUDGET = 90;
const ORPHAN_BUDGET = 180;
const DELETION_RECEIPT_BATCH_SIZE = 100;
const CLEANUP_ORPHAN_CURSOR_KEY = "orphan-r2-cursor-v1";

interface VaultIdRow {
  id: string;
}

interface PrunableHistoryRow {
  cursor: number;
  vault_id: string;
  r2_key: string | null;
}

interface MaintenanceStateRow {
  value: string;
}

export interface CleanupReport {
  operationsUsed: number;
  failedTasks: string[];
}

class CleanupBudget {
  operationsUsed = 0;

  constructor(readonly limit: number) {}

  consume(amount = 1): boolean {
    if (!Number.isInteger(amount) || amount < 0 || this.operationsUsed + amount > this.limit) return false;
    this.operationsUsed += amount;
    return true;
  }
}

export async function runCleanup(env: Env, now = Date.now()): Promise<CleanupReport> {
  const budget = new CleanupBudget(CLEANUP_SUBREQUEST_BUDGET);
  const failedTasks: string[] = [];

  // Deleted vaults are the only cleanup class with a user-visible privacy
  // deadline, so they always receive the first bounded slice of each cron.
  await isolatedCleanupTask("delete_tombstoned_vaults", failedTasks, () =>
    deleteTombstonedVaults(env, budget));
  await isolatedCleanupTask("prune_vault_deletion_receipts", failedTasks, async () => {
    if (!budget.consume()) return;
    await env.DB.prepare(
      `DELETE FROM vault_deletion_receipts
        WHERE token_hash IN (
          SELECT token_hash
            FROM vault_deletion_receipts
           WHERE expires_at <= ?1
           ORDER BY expires_at ASC, token_hash ASC
           LIMIT ?2
        )`,
    ).bind(now, DELETION_RECEIPT_BATCH_SIZE).run();
  });
  await isolatedCleanupTask("expire_pairing_sessions", failedTasks, () =>
    expirePairingSessions(env, budget, now));
  await isolatedCleanupTask("prune_superseded_payloads", failedTasks, () =>
    pruneSupersededPayloads(env, budget, now - 7 * DAY_MS));
  await isolatedCleanupTask("prune_expired_changes", failedTasks, () =>
    pruneExpiredChangeRows(env, budget, now - 90 * DAY_MS));
  await isolatedCleanupTask("cleanup_orphaned_objects", failedTasks, () =>
    cleanupOrphanedObjects(env, budget, now - DAY_MS));
  await isolatedCleanupTask("prune_rate_limits", failedTasks, async () => {
    if (!budget.consume()) return;
    await env.DB.prepare("DELETE FROM rate_limits WHERE window_started_at < ?1")
      .bind(now - 2 * DAY_MS).run();
  });

  return { operationsUsed: budget.operationsUsed, failedTasks };
}

async function isolatedCleanupTask(
  name: string,
  failedTasks: string[],
  operation: () => Promise<void>,
): Promise<void> {
  try {
    await operation();
  } catch {
    failedTasks.push(name);
    // Do not log identifiers, object keys, ciphertext metadata, or the raw
    // platform error. The next daily invocation resumes the bounded work.
    console.error(`Sync cleanup task failed: ${name}`);
  }
}

async function expirePairingSessions(env: Env, budget: CleanupBudget, now: number): Promise<void> {
  if (!budget.consume()) return;
  await env.DB.prepare(
    `UPDATE pairing_sessions
        SET status = 'expired'
      WHERE status IN ('waiting', 'joined', 'approved') AND expires_at <= ?1`,
  ).bind(now).run();
  if (!budget.consume()) return;
  await env.DB.prepare(
    "DELETE FROM pairing_sessions WHERE expires_at <= ?1 AND status IN ('expired', 'completed')",
  ).bind(now).run();
}

async function pruneSupersededPayloads(env: Env, budget: CleanupBudget, cutoff: number): Promise<void> {
  const taskStart = budget.operationsUsed;
  if (!consumeWithinTask(budget, taskStart, SUPERSEDED_PAYLOAD_BUDGET)) return;
  const rows = await env.DB.prepare(
    `SELECT h.cursor, h.vault_id, h.r2_key
       FROM history_changes h
      WHERE h.payload_pruned = 0
        AND h.tombstone = 0
        AND EXISTS (
          SELECT 1
            FROM history_changes newer
           WHERE newer.vault_id = h.vault_id
             AND newer.record_id = h.record_id
             AND (newer.revision > h.revision OR
                  (newer.revision = h.revision AND newer.cursor > h.cursor))
             AND newer.created_at <= ?1
        )
      ORDER BY h.cursor ASC
      LIMIT 40`,
  ).bind(cutoff).all<PrunableHistoryRow>();
  if (rows.results.length === 0) return;

  const objectKeys = new Set<string>();
  const pruneStatements = rows.results.map((row) => {
    if (row.r2_key) objectKeys.add(row.r2_key);
    return env.DB.prepare(
      `UPDATE history_changes
          SET payload_pruned = 1,
              nonce = NULL,
              tag = NULL,
              ciphertext_size = NULL,
              r2_key = NULL,
              r2_entry_index = NULL
        WHERE cursor = ?1`,
    ).bind(row.cursor);
  });
  if (!consumeWithinTask(budget, taskStart, SUPERSEDED_PAYLOAD_BUDGET, pruneStatements.length)) return;
  await env.DB.batch(pruneStatements);

  for (const key of objectKeys) {
    if (!consumeWithinTask(budget, taskStart, SUPERSEDED_PAYLOAD_BUDGET)) return;
    const reference = await env.DB.prepare("SELECT 1 AS present FROM history_changes WHERE r2_key = ?1 LIMIT 1")
      .bind(key).first<{ present: number }>();
    if (!reference) {
      if (!consumeWithinTask(budget, taskStart, SUPERSEDED_PAYLOAD_BUDGET)) return;
      await env.HISTORY.delete(key);
    }
  }
}

async function pruneExpiredChangeRows(env: Env, budget: CleanupBudget, cutoff: number): Promise<void> {
  const taskStart = budget.operationsUsed;
  if (!consumeWithinTask(budget, taskStart, EXPIRED_CHANGE_BUDGET)) return;
  const rows = await env.DB.prepare(
    `SELECT h.cursor, h.vault_id, h.r2_key
       FROM history_changes h
      WHERE h.created_at < ?1
        AND EXISTS (
          SELECT 1
            FROM history_changes newer
           WHERE newer.vault_id = h.vault_id
             AND newer.record_id = h.record_id
             AND (newer.revision > h.revision OR
                  (newer.revision = h.revision AND newer.cursor > h.cursor))
        )
      ORDER BY h.cursor ASC
      LIMIT 40`,
  ).bind(cutoff).all<PrunableHistoryRow>();
  if (rows.results.length === 0) return;
  const maximumPrunedByVault = new Map<string, number>();
  const statements = rows.results.map((row) => {
    maximumPrunedByVault.set(row.vault_id, Math.max(maximumPrunedByVault.get(row.vault_id) ?? 0, row.cursor));
    return env.DB.prepare("DELETE FROM history_changes WHERE cursor = ?1").bind(row.cursor);
  });
  const watermarks = [...maximumPrunedByVault.entries()].map(([vaultId, cursor]) => env.DB.prepare(
    `UPDATE vaults
        SET changes_pruned_through = MAX(changes_pruned_through, ?1)
      WHERE id = ?2`,
  ).bind(cursor, vaultId));
  if (!consumeWithinTask(budget, taskStart, EXPIRED_CHANGE_BUDGET, statements.length + watermarks.length)) return;
  await env.DB.batch([...statements, ...watermarks]);
}

async function cleanupOrphanedObjects(env: Env, budget: CleanupBudget, cutoff: number): Promise<void> {
  const taskStart = budget.operationsUsed;
  if (!consumeWithinTask(budget, taskStart, ORPHAN_BUDGET)) return;
  const state = await env.DB.prepare("SELECT value FROM maintenance_state WHERE key = ?1")
    .bind(CLEANUP_ORPHAN_CURSOR_KEY).first<MaintenanceStateRow>();
  const cursor = state?.value || undefined;

  if (!consumeWithinTask(budget, taskStart, ORPHAN_BUDGET)) return;
  let page: R2Objects;
  try {
    page = await env.HISTORY.list({ prefix: "history/", limit: 80, ...(cursor ? { cursor } : {}) });
  } catch (error) {
    if (cursor && consumeWithinTask(budget, taskStart, ORPHAN_BUDGET)) {
      await env.DB.prepare("DELETE FROM maintenance_state WHERE key = ?1")
        .bind(CLEANUP_ORPHAN_CURSOR_KEY).run();
    }
    throw error;
  }

  for (const object of page.objects) {
    if (object.uploaded.getTime() >= cutoff) continue;
    if (!consumeWithinTask(budget, taskStart, ORPHAN_BUDGET)) break;
    const reference = await env.DB.prepare("SELECT 1 AS present FROM history_changes WHERE r2_key = ?1 LIMIT 1")
      .bind(object.key).first<{ present: number }>();
    if (!reference) {
      if (!consumeWithinTask(budget, taskStart, ORPHAN_BUDGET)) break;
      await env.HISTORY.delete(object.key);
    }
  }

  if (!consumeWithinTask(budget, taskStart, ORPHAN_BUDGET)) return;
  if (page.truncated && page.cursor) {
    await env.DB.prepare(
      `INSERT INTO maintenance_state(key, value, updated_at)
       VALUES (?1, ?2, ?3)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
    ).bind(CLEANUP_ORPHAN_CURSOR_KEY, page.cursor, Date.now()).run();
  } else {
    await env.DB.prepare("DELETE FROM maintenance_state WHERE key = ?1")
      .bind(CLEANUP_ORPHAN_CURSOR_KEY).run();
  }
}

async function deleteTombstonedVaults(env: Env, budget: CleanupBudget): Promise<void> {
  const taskStart = budget.operationsUsed;
  while (consumeWithinTask(budget, taskStart, TOMBSTONED_VAULT_BUDGET)) {
    const vaults = await env.DB.prepare(
      "SELECT id FROM vaults WHERE deleted_at IS NOT NULL ORDER BY deleted_at ASC, id ASC LIMIT 25",
    ).all<VaultIdRow>();
    if (vaults.results.length === 0) return;
    let madeProgress = false;
    for (const vault of vaults.results) {
      if (!consumeWithinTask(budget, taskStart, TOMBSTONED_VAULT_BUDGET)) return;
      const page = await env.HISTORY.list({ prefix: `history/${vault.id}/`, limit: 1_000 });
      if (page.objects.length > 0) {
        if (!consumeWithinTask(budget, taskStart, TOMBSTONED_VAULT_BUDGET)) return;
        await env.HISTORY.delete(page.objects.map((object) => object.key));
        madeProgress = true;
      }
      if (!page.truncated) {
        if (!consumeWithinTask(budget, taskStart, TOMBSTONED_VAULT_BUDGET)) return;
        await env.DB.prepare("DELETE FROM vaults WHERE id = ?1 AND deleted_at IS NOT NULL")
          .bind(vault.id).run();
        madeProgress = true;
      }
    }
    if (!madeProgress) return;
  }
}

function consumeWithinTask(
  budget: CleanupBudget,
  taskStart: number,
  taskLimit: number,
  amount = 1,
): boolean {
  if (budget.operationsUsed - taskStart + amount > taskLimit) return false;
  return budget.consume(amount);
}
