ALTER TABLE devices
ADD COLUMN exempt_sync_page_count INTEGER NOT NULL DEFAULT 0
CHECK (exempt_sync_page_count >= 0 AND exempt_sync_page_count <= 256);
