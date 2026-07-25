'use strict';
// Proves the kiosk indexes v3 and v4 feeds identically.
//
// buildIndex is private to snmp-layer's IIFE, so rather than re-implement it
// (which would drift from the shipped code and test nothing), the real function
// source is extracted from the file and evaluated. If someone edits
// buildIndex, this test sees the edit.
const fs = require('fs');
const path = require('path');

const SRC = process.argv[2] || path.join(__dirname, 'snmp-layer.js');
const src = fs.readFileSync(SRC, 'utf8');

function extract(name) {
    const start = src.indexOf('function ' + name + '(');
    if (start < 0) throw new Error('cannot find function ' + name);
    let depth = 0, i = src.indexOf('{', start);
    const from = i;
    for (; i < src.length; i++) {
        if (src[i] === '{') depth++;
        else if (src[i] === '}') { depth--; if (depth === 0) break; }
    }
    return src.slice(start, i + 1);
}

// eslint-disable-next-line no-new-func
const mk = new Function(extract('fmtBps') + '\n' + extract('buildIndex') + '\nreturn buildIndex;');
const buildIndex = mk();

// Same underlying data, expressed both ways.
const common = {
    code: 'K7Q2', ifIndex: 1, name: 'Gi0/1', alias: 'uplink to fw',
    speedBps: 1e9, adminStatus: 'up', operStatus: 'up',
    inBps: 12345678, outBps: 234567,
    inErrorsPerSec: 0.033, outErrorsPerSec: 0, inDiscardsPerSec: 0, outDiscardsPerSec: 0
};
const v3 = { schemaVersion: 3, interfaces: [Object.assign({
    id: 'core-sw1:Gi0/1', device: { name: 'core-sw1', host: '10.0.0.2', status: 'up' },
    sampledAt: '2026-07-25T12:00:00.000Z' }, common)], metrics: [] };
const v4 = { schemaVersion: 4, interfaces: [Object.assign({
    device: 'core-sw1', sampledAt: 1784980800 }, common)], metrics: [] };

const i3 = buildIndex(v3);
const i4 = buildIndex(v4);
const k3 = Object.keys(i3).sort();
const k4 = Object.keys(i4).sort();

let fail = 0;
const chk = (label, ok, detail) => { if (!ok) fail++; console.log((ok ? 'PASS' : 'FAIL') + '  ' + label + (detail ? '  ' + detail : '')); };

console.log('v3 index keys:', JSON.stringify(k3));
console.log('v4 index keys:', JSON.stringify(k4));
console.log('');
chk('v4 produces the same keys as v3', JSON.stringify(k3) === JSON.stringify(k4));
chk('the "Device:ifName" key still binds', k4.indexOf('core-sw1:Gi0/1') >= 0, '(board annotations use this)');
chk('the short code still binds', k4.indexOf('K7Q2') >= 0);
chk('the "Device:alias" key still binds', k4.indexOf('core-sw1:uplink to fw') >= 0);
chk('display text matches between versions', i3['K7Q2'].display === i4['K7Q2'].display, JSON.stringify(i4['K7Q2'].display));

console.log('\n' + (fail ? fail + ' check(s) FAILED' : 'all checks passed - a kiosk binds either schema'));
process.exit(fail ? 1 : 0);
