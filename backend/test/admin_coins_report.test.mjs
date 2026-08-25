// The coins page's judgement calls: what counts as a return, what counts as
// an engaged wallet, and whose wallets are the developer's own. Each test is
// named for the mistake it catches.

import test from 'node:test';
import assert from 'node:assert/strict';
import { freshDb, d1, adminFetch, ADMIN_TOKEN } from './harness.mjs';

function bareEnv() {
  const db = freshDb();
  return { env: { CHAT_LOGS_DB: d1(db), ADMIN_TOKEN }, db };
}

test('a second dawn offering is what counts as a return, not a second visit', async () => {
  const { env, db } = bareEnv();
  const grant = db.prepare(
    "INSERT INTO coin_ledger (id, user_id, created_at, delta, kind, reason) VALUES (?, ?, ?, 20, 'grant', 'daily')"
  );
  // A came back: dailies on two different days. B claimed once and vanished.
  grant.run('d1', 'user_1700000000001', '2026-08-20 08:00:00');
  grant.run('d2', 'user_1700000000001', '2026-08-21 09:00:00');
  grant.run('d3', 'user_1700000000002', '2026-08-21 10:00:00');

  const res = await adminFetch(env, '/api/admin/coins?days=90');
  assert.equal(res.status, 200);
  const ret = res.json.retention;
  assert.equal(ret.claimers, 2);
  assert.equal(ret.returned, 1, 'only A claimed on a second day');
  assert.equal(ret.best_streak_days, 2);
  // The 21st: two claims, one from a returning user, one first-timer.
  const day21 = ret.by_day.find((r) => r.day === '2026-08-21');
  assert.equal(day21.claims, 2);
  assert.equal(day21.repeat_claims, 1);
});

test('a wallet full of automatic grants is not an engaged user', async () => {
  const { env, db } = bareEnv();
  const row = db.prepare(
    "INSERT INTO coin_ledger (id, user_id, delta, kind, reason) VALUES (?, ?, ?, ?, ?)"
  );
  // A: only the automatic pair — 100 coins, zero engagement.
  row.run('a1', 'user_1700000000001', 80, 'grant', 'welcome');
  row.run('a2', 'user_1700000000001', 20, 'grant', 'daily');
  // B: earned a reply grant — engaged.
  row.run('b1', 'user_1700000000002', 80, 'grant', 'welcome');
  row.run('b2', 'user_1700000000002', 8, 'grant', 'reply');
  // C: the developer — a beacon row ties this user id to Thailand.
  row.run('c1', 'user_1700000000003', 80, 'grant', 'welcome');
  db.prepare(
    "INSERT INTO site_visits (id, visit_id, event, created_at, path, source, country, app_user_id) VALUES ('sv1', 'v_dev', 'character_tap', datetime('now'), '/c/zeus', 'ig', 'TH', 'user_1700000000003')"
  ).run();

  const res = await adminFetch(env, '/api/admin/coins?days=14');
  assert.equal(res.status, 200);
  assert.equal(res.json.totals.engaged_wallets, 1, 'only B did anything beyond the automatics');
  assert.equal(res.json.totals.test_wallets, 1, 'C is the developer');
  assert.equal(res.json.totals.real_wallets, 2);
  const c = res.json.top_wallets.find((w) => w.user_id === 'user_1700000000003');
  const b = res.json.top_wallets.find((w) => w.user_id === 'user_1700000000002');
  assert.equal(c.test, true);
  assert.equal(b.engaged, true);
  assert.equal(b.test, false);
});
