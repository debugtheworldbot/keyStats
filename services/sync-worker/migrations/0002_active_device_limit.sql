CREATE TRIGGER devices_active_limit_before_insert
BEFORE INSERT ON devices
WHEN NEW.revoked_at IS NULL AND (
    SELECT COUNT(*)
      FROM devices
     WHERE vault_id = NEW.vault_id AND revoked_at IS NULL
) >= 5
BEGIN
    SELECT RAISE(ABORT, 'maximum active devices');
END;
