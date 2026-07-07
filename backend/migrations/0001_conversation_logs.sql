CREATE TABLE IF NOT EXISTS conversation_logs (
    id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    user_id TEXT NOT NULL,
    chat_id TEXT NOT NULL,
    scenario TEXT,
    language TEXT,
    model TEXT NOT NULL,
    status TEXT NOT NULL,
    status_code INTEGER NOT NULL,
    user_message TEXT NOT NULL,
    assistant_message TEXT,
    request_messages_json TEXT NOT NULL,
    response_json TEXT,
    error TEXT,
    prompt_tokens INTEGER,
    completion_tokens INTEGER,
    total_tokens INTEGER,
    client_timestamp TEXT
);

CREATE INDEX IF NOT EXISTS idx_conversation_logs_created_at
    ON conversation_logs(created_at);

CREATE INDEX IF NOT EXISTS idx_conversation_logs_user_created_at
    ON conversation_logs(user_id, created_at);

CREATE INDEX IF NOT EXISTS idx_conversation_logs_chat_created_at
    ON conversation_logs(chat_id, created_at);

CREATE INDEX IF NOT EXISTS idx_conversation_logs_status_created_at
    ON conversation_logs(status, created_at);
