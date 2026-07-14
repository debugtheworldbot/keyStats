# KeyStats sync Worker

This directory is the independently deployable Cloudflare backend for KeyStats
E2EE device synchronization. It never receives a recovery seed, recovery code,
plaintext device profile, local date, key name, or statistics count.

## Local verification

```bash
npm ci
npm run check
npx wrangler d1 migrations apply DB --local
```

`npm run check` validates the shared schemas and golden vectors, checks generated
Worker bindings and TypeScript, and runs the Worker inside Miniflare against D1
and R2. Tests inject a test-only token hashing key directly into Miniflare; no
dotenv file is used.

## One-time Cloudflare setup

Create separate D1 databases and R2 buckets named in `wrangler.jsonc`:

```bash
npx wrangler d1 create keystats-sync-staging
npx wrangler r2 bucket create keystats-sync-staging
npx wrangler d1 create keystats-sync-production
npx wrangler r2 bucket create keystats-sync-production
```

Keep the checked-in zero D1 IDs as non-deployable placeholders. Configure each
GitHub Environment (`sync-staging` and `sync-production`) with:

- variable `CLOUDFLARE_D1_DATABASE_ID`;
- secret `CLOUDFLARE_API_TOKEN`;
- secret `CLOUDFLARE_ACCOUNT_ID`;
- a different, randomly generated secret `TOKEN_HASH_KEY` of at least 32 bytes.

`TOKEN_HASH_KEY` is a persistent authentication pepper, not a disposable deploy
secret. Rotating or losing it invalidates every stored device and recovery
credential in that environment; preserve it in the GitHub Environment unless a
full vault reset is intentional.

The deployment workflow writes a permission-restricted temporary Wrangler
configuration, applies migrations, configures `TOKEN_HASH_KEY` with
`wrangler secret put`, and deploys. It does not write an `.env` or secret file
to the repository. Main deploys staging; production requires the
`sync-production` GitHub Environment approval and an explicit confirmation.

After production deployment, set repository variable
`KEYSTATS_SYNC_PRODUCTION_URL` to the resulting independent `workers.dev` URL.
Release builds inject it into macOS `Info.plist` and Windows assembly metadata.
Missing or placeholder endpoints leave the public UI visible but networking
disabled.

## Storage and limits

- D1 stores HMACs of credentials, encrypted device profiles, the current
  encrypted record, history cursors, limiter state, and independent hash-only
  vault-deletion receipts.
- R2 stores each encrypted history revision in its own immutable object. A
  superseded revision can therefore be removed independently after seven days.
  Sync requests carry at most 16 archives and JSON bodies are capped at 2 MiB;
  initial bootstrap/recovery/pairing uploads paginate with
  `bootstrapComplete=false` until their final page.
- A device can use at most 256 cooldown-exempt pages over its lifetime (4,096
  archived days at 16 records per page), preventing an unfinished bootstrap
  from becoming an unbounded write path.
- A successful sync updates the current ciphertext and limiter in one D1 row
  write. On record-ID rollover, the Worker first archives the previous current
  envelope held by that row, then replaces it; an archive backlog therefore
  cannot strand the prior day. This server-generated handoff is outside the
  16-item client archive limit. Exact idempotency replays do not consume another
  write or quota.
- Active vaults are limited to five devices. Ordinary successful syncs are
  limited to one per hour and eight per UTC day per device. A 409 caused by a
  vault dropping to one active device includes `activeDeviceCount: 1`, allowing
  clients to persist the gate and stop ordinary sync immediately.
- Superseded revisions are retained for seven days. Pairing sessions expire in
  ten minutes. Orphan objects and deleted vaults are removed by the daily Cron;
  vault tokens are rejected immediately when deletion is requested. Cron work
  uses a conservative 800-operation ceiling, prioritizes tombstoned vaults,
  persists the orphan-scan cursor, and continues oversized deletion backlogs on
  later daily runs. Individual cleanup failures do not suppress other tasks.
- Vault creation and recovery use client-generated, device-ID-bound bearer
  tokens, so an exact retry after a lost response cannot orphan an unknown
  server-generated credential. Recovery can rotate an existing active or
  revoked identity in place; a full-vault error returns only encrypted device
  descriptors plus the vault ID after the recovery credential has validated.
- `GET /v1/state` is an authenticated read-only repair endpoint. It returns all
  active encrypted device profiles and current records (including the caller)
  without consuming the one-hour/eight-per-day sync quota.
- Completed pairing grants remain replayable through the pairing session's
  ten-minute TTL. Pairing may rotate an existing same-vault identity, while a
  cross-vault device-ID collision remains rejected.
- Vault deletion writes a hash-only receipt for the initiating token in the
  same D1 batch that tombstones the vault. The independent receipt survives
  physical deletion for 30 days solely so exact `DELETE /v1/vault` retries can
  return `204`; normal authentication and every other operation reject the
  token immediately. Cron removes at most 100 expired receipts per invocation.

The checked-in configuration enables the kill switch variable
`SYNC_ENABLED`. Set it to `false` in a deployed environment to reject new sync,
pair, recovery, and history operations while still allowing authenticated
device/vault deletion.

## Production operations

Before the public client release, configure Cloudflare notifications or an
equivalent external dashboard for Worker request/error rate, D1 rows read and
written, R2 Class A/Class B operations, R2 storage, and encrypted object-size
distribution. Persistent Workers Logs and invocation logs are intentionally
disabled because invocation metadata may include request headers. Use the
platform's built-in Workers, D1, and R2 metrics; the application does not emit
credentials, identifiers, ciphertext, key names, or counts to logs.

Use the seven-day peak as the capacity signal. Alert at 60% of any applicable
Workers or D1 free-plan limit and move the service to Workers Paid at 75%.
Treat a rising 413 or archive-limit error rate as a client bootstrap batching
issue. Keep the `SYNC_ENABLED=false` kill switch documented
in the incident runbook; local statistics continue to operate while it is set.
