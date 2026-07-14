PRAGMA foreign_keys = ON;

CREATE TABLE vaults (
    id TEXT PRIMARY KEY,
    recovery_auth_hash TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL,
    deleted_at INTEGER,
    changes_pruned_through INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE devices (
    id TEXT PRIMARY KEY,
    vault_id TEXT NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
    profile_nonce TEXT,
    profile_ciphertext TEXT,
    profile_tag TEXT,
    token_hash TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL,
    last_seen_at INTEGER,
    revoked_at INTEGER,
    bootstrap_consumed_at INTEGER,
    last_sync_at INTEGER,
    sync_utc_day TEXT,
    sync_count INTEGER NOT NULL DEFAULT 0,
    current_record_id TEXT,
    current_revision INTEGER,
    current_nonce TEXT,
    current_ciphertext TEXT,
    current_tag TEXT,
    current_ciphertext_hash TEXT,
    current_updated_at INTEGER,
    last_idempotency_key TEXT,
    last_idempotency_hash TEXT,
    last_idempotency_at INTEGER
);

CREATE INDEX devices_vault_active_idx
    ON devices(vault_id, revoked_at);

CREATE TABLE history_changes (
    cursor INTEGER PRIMARY KEY AUTOINCREMENT,
    vault_id TEXT NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    record_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    tombstone INTEGER NOT NULL DEFAULT 0 CHECK (tombstone IN (0, 1)),
    payload_pruned INTEGER NOT NULL DEFAULT 0 CHECK (payload_pruned IN (0, 1)),
    nonce TEXT,
    tag TEXT,
    ciphertext_hash TEXT,
    ciphertext_size INTEGER,
    r2_key TEXT,
    r2_entry_index INTEGER,
    created_at INTEGER NOT NULL,
    UNIQUE(vault_id, record_id, revision)
);

CREATE INDEX history_changes_vault_cursor_idx
    ON history_changes(vault_id, cursor);

CREATE INDEX history_changes_record_latest_idx
    ON history_changes(vault_id, record_id, revision DESC, cursor DESC);

CREATE TABLE pairing_sessions (
    id TEXT PRIMARY KEY,
    code_hash TEXT NOT NULL UNIQUE,
    vault_id TEXT REFERENCES vaults(id) ON DELETE CASCADE,
    approver_device_id TEXT REFERENCES devices(id) ON DELETE CASCADE,
    pending_device_id TEXT NOT NULL,
    joining_public_key TEXT NOT NULL,
    completion_token_hash TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('waiting', 'joined', 'approved', 'completed', 'expired')),
    approving_public_key TEXT,
    new_device_token_hash TEXT,
    key_envelope_nonce TEXT,
    key_envelope_ciphertext TEXT,
    key_envelope_tag TEXT,
    grant_hash TEXT,
    join_attempts INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    approved_at INTEGER,
    completed_at INTEGER,
    approver_sync_consumed_at INTEGER
);

CREATE INDEX pairing_sessions_vault_status_idx
    ON pairing_sessions(vault_id, status);

CREATE UNIQUE INDEX pairing_pending_device_active_idx
    ON pairing_sessions(pending_device_id)
    WHERE status IN ('waiting', 'joined', 'approved');

CREATE TABLE rate_limits (
    key_hash TEXT NOT NULL,
    endpoint TEXT NOT NULL,
    window_started_at INTEGER NOT NULL,
    request_count INTEGER NOT NULL DEFAULT 0,
    blocked_until INTEGER,
    PRIMARY KEY(key_hash, endpoint)
);
