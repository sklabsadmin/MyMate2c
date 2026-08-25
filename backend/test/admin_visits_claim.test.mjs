// The coin claim steps in the visits funnel. Two buttons — "Tap to Claim
// Coins" (entry_tap) and "Collect and begin" (claim_tap) — plus the screen
// itself (claim_shown) must each surface as their own funnel column, or the
// admin cannot tell one tap from the other.

import test from 'node:test';
import assert from 'node:assert/strict';
import { testEnv, adminFetch } from './harness.mjs';

test('the funnel counts the Claim Coins tap, the coins screen, and the Collect tap separately', async () => {
  const { env, db } = testEnv();
  const ins = db.prepare(
    "INSERT INTO site_visits (id, visit_id, event, created_at, path, source) VALUES (?, ?, ?, datetime('now'), '/c/hercules', 'ig')"
  );
  // One visitor who went all the way: arrived, saw the card, tapped Claim
  // Coins, saw the coins screen, tapped Collect.
  let n = 0;
  for (const e of ['arrive', 'app_ready', 'entry_shown', 'entry_tap', 'claim_shown', 'claim_tap']) {
    ins.run(`c${n++}`, 'v_claimer', e);
  }
  // A second visitor who tapped Claim Coins and saw the screen but did NOT
  // collect — this is the drop the two separate events exist to expose.
  for (const e of ['arrive', 'app_ready', 'entry_shown', 'entry_tap', 'claim_shown']) {
    ins.run(`c${n++}`, 'v_bailed', e);
  }

  const res = await adminFetch(env, '/api/admin/visits?days=1');
  assert.equal(res.status, 200);
  const ig = res.json.funnel.find((r) => r.source === 'ig');
  assert.ok(ig, 'an ig funnel row');
  assert.equal(ig.entry_tap, 2, 'both tapped Claim Coins');
  assert.equal(ig.claim_shown, 2, 'both saw the coins screen');
  assert.equal(ig.claim_tap, 1, 'only one tapped Collect');
});
