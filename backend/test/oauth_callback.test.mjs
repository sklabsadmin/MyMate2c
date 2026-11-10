// Where a sign-in that did not complete sends the user back to.
//
// The app keeps its chat history and anonymous id per origin, so landing on a
// different host than the one sign-in started on looks like a brand-new user
// with an empty app. The callback always arrives on the starting host (the
// redirect URI is built from it), so that is where every outcome must land —
// never APP_ORIGIN. Cancelling on Google's consent screen is the common case:
// it comes back with error=access_denied and no code.

import test from 'node:test';
import assert from 'node:assert/strict';
import { loadWorker, testEnv } from './harness.mjs';

const HOST = 'https://chat.mythos.test';

async function hit(path, cookie) {
    const { env } = testEnv();
    const worker = await loadWorker();
    const headers = cookie ? { Cookie: cookie } : {};
    return worker.fetch(new Request(HOST + path, { headers, redirect: 'manual' }), {
        ...env,
        APP_ORIGIN: 'https://elsewhere.workers.test',
        GOOGLE_CLIENT_ID: 'test-client',
        GOOGLE_CLIENT_SECRET: 'test-secret',
    }, { waitUntil() {}, passThroughOnException() {} });
}

for (const provider of ['google', 'instagram']) {
    const stateCookie = provider === 'google' ? 'mymate_google_state' : 'mymate_ig_state';

    test(`a cancelled ${provider} sign-in lands back on the starting host`, async () => {
        const res = await hit(`/auth/${provider}/callback?error=access_denied&state=s1`,
            `${stateCookie}=s1|${HOST}/settings?${provider}=connected|`);
        assert.equal(res.status, 302);
        assert.equal(res.headers.get('location'), `${HOST}/settings?${provider}=failed`);
    });

    test(`a ${provider} callback with an expired state cookie lands on the starting host`, async () => {
        const res = await hit(`/auth/${provider}/callback?code=c1&state=s1`);
        assert.equal(res.headers.get('location'), `${HOST}/settings?${provider}=failed`);
    });

    test(`a ${provider} callback with a mismatched state lands on the starting host`, async () => {
        const res = await hit(`/auth/${provider}/callback?code=c1&state=forged`,
            `${stateCookie}=s1|${HOST}/settings|`);
        assert.equal(res.headers.get('location'), `${HOST}/settings?${provider}=failed`);
    });
}

test('a failed Google token exchange lands on the starting host', async () => {
    const realFetch = globalThis.fetch;
    globalThis.fetch = async () => new Response(JSON.stringify({ error: 'invalid_grant' }), { status: 400 });
    try {
        const res = await hit('/auth/google/callback?code=c1&state=s1',
            `mymate_google_state=s1|${HOST}/settings?google=connected|`);
        assert.equal(res.headers.get('location'), `${HOST}/settings?google=failed`);
    } finally {
        globalThis.fetch = realFetch;
    }
});
