ALTER TABLE pairing_sessions
ADD COLUMN replaces_existing_device INTEGER NOT NULL DEFAULT 0
CHECK (replaces_existing_device IN (0, 1));

CREATE TRIGGER devices_active_limit_before_reactivation
BEFORE UPDATE OF revoked_at ON devices
WHEN OLD.revoked_at IS NOT NULL
 AND NEW.revoked_at IS NULL
 AND (
    SELECT COUNT(*)
      FROM devices
     WHERE vault_id = NEW.vault_id AND revoked_at IS NULL
 ) >= 5
BEGIN
    SELECT RAISE(ABORT, 'maximum active devices');
END;
