CREATE TRIGGER history_revision_monotonic_before_insert
BEFORE INSERT ON history_changes
WHEN EXISTS (
    SELECT 1
      FROM history_changes
     WHERE vault_id = NEW.vault_id
       AND record_id = NEW.record_id
       AND revision >= NEW.revision
)
BEGIN
    SELECT RAISE(ABORT, 'history revision is not newer');
END;
