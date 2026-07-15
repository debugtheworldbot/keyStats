# KeyStats Cloudflare E2EE multi-device sync design

**Date:** 2026-07-13
**Status:** Implemented locally; staging validation pending

## Goals

KeyStats synchronizes the privacy-safe core counters of up to five macOS and
Windows devices. Cloudflare stores only encrypted payloads and random
identifiers. The existing local statistics remain the only writable source for
the current device; downloaded records are immutable remote shards that are
combined only while building aggregate views.

Version 1 synchronizes:

- total key presses;
- per-key counts using canonical, `+`-separated names;
- left, right, middle, back-side, and forward-side mouse clicks.

Menu-bar values, today's local panel, rates, peaks, notifications, application
statistics, pointer distance, and scroll distance remain local. History,
all-time summaries, key history, and heatmaps may include remote shards.

## Trust and identity model

There is no account service. Creating a vault generates a 128-bit recovery seed
and a 28-character checksummed Crockford Base32 recovery code. HKDF-SHA256
derives separate keys for `vault-encryption-v1`, `record-index-v1`, and
`recovery-auth-v1`.

Records use AES-256-GCM with a new random 96-bit nonce. AAD binds the protocol
version, vault ID, device ID, opaque record ID, and revision. The opaque record
ID is an HMAC-derived index; it does not reveal the local date.

Pairing uses an ephemeral X25519 exchange. A new device displays a six-digit
pairing code. Both devices must explicitly confirm the same safety code before
the existing device releases an encrypted vault seed and new device token.

macOS stores the credential bundle in the app's UserDefaults domain. Windows
stores secrets with DPAPI `CurrentUser`. Secrets, IDs, key names, and counts are
never analytics properties or log fields.

## Wire record

`CoreDaySnapshotV1` contains:

```text
schemaVersion: 1
deviceId: random identifier
localDay: YYYY-MM-DD (the source device's calendar date)
revision: non-negative Int64
keyPresses: non-negative Int64
keyPressCounts: map<canonical key, non-negative Int64>
clicks: { left, right, middle, sideBack, sideForward }
```

The decrypted JSON is limited to 64 KiB, 512 key entries, and 64 UTF-8 bytes
per key name. Integer aggregation is saturating. A server record with the same
`(deviceId, opaqueRecordId, revision)` and ciphertext hash is an idempotent
success. A different hash at the same revision is a conflict; lower revisions
are stale. A client replaces a remote shard by revision and never passes it to
the legacy import merge path.

## Service architecture

The native TypeScript Worker exposes:

```text
POST   /v1/vaults
POST   /v1/pairing-sessions
POST   /v1/pairing-sessions/{code}/join
POST   /v1/pairing-sessions/{id}/approve
POST   /v1/pairing-sessions/{id}/complete
POST   /v1/recover
POST   /v1/sync
GET    /v1/state
GET    /v1/history?cursor=...
DELETE /v1/devices/{deviceId}
DELETE /v1/vault
```

Vault creation and recovery use client-generated bearer tokens whose UUID
prefix is bound to `deviceId`; exact request replays acknowledge the same token
after a lost response. Recovery may explicitly set
`replaceDeviceId == deviceId` to rotate an active or revoked same-vault row in
place while preserving its accepted current/history records. It returns cursor
zero and the target current record, so the client rebuilds revisions before
upload. At five active devices, a valid recovery credential receives the vault
ID and encrypted active-device descriptors, then explicitly chooses a target;
the Worker never chooses or silently replaces one. Profile encryption is
deferred to the first recovery sync because profile AAD includes the vault ID.

Pairing supports the same identity takeover after the authenticated approver
establishes that the colliding device belongs to its vault. Completed sessions
replay the approving public key and encrypted grant until their ten-minute
expiry. `GET /v1/state` is authenticated and read-only, returning all active
current records (including the caller) and encrypted device profiles without
uploading statistics or consuming sync quota. Vault deletion atomically writes
an independent hash-only receipt for the initiating token. It survives physical
vault deletion for 30 days only to acknowledge exact delete retries; the token
remains invalid everywhere else, and Cron removes expired receipts in bounded
100-row pages.

