// logs.<domain> is a custom domain for the admin tools only. A custom domain
// binds the whole hostname, so the worker has to turn everything else away
// there itself. The guard used to sit below the campaign-link and /auth/*
// handlers, so the admin host still started Google sign-in — against a
// callback Google has never heard of, which ended on redirect_uri_mismatch.

import test from 'node:test';
import assert from 'node:assert/strict';
import { loadWorker, testEnv, ADMIN_AUTH } from './harness.mjs';

async function hit(env, url, headers = {}) {
    const worker = await loadWorker();
    return worker.fetch(new Request(url, { headers, redirect: 'manual' }), env, {
        waitUntil() {},
        passThroughOnException() {},
    });
}

function googleEnv() {
    const { env } = testEnv();
    return { ...env, GOOGLE_CLIENT_ID: 'test-client', GOOGLE_CLIENT_SECRET: 'test-secret' };
}

for (const path of ['/auth/google/start', '/auth/google/callback', '/auth/instagram/start', '/auth/me', '/c/zeus']) {
    test(`the admin host bounces ${path} to /admin`, async () => {
        const res = await hit(googleEnv(), 'https://logs.mythos.test' + path);
        assert.equal(res.status, 302);
        assert.equal(res.headers.get('location'), 'https://logs.mythos.test/admin');
    });
}

test('the admin host still serves the admin pages', async () => {
    const res = await hit(googleEnv(), 'https://logs.mythos.test/admin', { Authorization: ADMIN_AUTH });
    assert.equal(res.status, 200);
});

test('Google sign-in on a chat host calls back to that same host', async () => {
    const res = await hit(googleEnv(), 'https://chat.mythos.test/auth/google/start');
    assert.equal(res.status, 302);
    const auth = new URL(res.headers.get('location'));
    assert.equal(auth.origin, 'https://accounts.google.com');
    assert.equal(auth.searchParams.get('redirect_uri'), 'https://chat.mythos.test/auth/google/callback');
});
