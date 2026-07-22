/*
 * status-layer.js - renderer-agnostic status polling + staleness for PingCanvas.
 *
 * This module owns the poll loop, the pollIntervalSec/staleness math, and the
 * status->color mapping. It knows NOTHING about the SVG renderer. The forked
 * CrossCanvas kiosk wires it up by supplying two callbacks:
 *
 *   onStatus(doc, meta)          -> the whole parsed feed + staleness meta. The
 *                                   device consumer reads doc.devices and, per
 *                                   board device, looks up its key (via
 *                                   StatusFeed.entryFor, trim + case tolerant)
 *                                   to set the status ring to STATE_COLORS[state];
 *                                   the SNMP consumer reads doc.interfaces /
 *                                   doc.metrics. A device with no entry =
 *                                   'unmonitored'.
 *   onStale(info | null)         -> info != null: show the STALE banner + desaturate
 *                                   the board. null: clear it.
 *
 * Usage in the kiosk:
 *   var feed = new StatusFeed({
 *     url: params.status || 'status.json',
 *     interval: params.interval || null,          // else uses the file's pollIntervalSec
 *     staleMul: params.staleMul || 2,
 *     onStatus: applyStatusToBoard,
 *     onStale:  showStaleBanner
 *   });
 *   feed.start();
 */
(function (global) {
    'use strict';

    // Status palette - deliberately separate from the board theme's device tint,
    // so status reads clearly without fighting the diagram's colors.
    var STATE_COLORS = {
        up:          '#2e9b57',   // green
        degraded:    '#d9a406',   // amber
        down:        '#d64545',   // red
        unknown:     '#8a8f98',   // gray  (in feed, state unknown)
        unmonitored: '#8a8f98',   // gray  (board device, no feed entry)
        stale:       '#8a8f98'    // gray  (whole board, poller stale)
    };

    function StatusFeed(opts) {
        opts = opts || {};
        this.url              = opts.url || 'status.json';
        this.staleMul         = opts.staleMul || 2;
        // Same >= 1 clamp the feed's advertised interval gets below - a negative
        // ?interval= URL override would otherwise setTimeout(…, <0) = busy-poll.
        this.intervalOverride = (Number(opts.interval) >= 1) ? Number(opts.interval) : null;
        this.onStatus         = opts.onStatus || function () {};
        this.onStale          = opts.onStale  || function () {};
        this._timer    = null;
        this._misses   = 0;
        this._interval = this.intervalOverride || 30;
    }

    StatusFeed.prototype.start = function () { this._tick(); };
    StatusFeed.prototype.stop  = function () { if (this._timer) { clearTimeout(this._timer); this._timer = null; } };

    StatusFeed.prototype._schedule = function () {
        this.stop();
        this._timer = setTimeout(this._tick.bind(this), this._interval * 1000);
    };

    StatusFeed.prototype._tick = function () {
        var self = this;
        var sep  = this.url.indexOf('?') < 0 ? '?' : '&';
        fetch(this.url + sep + 't=' + Date.now(), { cache: 'no-store' })
            .then(function (r) { if (!r.ok) { throw new Error('HTTP ' + r.status); } return r.json(); })
            .then(function (doc) {
                self._misses = 0;
                // Clamp the advertised interval: a negative/NaN value would make
                // setTimeout fire as fast as possible (busy-poll).
                var n = Number(doc.pollIntervalSec);
                if (!self.intervalOverride && n >= 1) { self._interval = n; }
                // Fail SAFE on a missing/garbage 'generated' timestamp: Date.parse
                // returns NaN, and (NaN > threshold) is false, which would leave the
                // board looking healthy forever. Treat an unparseable timestamp as
                // stale - the staleness banner is the whole safety net.
                // Device feed timestamps as 'generated'; the SNMP feed as
                // 'generatedAt'. NaN handling below treats either being absent
                // or garbage as stale.
                var t = Date.parse(doc.generated || doc.generatedAt);
                var ageSec = (Date.now() - t) / 1000;
                var stale  = !isFinite(t) || ageSec > self.staleMul * self._interval;
                // Pass the WHOLE doc; each consumer reads its own shape
                // (applyStatus -> doc.devices, applySnmp -> doc.interfaces).
                self.onStatus(doc, { generated: doc.generated || doc.generatedAt, ageSec: ageSec, stale: stale });
                self.onStale(stale ? { reason: isFinite(t) ? 'age' : 'badtime', ageSec: ageSec } : null);
            })
            .catch(function (err) {
                // Keep the last good render; two misses in a row => stale.
                self._misses++;
                if (self._misses >= 2) { self.onStale({ reason: 'fetch', error: String(err) }); }
            })
            .then(function () { self._schedule(); });
    };

    // Look up a device's status entry by key, tolerating the same
    // normalization the poller applies. The poller TRIMS Monitor ID / IP and
    // dedups keys CASE-INSENSITIVELY, so a board field with a stray space or a
    // different case would otherwise leave an actively-probed device rendered
    // as a permanent gray "unmonitored". Exact match first (the common path);
    // a trimmed+lowercased index is built once per doc and memoized on it, so
    // repeated per-device calls in one poll stay O(1).
    StatusFeed.entryFor = function (devicesByIp, key) {
        if (!key || !devicesByIp) { return null; }
        key = String(key).trim();
        var e = devicesByIp[key];
        if (e) { return e; }
        var idx = devicesByIp.__lcIndex;
        if (!idx) {
            idx = {};
            for (var k in devicesByIp) {
                if (k === '__lcIndex' || !Object.prototype.hasOwnProperty.call(devicesByIp, k)) { continue; }
                idx[String(k).trim().toLowerCase()] = devicesByIp[k];
            }
            try { Object.defineProperty(devicesByIp, '__lcIndex', { value: idx, enumerable: false }); }
            catch (_) { devicesByIp.__lcIndex = idx; }
        }
        return idx[key.toLowerCase()] || null;
    };

    // Resolve a board device to a status state given the feed map. `key` is the
    // device's IP-Address (or a Monitor ID override). Returns a state string.
    StatusFeed.stateFor = function (devicesByIp, key) {
        var e = StatusFeed.entryFor(devicesByIp, key);
        return e ? (e.state || 'unknown') : 'unmonitored';
    };

    StatusFeed.STATE_COLORS = STATE_COLORS;
    global.StatusFeed = StatusFeed;
})(typeof window !== 'undefined' ? window : this);
