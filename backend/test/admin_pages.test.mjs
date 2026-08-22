// The admin pages themselves.
//
// Every page is one big template literal holding the JavaScript the browser
// will run, which means a stray backtick or an accidental ${...} produces a
// page that serves 200 and does nothing — the failure mode that cannot be seen
// from the server side. These tests render each page and parse its inline
// script, which is the cheapest possible stand-in for opening it.

import test from 'node:test';
import assert from 'node:assert/strict';
import { adminFetch, testEnv } from './harness.mjs';

const PAGES = [
    ['/admin', 'Mythos Live — Admin'],
    ['/admin/sessions', 'User sessions'],
    ['/admin/visits', 'Site visits'],
    ['/admin/referrals', 'Campaign'],
    ['/admin/logs', 'Chat Logs'],
    ['/admin/deploys', 'Deploy log'],
    ['/admin/delivery', 'Message delivery'],
    ['/admin/coins', 'Coins'],
];

for (const [pathname, marker] of PAGES) {
    test(`${pathname} renders and its inline script parses`, async () => {
        const { env } = testEnv();
        const res = await adminFetch(env, pathname);
        assert.equal(res.status, 200);
        assert.match(res.headers.get('Content-Type'), /text\/html/);
        assert.ok(res.text.includes(marker), `page did not contain "${marker}"`);

        const scripts = [...res.text.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
        for (const [i, body] of scripts.entries()) {
            // Throws on a template literal that closed early, an unescaped
            // backtick, or an interpolation that ran at build time and left
            // broken syntax behind.
            assert.doesNotThrow(() => new Function(body), `${pathname} script ${i} does not parse`);
        }
    });
}

test('the sessions colspans match the number of columns in the header', async () => {
    const { env } = testEnv();
    const res = await adminFetch(env, '/admin/sessions');
    // A column added to the header and forgotten in the colspan of the
    // drill-down row shifts everything under it, and the page still renders —
    // so this is invisible until someone reads a number off the wrong column.
    // The header is built as one concatenated expression, so it can be read
    // straight out of the page source between the table tag and its </tr>.
    const header = res.text.slice(
        res.text.indexOf('<table class="sortable"><tr>'),
        res.text.indexOf("</tr>'")
    );
    const columns = (header.match(/<th[ >]/g) || []).length;
    assert.ok(columns > 10, `only found ${columns} columns — the header moved`);

    const colspans = [...res.text.matchAll(/colspan="(\d+)"/g)].map((m) => Number(m[1]));
    assert.ok(colspans.length >= 2, 'expected the drill-down and empty-state colspans');
    for (const span of colspans) {
        assert.equal(span, columns,
            `a colspan of ${span} against ${columns} header columns`);
    }
});

test('the admin index links every page that exists', async () => {
    const { env } = testEnv();
    const res = await adminFetch(env, '/admin');
    for (const [pathname] of PAGES) {
        if (pathname === '/admin') continue;
        assert.ok(res.text.includes(`href="${pathname}"`), `the index does not link ${pathname}`);
    }
});
