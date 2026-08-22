-- Mythos Coins: the wallet is a ledger, not a number.
--
-- Every movement of coins is one INSERT here, with an id the *caller* chooses.
-- That id is the idempotency key — the same trick message_delivery plays with
-- bubble_id — so a client retry, a double-tap, or a replayed request collapses
-- onto the row it already wrote instead of granting or charging twice. The
-- worker never UPDATEs a ledger row and never DELETEs one; corrections are new
-- rows with kind 'adjust' or 'refund', which is what makes the history worth
-- reading when a balance is disputed.
--
-- created_at takes SQLite's own CURRENT_TIMESTAMP (space form), NOT the ISO
-- 'T' form conversation_logs uses. The two formats do not compare as strings,
-- and that mismatch has already cost real rows in window queries — see the
-- comment block in exportAllTables.
CREATE TABLE coin_ledger (
    id          TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL,
    created_at  TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    -- Positive = coins in, negative = coins out. Zero is a bug, so it is
    -- rejected here rather than filtered out of every report later.
    delta       INTEGER NOT NULL CHECK (delta <> 0),
    -- grant | spend | purchase | refund | adjust | merge
    kind        TEXT NOT NULL,
    -- welcome | daily | reply | link | profile | gift | photo | oracle |
    -- pack | admin — the vocabulary the admin page groups by.
    reason      TEXT NOT NULL,
    -- What the movement was about: a character id for a gift, the
    -- conversation_logs id for a reply grant, a transaction id for a pack.
    ref         TEXT,
    -- Same analysis joins message_delivery carries: which browser visit and
    -- which build. NULL means "not measured", never "none".
    visit_id    TEXT,
    app_version TEXT,
    meta_json   TEXT
);

CREATE INDEX idx_coin_ledger_user ON coin_ledger (user_id, created_at);
CREATE INDEX idx_coin_ledger_reason ON coin_ledger (reason, created_at);

-- The balance is a cache of SUM(delta), maintained by the trigger below and
-- rebuildable from the ledger at any time. It exists so a spend can be one
-- conditional statement (D1 has no interactive transactions) and so the chat
-- path can read a balance without summing a user's history per message.
--
-- last_daily_on / last_daily_at gate the daily grant: the user's own local
-- date decides *which* day it was (the client sends it), and the server
-- timestamp enforces that two "days" are at least 20 hours apart, so a device
-- with a wandering clock cannot harvest a week of mornings in an afternoon.
CREATE TABLE coin_wallets (
    user_id          TEXT PRIMARY KEY,
    balance          INTEGER NOT NULL DEFAULT 0,
    lifetime_earned  INTEGER NOT NULL DEFAULT 0,
    lifetime_spent   INTEGER NOT NULL DEFAULT 0,
    last_daily_on    TEXT,
    last_daily_at    TEXT,
    -- Phase 2: hash of the token that proves an anonymous wallet is being
    -- presented by the device that created it. Unused until then.
    claim_token_hash TEXT,
    created_at       TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at       TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Every ledger row moves the cache in the same atomic step that writes it.
-- This is the whole consistency story: no code path updates balance directly,
-- so the cache cannot drift from the ledger except by someone editing rows by
-- hand — in which case the ledger, not the cache, is the truth.
CREATE TRIGGER coin_ledger_ai AFTER INSERT ON coin_ledger BEGIN
    INSERT INTO coin_wallets (user_id, balance, lifetime_earned, lifetime_spent)
    VALUES (NEW.user_id, NEW.delta, MAX(NEW.delta, 0), MAX(-NEW.delta, 0))
    ON CONFLICT(user_id) DO UPDATE SET
        balance         = balance + NEW.delta,
        lifetime_earned = lifetime_earned + MAX(NEW.delta, 0),
        lifetime_spent  = lifetime_spent  + MAX(-NEW.delta, 0),
        updated_at      = CURRENT_TIMESTAMP;
END;
