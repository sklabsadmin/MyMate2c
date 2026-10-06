-- Keepsakes: who holds which once-only gift, so it can follow a sign-in.
--
-- Until now a keepsake (the pendant, the golden laurel) was only its ledger
-- row, id `gift:<item>:<userId>:<ref>`, and every read derived what a person
-- had given from those ids. That breaks at sign-in: coinMergeWallet moves the
-- coin BALANCE onto the account with merge:out / merge:in rows, but a gift
-- row stays under the anonymous id it was written for, so the account holds
-- nothing. The profile's "Gifts From You" goes blank, the gift sheet offers
-- the pendant for sale again, and the character forgets the keepsake note.
--
-- The ledger cannot carry it. A zero-delta "copy" row is refused by
-- CHECK (delta <> 0), and rewriting user_id on the old rows would break the
-- coin_wallets caches (and the rule that ledger rows are never UPDATEd).
-- Nor can a read follow the link back to the anonymous id: merge rows exist
-- only when the anonymous balance was non-zero (the laurel buyer often spent
-- it all), while the link bonus and linked_accounts.merged_anon_id are both
-- written even when the merge was REFUSED — and a refused merge must not
-- hand over a keepsake any more than it hands over coins.
--
-- So this table records holding, separately from paying:
--
--   * a gift row creates a holding row, in the same atomic step, through the
--     trigger below (the coin_wallets idiom: nothing in the worker writes it
--     for a gift, so nothing can forget to);
--   * an allowed merge copies the anonymous holdings onto the account and
--     marks the originals moved_to, in the same batch as the coin rows. A
--     refused merge touches neither. The originals are marked, not deleted,
--     so the trail reads both ways like merge:out / merge:in do.
--
-- The ledger stays the record of what was PAID; this table is the record of
-- what is HELD. Gift-made rows can be rebuilt from the ledger (the backfill
-- below is exactly that rebuild); merge-made rows carry from_user_id and
-- gift_id, which say where they came from and which ledger row paid.

CREATE TABLE coin_keepsakes (
    id           INTEGER PRIMARY KEY,
    -- Who holds it now.
    user_id      TEXT NOT NULL,
    -- The catalogue key (pendant | laurel). Reads filter by the live
    -- catalogue, so a retired item stays stored but stops being shown.
    item         TEXT NOT NULL,
    -- To whom it was given: a character id, or the chat id for a custom
    -- character — the same value as the gift row's ref.
    ref          TEXT NOT NULL,
    -- When it was originally given (the gift row's created_at), carried
    -- unchanged across a merge so the profile's date stays the real one.
    given_at     TEXT NOT NULL,
    -- The coin_ledger row that paid for it, under whichever user paid.
    gift_id      TEXT NOT NULL,
    -- NULL when this user gave it; otherwise the id a merge carried it from.
    from_user_id TEXT,
    -- Set when a merge carried this holding onto another user. A moved row
    -- is history, not a holding: every read asks for moved_to IS NULL.
    moved_to     TEXT,
    created_at   TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- One live holding per (user, item, character). Partial, not a primary key,
-- because moved rows must not block a new one: a holder whose keepsake moved
-- away and who later pays for the same gift again must end up holding it,
-- not charged for an INSERT that the key silently ignored. It is also the
-- index every read uses (they all filter moved_to IS NULL).
CREATE UNIQUE INDEX idx_coin_keepsakes_held
    ON coin_keepsakes (user_id, item, ref) WHERE moved_to IS NULL;

-- A keepsake is a gift spend whose id has the once-only shape. Client gift
-- ids are [A-Za-z0-9_-]{8,64}, so a repeatable gift's `gift:<clientId>` can
-- never contain a second colon; only the derived keys match 'gift:%:%:%'.
-- The item is the first segment after 'gift:' — user ids (google:<sub>) and
-- chat ids may themselves contain colons, so nothing after it is parsed;
-- user and ref come from their own columns. OR IGNORE: the ledger id already
-- makes a second giving a no-op, so a conflict here is the same no-op.
CREATE TRIGGER coin_ledger_keepsake AFTER INSERT ON coin_ledger
WHEN NEW.kind = 'spend' AND NEW.reason = 'gift' AND NEW.ref IS NOT NULL
     AND NEW.id LIKE 'gift:%:%:%'
BEGIN
    INSERT OR IGNORE INTO coin_keepsakes (user_id, item, ref, given_at, gift_id, created_at)
    VALUES (
        NEW.user_id,
        substr(NEW.id, 6, instr(substr(NEW.id, 6), ':') - 1),
        NEW.ref,
        NEW.created_at,
        NEW.id,
        NEW.created_at
    );
END;

-- Backfill: every keepsake already given, from the same rule the trigger
-- applies, oldest first so ids keep the order they were given in. Nothing
-- has been merged yet under this table, so every row starts with its giver.
-- The anonymous holdings of accounts that ALREADY signed in stay where they
-- were; carrying those across retroactively would need the merge outcome,
-- which (see above) the database does not record.
INSERT OR IGNORE INTO coin_keepsakes (user_id, item, ref, given_at, gift_id, created_at)
SELECT user_id,
       substr(id, 6, instr(substr(id, 6), ':') - 1),
       ref,
       created_at,
       id,
       created_at
FROM coin_ledger
WHERE kind = 'spend' AND reason = 'gift' AND ref IS NOT NULL
  AND id LIKE 'gift:%:%:%'
ORDER BY created_at, rowid;
