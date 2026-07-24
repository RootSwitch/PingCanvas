'use strict';
// Drives the real kiosk/status-layer.js under node with a stub fetch.
// Three properties, the middle one being the regression this change could
// easily have introduced:
//   1. fetches run at HALF the poller's advertised interval
//   2. the stale threshold still uses the FULL interval, so a healthy feed
//      whose file is legitimately mid-cycle does NOT trip the banner
//   3. a genuinely stalled poller still does
const fs = require('fs');
const path = require('path');

const SRC = process.argv[2] || path.join(__dirname, 'status-layer.js');
const g = {};
const scheduled = [];
global.setTimeout = (fn, ms) => { scheduled.push(ms); return scheduled.length; };
global.clearTimeout = () => {};

let fileAgeSec = 0;
global.fetch = () => Promise.resolve({
    ok: true,
    json: () => Promise.resolve({
        pollIntervalSec: 30,
        generated: new Date(Date.now() - fileAgeSec * 1000).toISOString(),
        devices: {}
    })
});

// The file ends with `})(typeof window !== 'undefined' ? window : this)`, so
// with no window it attaches to `this` - bind that to our sandbox object.
new Function(fs.readFileSync(SRC, 'utf8')).call(g);

let stale = null;
const feed = new g.StatusFeed({ url: 's.json', onStatus: () => {}, onStale: (i) => { stale = i; } });

let failed = 0;
const check = (name, got, want) => {
    const okk = got === want;
    if (!okk) failed++;
    console.log(`${okk ? 'PASS' : 'FAIL'}  ${name}: got ${got}, want ${want}`);
};

// _tick() does not RETURN its promise chain, so awaiting it resolves
// immediately and every assertion after would read the previous tick's result.
// Drain the microtask queue instead.
const settle = () => new Promise((r) => setImmediate(r));

(async () => {
    // A file 25s old: mid-cycle on a 30s poller, entirely healthy.
    fileAgeSec = 25;
    feed.start();
    await settle();
    check('fetch cadence is half the 30s feed interval', scheduled[scheduled.length - 1], 15000);
    check('staleness basis is still the full interval', feed._interval, 30);
    check('healthy mid-cycle file is not stale', stale, null);

    // 45s: the worst age this change can now produce (1.5x interval). Under a
    // naive fix that halved _interval, the threshold would be 30s and this
    // would false-alarm on every healthy wall.
    fileAgeSec = 45;
    feed._tick(); await settle();
    check('worst-case healthy age (1.5x) is not stale', stale, null);

    // 70s: past 2x. The poller really has stopped.
    fileAgeSec = 70;
    feed._tick(); await settle();
    check('a stalled poller still trips stale', stale && stale.reason, 'age');

    console.log(failed ? `\n${failed} check(s) failed` : '\nall checks passed');
    process.exit(failed ? 1 : 0);
})();