D1 holds vault/device authentication hashes, the current encrypted device
record, cursors, limiter state, and pairing sessions. R2 holds immutable
finalized-day and bootstrap ciphertext. D1 and R2 are separate between staging
and production. `TOKEN_HASH_KEY` is configured as a Wrangler secret; no dotenv
file is used.

The Worker accepts at most a 2 MiB request body and at most 16 history archives
per sync request. Bootstrap/recovery uploads are explicitly paged with
`bootstrapComplete`; a device may consume at most 256 cooldown-exempt pages.
Each accepted history revision has its own immutable R2 object. A replaced
revision is retained for seven days before cleanup, so replacement cannot erase
the rollback window of an unrelated record in the same pack.

Every successful ordinary sync is at least one hour after the previous success
and each device receives at most eight successful syncs per UTC day. A vault
has at most five active devices. Pair and recovery endpoints have independent
IP limits. Revoking a device archives its current ciphertext before invalidating
the token. Deleting a vault invalidates all tokens immediately and schedules
encrypted object deletion for the next daily Cron. Cleanup prioritizes deleted
vaults under a conservative 800-operation budget, persists the bounded orphan
scan cursor, and continues unusually large deletion backlogs on later daily
runs. Thus token invalidation is immediate and physical deletion is best-effort
within 24 hours rather than an unbounded single-invocation promise.

## Client scheduling and failure behavior

`SyncCoordinator` is a single-flight state machine over an injectable
`SyncTransport`. When fewer than two active devices exist it has no ordinary
timer, disables manual sync, and never calls `/v1/sync`; pairing and recovery
remain available. If another device is revoked between syncs, the Worker returns
`single_device_sync_disabled` with `activeDeviceCount: 1`; clients persist that
server-authoritative count and stop the timer instead of retrying every hour.

With two or more devices, manual sync becomes available one hour after the last
success. After 24 hours without success, an automatic attempt is scheduled with
0-60 minutes of jitter. Automatic failures retry after one hour and then six
hours, with no more than three failed retries per UTC day. A manual transport
failure has a 60-second local cooldown and HTTP 429 always uses `Retry-After`.

The app does not wake in the background after exit. It evaluates due work on
launch, resume, and activation. Any credential, decryption, or cache failure
leaves the local statistics untouched and moves synchronization to a
repair/re-pair state.

Clients persist an acknowledgement after every accepted upload page. They send
the current record and encrypted profile only on the final page, then persist a
history-only continuation before fetching cursor pages. A network failure while
pulling history therefore resumes the pull and does not replay an already
accepted bootstrap. When the current record ID rolls over, the Worker archives
the complete previous envelope persisted in the device row before replacing
it. The client may still submit a newer archived revision, but a 16-record
backlog page no longer has to contain the server's previous current record.

The sync response includes `historyHasMore`. This same durable history-only
continuation is used after manual and automatic syncs, so an offline backlog
larger than the 100-change inline page is completed immediately rather than
waiting for another hourly sync window.

After pairing approval, the approving device polls with bounded 5/10/20/40/60
second backoff. That one-time refresh becomes eligible only after the joining
device has registered and completed its final bootstrap page; an early conflict
is retryable and does not move either client into repair.

## Product behavior

Both settings screens expose a Device Sync card and a separate management
window. Creating, pairing, recovering, manually syncing, revoking, leaving, and
deleting are explicit actions. A single device displays “Only one device; no
sync needed.”

Legacy import is disabled while a vault is configured. Export remains a local
device export. Reset means “reset this device's statistics”; a higher revision
propagates the zero snapshot. Revocation retains the device's archived history;
only vault deletion removes all cloud data. Client analytics record stable page
and click event names without synchronization contents or identifiers.

## Availability and rollout

The service uses an independent `workers.dev` production endpoint. Service
failure never blocks startup, event monitoring, local persistence, or exit. A
server kill switch can reject synchronization without changing local behavior.
Main deploys staging after tests; production deploys only through a manually
approved GitHub Environment.
