'use strict';
// A kiosk must index an SNMPCanvas v3 feed and a v4 feed identically.
//
//   node tools/test-snmp-schema.js
//
// Version skew between siblings is expected, not exceptional: the whole point
// of separate repositories is that someone updates SNMPCanvas on Tuesday and
// the kiosk Pi in March. v4 flattened `device` from an object to a string and
// moved `sampledAt` to epoch seconds, so a kiosk that only understood v4 would
// go blank against the older feed and vice versa.
//
// The failure this guards against is quiet. A board whose annotations stop
// binding still renders perfectly - it just has no numbers on it, which looks
// like a device problem rather than a schema problem.
//
// buildIndex is private to snmp-layer's IIFE. Rather than re-implement it here
// (a copy would drift and then test nothing), the real function source is
// lifted out of the shipped file and evaluated, so an edit to buildIndex is an
// edit to what this tests.

const fs = require('node:fs');
const path = require('node:path');

const SRC = process.argv[2] || path.join(__dirname, '..', 'kiosk', 'snmp-layer.js');
const src = fs.readFileSync(SRC, 'utf8');

function extract(name) {
    const start = src.indexOf('function ' + name + '(');
    if (start < 0) throw new Error(`cannot find function ${name} in ${SRC}`);
    let depth = 0;
    let i = src.indexOf('{', start);
    for (; i < src.length; i++) {
        if (src[i] === '{') depth++;
        else if (src[i] === '}') { depth--; if (depth === 0) break; }
    }
    return src.slice(start, i + 1);
}

// eslint-disable-next-line no-new-func
const buildIndex = new Function(`${extract('fmtBps')}\n${extract('buildIndex')}\nreturn buildIndex;`)();

// The same port, described both ways.
const common = {
    code: 'K7Q2', ifIndex: 1, name: 'Gi0/1', alias: 'uplink to fw',
    speedBps: 1e9, adminStatus: 'up', operStatus: 'up',
    inBps: 12345678, outBps: 234567,
    inErrorsPerSec: 0.033, outErrorsPerSec: 0, inDiscardsPerSec: 0, outDiscardsPerSec: 0
};
const v3 = { schemaVersion: 3, metrics: [], interfaces: [{
    ...common,
    id: 'core-sw1:Gi0/1',
    device: { name: 'core-sw1', host: '10.0.0.2', status: 'up' },
    sampledAt: '2026-07-25T12:00:00.000Z'
}] };
const v4 = { schemaVersion: 4, metrics: [], interfaces: [{
    ...common,
    device: 'core-sw1',
    sampledAt: 1784980800
}] };

const i3 = buildIndex(v3);
const i4 = buildIndex(v4);
const k3 = Object.keys(i3).sort();
const k4 = Object.keys(i4).sort();

let failures = 0;
function check(name, pass, detail) {
    console.log(`${pass ? '  ok  ' : ' FAIL '} ${name}${detail ? '   ' + detail : ''}`);
    if (!pass) failures++;
}

console.log('v3 keys:', JSON.stringify(k3));
console.log('v4 keys:', JSON.stringify(k4), '\n');

check('v4 produces the same keys as v3', JSON.stringify(k3) === JSON.stringify(k4));
check('"Device:ifName" still binds', k4.includes('core-sw1:Gi0/1'), '(what most board annotations use)');
check('the short code still binds', k4.includes('K7Q2'));
check('"Device:alias" still binds', k4.includes('core-sw1:uplink to fw'));
check('display text is identical across versions', i3.K7Q2.display === i4.K7Q2.display, JSON.stringify(i4.K7Q2.display));

console.log(failures ? `\n${failures} check(s) FAILED` : '\na kiosk binds either schema');
process.exit(failures ? 1 : 0);
