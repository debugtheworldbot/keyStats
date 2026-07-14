export interface EncryptedEnvelope {
  nonce: string;
  ciphertext: string;
  tag: string;
}

export interface EncryptedRecord extends EncryptedEnvelope {
  schemaVersion: 1;
  recordId: string;
  deviceId: string;
  revision: number;
  ciphertextHash: string;
}

export interface DeviceRow {
  id: string;
  vault_id: string;
  profile_nonce: string | null;
  profile_ciphertext: string | null;
  profile_tag: string | null;
  token_hash: string;
  created_at: number;
  last_seen_at: number | null;
  revoked_at: number | null;
  bootstrap_consumed_at: number | null;
  // Optional only for the minimal token-auth projection; SELECT * device rows
  // always receive the migration-backed default of zero.
  exempt_sync_page_count?: number;
  last_sync_at: number | null;
  sync_utc_day: string | null;
  sync_count: number;
  current_record_id: string | null;
  current_revision: number | null;
  current_nonce: string | null;
  current_ciphertext: string | null;
  current_tag: string | null;
  current_ciphertext_hash: string | null;
  current_updated_at: number | null;
  last_idempotency_key: string | null;
  last_idempotency_hash: string | null;
  last_idempotency_at: number | null;
}

export interface AuthContext {
  device: DeviceRow;
  vault: VaultRow;
}

export interface HistoryRow {
  cursor: number;
  vault_id: string;
  device_id: string;
  record_id: string;
  revision: number;
  tombstone: number;
  payload_pruned: number;
  nonce: string | null;
  tag: string | null;
  ciphertext_hash: string | null;
  ciphertext_size: number | null;
  r2_key: string | null;
  r2_entry_index: number | null;
  created_at: number;
}

export interface PairingRow {
  id: string;
  vault_id: string | null;
  approver_device_id: string | null;
  pending_device_id: string;
  joining_public_key: string;
  completion_token_hash: string;
  status: "waiting" | "joined" | "approved" | "completed" | "expired";
  approving_public_key: string | null;
  new_device_token_hash: string | null;
  key_envelope_nonce: string | null;
  key_envelope_ciphertext: string | null;
  key_envelope_tag: string | null;
  grant_hash: string | null;
  expires_at: number;
  approved_at: number | null;
  completed_at: number | null;
  approver_sync_consumed_at: number | null;
  replaces_existing_device?: number;
}

export interface VaultRow {
  id: string;
  recovery_auth_hash: string;
  created_at: number;
  deleted_at: number | null;
  changes_pruned_through: number;
}

export interface StoredHistoryPack {
  schemaVersion: 1;
  records: EncryptedRecord[];
}
