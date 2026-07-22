CREATE TABLE IF NOT EXISTS linked_accounts (
    id TEXT PRIMARY KEY,
    linked_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    user_id TEXT NOT NULL,
    provider TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    email TEXT,
    display_name TEXT,
    merged_anon_id TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_linked_accounts_provider_id
    ON linked_accounts(provider, provider_id);

CREATE INDEX IF NOT EXISTS idx_linked_accounts_user_id
    ON linked_accounts(user_id);
