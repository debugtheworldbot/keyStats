CREATE TABLE vault_deletion_receipts (
    token_hash TEXT PRIMARY KEY,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    CHECK (expires_at > created_at)
);

CREATE INDEX vault_deletion_receipts_expiry_idx
    ON vault_deletion_receipts(expires_at, token_hash);
