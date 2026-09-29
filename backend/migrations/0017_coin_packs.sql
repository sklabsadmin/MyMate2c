-- Coin packs: real money enters the ledger.
--
-- Design in docs/coin-packs-brief-2026-09-16.md. The short version: the
-- ledger in 0014 stays the single source of truth; RevenueCat verifies a
-- purchase with the store and tells the worker about it (webhook); the worker
-- writes ONE ledger row per store transaction, id `purchase:<transaction_id>`,
-- so a retried or duplicated event collapses onto the row that already exists.
-- A refund is a second row, `refund:<transaction_id>`, with the opposite
-- delta — which may take the balance below zero on purpose (E1 in the brief):
-- a refund of coins already spent is a debt, never a free gift.
--
-- 0016 is taken by the sign-in branch (email_codes); this is 0017.

-- Every webhook event RevenueCat sends, verbatim, keyed by RevenueCat's own
-- event id. This is an audit log and a dedupe table, nothing more: no other
-- table references it, and no RevenueCat identifier appears anywhere else, so
-- the provider can be swapped without touching the economy. `applied` says
-- whether the event produced a ledger row; `note` says why not when it did
-- not (unknown product, sandbox event for a non-dev wallet, unmapped user).
CREATE TABLE rc_events (
    id                      TEXT PRIMARY KEY,
    type                    TEXT NOT NULL,
    app_user_id             TEXT,
    user_id                 TEXT,
    transaction_id          TEXT,
    original_transaction_id TEXT,
    product_id              TEXT,
    store                   TEXT,
    environment             TEXT,
    price                   REAL,
    currency                TEXT,
    purchased_at_ms         INTEGER,
    event_timestamp_ms      INTEGER,
    received_at             TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    applied                 INTEGER NOT NULL DEFAULT 0,
    note                    TEXT,
    payload_json            TEXT
);
CREATE INDEX idx_rc_events_user ON rc_events (user_id, received_at);
CREATE INDEX idx_rc_events_tx   ON rc_events (transaction_id);

-- When the wallet's claim token was first presented successfully. NULL while
-- the token has never been used, which is the one state in which the server
-- will mint a replacement (the response carrying the token was lost). See
-- coinClaimCheck / coinClaimIssue in the worker.
ALTER TABLE coin_wallets ADD COLUMN claim_used_at TEXT;

-- Net paid coins credited to this wallet: purchases minus refunds, plus the
-- paid portion carried across by an anonymous-to-account merge. Free and paid
-- coins share one balance (B2 in the brief); this column is what lets the
-- split be read back without summing the ledger:
--
--   free coins still unspent = MAX(0, lifetime_earned - lifetime_spent)
--   paid coins still unspent = balance - (that)
--   paid coins consumed      = MAX(0, lifetime_spent - lifetime_earned)
--
-- because free coins are always spent first — not per coin, by arithmetic.
ALTER TABLE coin_wallets ADD COLUMN lifetime_purchased INTEGER NOT NULL DEFAULT 0;

-- The trigger learns to route money rows into the new column instead of
-- lifetime_earned / lifetime_spent, which from here on count only the free
-- economy (grants, gifts, merges). No purchase or refund row exists before
-- this migration, so the existing columns keep their meaning for every row
-- already written.
--
-- A merge row may carry paid coins too (someone bought a pack anonymously,
-- then signed in). coinMergeWallet says how many in meta_json as
-- {"paid": N} (negative on the merge-out row), and the trigger honours it, so
-- the paid/free split survives the account link with the ledger still the
-- only thing anyone writes.
DROP TRIGGER coin_ledger_ai;
CREATE TRIGGER coin_ledger_ai AFTER INSERT ON coin_ledger BEGIN
    INSERT INTO coin_wallets (user_id, balance, lifetime_earned, lifetime_spent, lifetime_purchased)
    VALUES (
        NEW.user_id,
        NEW.delta,
        MAX(NEW.delta - (CASE WHEN NEW.kind IN ('purchase', 'refund') THEN NEW.delta
                              ELSE COALESCE(json_extract(NEW.meta_json, '$.paid'), 0) END), 0),
        MAX((CASE WHEN NEW.kind IN ('purchase', 'refund') THEN NEW.delta
                  ELSE COALESCE(json_extract(NEW.meta_json, '$.paid'), 0) END) - NEW.delta, 0),
        (CASE WHEN NEW.kind IN ('purchase', 'refund') THEN NEW.delta
              ELSE COALESCE(json_extract(NEW.meta_json, '$.paid'), 0) END)
    )
    ON CONFLICT(user_id) DO UPDATE SET
        balance            = balance + NEW.delta,
        lifetime_earned    = lifetime_earned
            + MAX(NEW.delta - (CASE WHEN NEW.kind IN ('purchase', 'refund') THEN NEW.delta
                                    ELSE COALESCE(json_extract(NEW.meta_json, '$.paid'), 0) END), 0),
        lifetime_spent     = lifetime_spent
            + MAX((CASE WHEN NEW.kind IN ('purchase', 'refund') THEN NEW.delta
                        ELSE COALESCE(json_extract(NEW.meta_json, '$.paid'), 0) END) - NEW.delta, 0),
        lifetime_purchased = lifetime_purchased
            + (CASE WHEN NEW.kind IN ('purchase', 'refund') THEN NEW.delta
                    ELSE COALESCE(json_extract(NEW.meta_json, '$.paid'), 0) END),
        updated_at         = CURRENT_TIMESTAMP;
END;
