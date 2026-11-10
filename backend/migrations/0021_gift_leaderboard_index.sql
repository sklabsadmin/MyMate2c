-- Leaderboards (backend/src/leaderboard.js): who has given a character the
-- most, by coins. Every board is a GROUP BY over the gift rows of one
-- character, and the only gift index so far is (reason, created_at), which
-- makes each read walk every gift ever given. This one finds a character's
-- rows directly and already holds the user to group by.
--
-- Partial, because gifts are a small slice of the ledger (replies and daily
-- grants dominate it) and nothing else is ever looked up by ref this way.
CREATE INDEX IF NOT EXISTS idx_coin_ledger_gift_ref
    ON coin_ledger (ref, user_id)
    WHERE reason = 'gift';
