-- Gift reactions: a thank-you is owed until the visitor has seen it.
--
-- A gift is charged before the model is called (the spend is the one
-- conditional INSERT that makes the economy honest), so a reply that fails
-- upstream, or never reaches the phone, leaves the visitor paid up and
-- unthanked — the reaction is the gift's entire visible effect. Rather than
-- refund (a reversal row would make a replay of the same id free forever,
-- and the keepsake it bought is already held), the thanks becomes a debt the
-- character carries: every later turn with that character reads the owed
-- rows and is told to thank them again, in fresh words, until the client
-- says the thanks was rendered.
--
-- One row per charged gift, keyed by the ledger row that paid for it.
-- attempt_log_id is the conversation_logs row whose reply last carried the
-- thanks (the giving turn, then each retry); the client acknowledges by gift
-- id on its next request once those bubbles have been drawn. attempts is
-- capped in the worker so a client that never acknowledges cannot turn a
-- character into a thank-you loop.

CREATE TABLE gift_reactions (
    gift_id         TEXT PRIMARY KEY,
    user_id         TEXT NOT NULL,
    ref             TEXT NOT NULL,
    item            TEXT NOT NULL,
    given_at        TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    attempt_log_id  TEXT,
    attempts        INTEGER NOT NULL DEFAULT 1,
    acknowledged_at TEXT
);

CREATE INDEX idx_gift_reactions_owed
    ON gift_reactions (user_id, ref) WHERE acknowledged_at IS NULL;
