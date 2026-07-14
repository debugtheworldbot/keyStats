import { applyD1Migrations, env } from "cloudflare:test";
import { beforeEach } from "vitest";

beforeEach(async () => {
  const tables = await env.DB.prepare(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'vaults'",
  ).first<{ name: string }>();
  if (!tables) await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);

  await env.DB.batch([
    env.DB.prepare("DELETE FROM vault_deletion_receipts"),
    env.DB.prepare("DELETE FROM rate_limits"),
    env.DB.prepare("DELETE FROM pairing_sessions"),
    env.DB.prepare("DELETE FROM history_changes"),
    env.DB.prepare("DELETE FROM devices"),
    env.DB.prepare("DELETE FROM vaults"),
  ]);
  let cursor: string | undefined;
  do {
    const page = await env.HISTORY.list({ ...(cursor ? { cursor } : {}) });
    if (page.objects.length > 0) await env.HISTORY.delete(page.objects.map((object) => object.key));
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
});
