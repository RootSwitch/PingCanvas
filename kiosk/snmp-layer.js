/*
 * snmp-layer.js - optional SNMP metric overlay for the PingCanvas kiosk.
 *
 * Inert unless the kiosk URL carries ?snmp=<file>. Reads a snmp-status.json
 * (SNMPCanvas, schemaVersion 2): { interfaces: [ { id, code, operStatus, inBps,
 * outBps, ... } ], metrics: [ { code, kind, display, status?, ... } ] } and
 * overlays live values onto the board BY CODE. Two placement surfaces:
 *
 *   - CONNECTION annotation whose text is an interface id/code -> live link
 *     bandwidth readout + up/down recolor (down=red, near-cap/errors=amber).
 *     Two looks: the default high-contrast overlay chip, or ?annstyle=native,
 *     which patches the annotation's own text in place - keeping the
 *     operator's font, colors, and theme background - and refits its bg rect
 *     to the live value.
 *   - LABEL LINE containing a {code} token -> the token is replaced by that
 *     code's display string (e.g. "CPU: {C1}" -> "CPU: 45%"). Binds device
 *     labels, TEXT BOXES and ZONE LABELS alike; bold/italic/per-run colors on
 *     the line survive the swap. A {code} that matches nothing is left
 *     literal, so typos stay visible. A cpu metric with status warn/crit also
 *     tints its device's frame (amber/red - device labels only).
 *
 * Display-only, kiosk-owned: link pills live in #status-overlay; label swaps and
 * the frame tint mutate the rendered DOM in place (the kiosk loads the board once
 * and never re-renders, so the patch persists). The board MODEL (state) is never
 * touched, and the renderer is reached only through the DOM + CrossCanvas.svg(),
 * so no CrossCanvas change is needed and this flows in via sync with no porting.
 */
(function (global) {
    'use strict';

    var SVGNS = 'http://www.w3.org/2000/svg';
    var COLORS = global.StatusFeed ? global.StatusFeed.STATE_COLORS : {};
    var UTIL_WARN = 0.8;   // >= 80% of line rate reads as amber

    var annBindings = [];    // link annotations: { key, path, origStroke, origTexts, origBg, cx, cy, pill, matched }
    var labelBindings = [];  // label lines (device/text box/zone): { textEl, line, template, codes:[] }
    var deviceFrames = {};   // deviceId -> { el, orig, codes:[] }  (for the CPU tint)
    var annStyle = 'chip';   // 'chip' (overlay pill) | 'native' (patch the annotation in place)
    var overlay = null;
    var feed = null;
    var lastDoc = null, lastMeta = null;
    var rebinding = false;      // re-entry guard: rescan() repaints via applyStatus

    // bits/s -> "5.6M" (K/M/G/T, decimal - network convention). null -> "--".
    function fmtBps(b) {
        if (b == null) { return '--'; }
        var u = ['', 'K', 'M', 'G', 'T'], i = 0;
        while (b >= 1000 && i < u.length - 1) { b /= 1000; i++; }
        return (b < 10 ? b.toFixed(1) : String(Math.round(b))) + u[i];
    }

    // Amber when near line rate OR any error/discard is currently non-zero.
    function isDegraded(f) {
        if (f.speedBps > 0) {
            var mx = Math.max(f.inBps || 0, f.outBps || 0);
            if (mx / f.speedBps >= UTIL_WARN) { return true; }
        }
        return (f.inErrorsPerSec > 0) || (f.outErrorsPerSec > 0) ||
               (f.inDiscardsPerSec > 0) || (f.outDiscardsPerSec > 0);
    }

    // One lookup over EVERY match key: interface id, interface code, metric code.
    // (SNMPCanvas guarantees these are globally unique.) Each entry carries the
    // display string; interfaces also carry the raw object for link coloring.
    function buildIndex(doc) {
        // Prototype-free: a plain {} would resolve {toString}, {constructor},
        // {__proto__} etc. to inherited members, so those tokens rendered
        // "undefined" instead of staying literal like every other unknown code.
        var idx = Object.create(null), i;
        var ifaces = (doc && doc.interfaces) || [];
        for (i = 0; i < ifaces.length; i++) {
            var it = ifaces[i];
            var disp = (it.display != null && it.display !== '') ? it.display
                     : ('▼' + fmtBps(it.inBps) + '  ▲' + fmtBps(it.outBps));
            var e = { display: disp, iface: it };
            if (it.id != null && it.id !== '') { idx[it.id] = e; }   // '' would catch a "{ }" token
            if (it.code != null && it.code !== '') { idx[it.code] = e; }
            // Also match "Device:alias" (the friendly interface name, e.g.
            // "EdgeSw-01:Uplink-1"). The exporter's `id` is "Device:ifName"
            // (the raw SNMP name like "GigabitEthernet0/1"), so without this an
            // annotation written against the readable alias never binds - the
            // exact drift the samples used to hide. `id` still wins on a clash
            // (registered first, not overwritten).
            if (it.alias && it.device && it.device.name) {
                var aliasKey = it.device.name + ':' + it.alias;
                if (idx[aliasKey] === undefined) { idx[aliasKey] = e; }
            }
        }
        var mets = (doc && doc.metrics) || [];
        for (i = 0; i < mets.length; i++) {
            var m = mets[i];
            if (m.code != null && m.code !== '') {
                idx[m.code] = { display: (m.display != null ? m.display : '--'),
                                status: m.status, kind: m.kind };
            }
        }
        return idx;
    }

    function extractCodes(str) {                 // fresh regex each call (no shared /g state)
        var out = [], re = /\{([^{}]+)\}/g, m;
        while ((m = re.exec(str))) { out.push(m[1].trim()); }
        return out;
    }
    function replaceTokens(str, idx) {
        return str.replace(/\{([^{}]+)\}/g, function (whole, code) {
            var e = idx[code.trim()];
            return e ? e.display : whole;        // unmatched token stays literal
        });
    }

    // Capture one <text> line so tokens can be swapped in place and the
    // original restored later. Bold/italic/per-run colors live on child
    // tspans, so segs records each run's template; segs stays null (flat
    // mode) when the line has no tspans or a token is split across
    // differently-styled runs (whole-line swap is the only correct move then).
    function captureLine(t) {
        var raw = t.textContent || '';
        var codes = extractCodes(raw);
        var segs = null;
        var spans = t.querySelectorAll('tspan');
        if (spans.length) {
            var whole = 0;
            segs = [];
            for (var s = 0; s < spans.length; s++) {
                var st = spans[s].textContent || '';
                whole += extractCodes(st).length;
                segs.push({ node: spans[s], template: st });
            }
            if (whole !== codes.length) { segs = null; }
        }
        return { el: t, template: raw, codes: codes, segs: segs };
    }
    function paintLine(line, idx) {
        if (line.segs) {
            for (var s = 0; s < line.segs.length; s++) {
                line.segs[s].node.textContent = replaceTokens(line.segs[s].template, idx);
            }
        } else {
            line.el.textContent = replaceTokens(line.template, idx);
        }
    }
    function restoreLine(line) {
        if (line.segs) {
            for (var s = 0; s < line.segs.length; s++) { line.segs[s].node.textContent = line.segs[s].template; }
        } else {
            line.el.textContent = line.template;
        }
    }

    // --- link annotations (unchanged binding scan) ---
    function scanAnnotations() {
        var svg = global.CrossCanvas.svg();
        overlay = document.getElementById('status-overlay');
        if (!svg || !overlay) { return; }
        var seen = {};
        var texts = svg.querySelectorAll('text.connection-annotation');
        for (var i = 0; i < texts.length; i++) {
            var t = texts[i];
            var g = t.parentNode;                  // <g id="conn.id">
            if (!g || !g.id) { continue; }
            var annId = t.getAttribute('data-ann-id');
            var dedupe = g.id + '|' + annId;
            if (seen[dedupe]) { continue; }
            seen[dedupe] = true;
            var path = g.querySelector('path.connection-line');
            if (!path) { continue; }
            // An annotation renders one <text> per LINE, all sharing the ann
            // id, and every line gets hidden behind the pill - so the key must
            // be built from all of them. Reading only the first line meant
            // "{K7Q2}\nCore Uplink" silently dropped "Core Uplink", and
            // "Core Uplink\n{K7Q2}" never bound at all.
            var lineEls = g.querySelectorAll('text.connection-annotation[data-ann-id="' + annId + '"]');
            var raw = Array.prototype.map.call(lineEls, function (el) {
                return (el.textContent || '').trim();
            }).filter(Boolean).join(' ').trim();
            if (!raw) { continue; }
            // Two ways to write an annotation, so ONE copy-pasteable format
            // works everywhere: bare (`Xa3`, the whole label is the code) or
            // braced (`{Xa3}`, `Rx {Xa3}`), matching device labels. A generator
            // UI can therefore offer `{CODE}` for every value and the operator
            // pastes it onto either surface without editing it.
            var codes = raw.indexOf('{') >= 0 ? extractCodes(raw) : [];
            var box;
            try { box = t.getBBox(); } catch (e) { continue; }
            var origBg = g.querySelector('rect.connection-annotation-bg[data-ann-id="' + annId + '"]');
            annBindings.push({
                key: codes.length ? codes[0] : raw,   // bare form matches as before
                codes: codes,                          // braced form: resolve any of these
                template: codes.length ? raw : null,   // ...and keep the operator's own text
                path: path, origStroke: path.getAttribute('stroke'),
                origTexts: lineEls,
                // native mode: per-line capture (templates + styled runs) so the
                // annotation's own text can be patched in place and restored.
                lines: Array.prototype.map.call(lineEls, captureLine),
                origBg: origBg,
                origBgBox: origBg ? { x: origBg.getAttribute('x'), width: origBg.getAttribute('width') } : null,
                cx: box.x + box.width / 2, cy: box.y + box.height,
                pill: null, matched: false
            });
        }
    }

    // --- label text: any line with a {code} token binds. Three surfaces share
    // the pipeline: device labels, text boxes, and zone labels (all render a
    // <text> per line, direct child of their group).
    //
    // Styling: bold/italic/per-run colors live on child <tspan>s; font family,
    // size and the line's base fill live on the <text> itself. Replacing via
    // textContent would flatten the tspans away (bolded codes lost their bold),
    // so tokens are swapped inside each tspan and the run structure survives.
    // Only when a single token is SPLIT across differently-styled runs (braces
    // half-bolded) does that line fall back to the flat swap.
    function bindLabelText(t) {
        var raw = t.textContent || '';
        if (raw.indexOf('{') < 0) { return null; }       // only tokenized lines bind
        var line = captureLine(t);
        if (!line.codes.length) { return null; }
        return { textEl: t, line: line, template: line.template, codes: line.codes };
    }

    function scanLabels() {
        var svg = global.CrossCanvas.svg();
        if (!svg) { return; }
        var texts = svg.querySelectorAll('g.device-node > text, g.textbox-node > text, g.zone-node > text');
        for (var i = 0; i < texts.length; i++) {
            var t = texts[i];
            var b = bindLabelText(t);
            if (!b) { continue; }
            labelBindings.push(b);
            // CPU frame tint wiring is device-only by construction: text boxes
            // and zones have no rect.device-border, so the guard skips them.
            var did = t.parentNode.id;
            if (did && !deviceFrames[did]) {
                var border = t.parentNode.querySelector('rect.device-border');
                if (border) { deviceFrames[did] = { el: border, orig: border.getAttribute('stroke'), codes: [] }; }
            }
            if (deviceFrames[did]) {
                for (var c = 0; c < b.codes.length; c++) { deviceFrames[did].codes.push(b.codes[c]); }
            }
        }
    }

    function makePill(cx, cy) {
        var g = document.createElementNS(SVGNS, 'g');
        g.setAttribute('class', 'snmp-pill');
        var rect = document.createElementNS(SVGNS, 'rect');
        rect.setAttribute('class', 'snmp-pill-bg');
        rect.setAttribute('rx', 3);
        var text = document.createElementNS(SVGNS, 'text');
        text.setAttribute('class', 'snmp-pill-text');
        text.setAttribute('x', cx);
        text.setAttribute('y', cy);
        text.setAttribute('text-anchor', 'middle');
        g.appendChild(rect);
        g.appendChild(text);
        overlay.appendChild(g);
        return { g: g, rect: rect, text: text };
    }

    function sizePill(p) {
        var bb = p.text.getBBox(), pad = 4;
        p.rect.setAttribute('x', bb.x - pad);
        p.rect.setAttribute('y', bb.y - pad);
        p.rect.setAttribute('width', bb.width + pad * 2);
        p.rect.setAttribute('height', bb.height + pad * 2);
    }

    function showOriginal(b, show) {
        var d = show ? '' : 'none';
        for (var i = 0; i < b.origTexts.length; i++) { b.origTexts[i].style.display = d; }
        if (b.origBg) { b.origBg.style.display = d; }
    }

    function paintLink(b, color, down, dim) {
        b.path.setAttribute('stroke', color);
        b.path.classList.toggle('snmp-down', !!down);
        b.path.style.opacity = dim ? '0.5' : '';
    }

    // --- native annotation mode: patch the operator's own annotation text in
    // place (keeping their font, colors, and theme background) instead of
    // hiding it behind the overlay chip. The bg rect was sized for the
    // design-time text, so refit it to the live text; padding matches the
    // editor's (3px).
    function paintNative(b, idx, e, stale) {
        var i;
        if (b.template) {                              // braced: swap tokens per line
            for (i = 0; i < b.lines.length; i++) { paintLine(b.lines[i], idx); }
        } else if (b.lines.length) {                   // bare: the whole label IS the code
            b.lines[0].el.textContent = e.display;
        }
        for (i = 0; i < b.origTexts.length; i++) {
            b.origTexts[i].classList.toggle('snmp-native-stale', !!stale);
        }
        if (b.origBg) {
            var x0 = Infinity, x1 = -Infinity;
            for (i = 0; i < b.origTexts.length; i++) {
                try {
                    var bb = b.origTexts[i].getBBox();
                    if (bb.width > 0) { x0 = Math.min(x0, bb.x); x1 = Math.max(x1, bb.x + bb.width); }
                } catch (err) { /* detached mid-rescan: next poll refits */ }
            }
            if (x1 > x0) {
                b.origBg.setAttribute('x', x0 - 3);
                b.origBg.setAttribute('width', (x1 - x0) + 6);
            }
        }
    }
    function restoreNative(b) {
        for (var i = 0; i < b.lines.length; i++) { restoreLine(b.lines[i]); }
        for (i = 0; i < b.origTexts.length; i++) { b.origTexts[i].classList.remove('snmp-native-stale'); }
        if (b.origBg && b.origBgBox) {
            b.origBg.setAttribute('x', b.origBgBox.x);
            b.origBg.setAttribute('width', b.origBgBox.width);
        }
    }

    // Have our cached nodes been replaced under us? One probe per binding kind
    // covers the three layers a re-render can rebuild independently.
    function bindingsStale() {
        if (labelBindings.length && !document.contains(labelBindings[0].textEl)) { return true; }
        if (annBindings.length && !document.contains(annBindings[0].path)) { return true; }
        var ids = Object.keys(deviceFrames);
        if (ids.length && !document.contains(deviceFrames[ids[0]].el)) { return true; }
        return false;
    }

    // onStatus(doc, meta): the whole snmp-status.json + staleness meta.
    function applyStatus(doc, meta) {
        lastDoc = doc; lastMeta = meta;      // kept so rescan() can repaint at once
        // Self-heal. Anything that re-renders a board layer detaches the nodes
        // this layer patched, and the failure is SILENT: the pills keep
        // updating from their own overlay while link coloring, the CPU tint and
        // label swaps quietly stop - a down link would show healthy live
        // numbers on a normal-colored line. Both known triggers are closed
        // (the kiosk swallows keys, and it re-scans after its own recolor), so
        // this is the net for a future one. One document.contains per poll.
        if (!rebinding && bindingsStale()) { rescan(); return; }   // rescan repaints
        var idx = buildIndex(doc);

        // Links: bandwidth pill + up/down recolor (interface entries only).
        annBindings.forEach(function (b) {
            // Braced form: the first code that resolves drives the link color,
            // so `Rx {Xa3}` colors from Xa3 and a partly-unknown template still
            // shows what it can (unknown tokens stay literal, like labels).
            var e = null;
            if (b.codes && b.codes.length) {
                for (var ci = 0; ci < b.codes.length && !e; ci++) { e = idx[b.codes[ci]] || null; }
            } else {
                e = idx[b.key];
            }
            if (!e) {
                if (b.matched) {
                    if (annStyle === 'native') { restoreNative(b); }
                    else { showOriginal(b, true); if (b.pill) { b.pill.g.style.display = 'none'; } }
                    paintLink(b, b.origStroke, false, false);
                }
                b.matched = false;
                return;
            }
            b.matched = true;
            var f = e.iface;
            if (f) {
                var down = f.operStatus === 'down';
                var unknown = f.operStatus === 'unknown' || f.operStatus == null;
                var noData = f.inBps == null && f.outBps == null;
                if (down) { paintLink(b, COLORS.down, true, false); }
                else if (unknown || noData) { paintLink(b, COLORS.unknown, false, true); }
                else if (isDegraded(f)) { paintLink(b, COLORS.degraded, false, false); }
                else { paintLink(b, b.origStroke, false, false); }
            } else {
                paintLink(b, b.origStroke, false, false);   // a metric pinned to a link: show value, don't recolor
            }
            if (annStyle === 'native') {
                paintNative(b, idx, e, meta.stale);
                return;
            }
            showOriginal(b, false);
            if (!b.pill) { b.pill = makePill(b.cx, b.cy); }
            b.pill.text.textContent = b.template ? replaceTokens(b.template, idx) : e.display;
            b.pill.g.style.display = '';
            b.pill.g.classList.toggle('stale', !!meta.stale);
            sizePill(b.pill);
        });

        // Labels (device / text box / zone): swap {code} tokens for their live
        // display strings. Per-tspan when possible so bold/italic/run colors
        // survive; the flat path handles tokenless-tspan lines and split tokens.
        labelBindings.forEach(function (lb) { paintLine(lb.line, idx); });

        // CPU frame tint: a device whose label binds a cpu metric with a
        // warn/crit status gets its frame stroked amber/red (worst wins).
        Object.keys(deviceFrames).forEach(function (did) {
            var fr = deviceFrames[did], worst = 0;
            fr.codes.forEach(function (code) {
                var e = idx[code];
                if (e && e.kind === 'cpu' && e.status) {
                    var r = e.status === 'crit' ? 3 : (e.status === 'warn' ? 2 : 0);
                    if (r > worst) { worst = r; }
                }
            });
            fr.el.setAttribute('stroke', worst === 3 ? COLORS.down : (worst === 2 ? COLORS.degraded : fr.orig));
        });
    }

    // onStale(info|null): fetch failure (onStatus did not fire). Gray link
    // pills and drop any CPU alert tint - a stale reading must not keep a
    // device frame amber/red on old data.
    function applyStale(info) {
        annBindings.forEach(function (b) {
            if (!b.matched) { return; }
            if (annStyle === 'native') {
                for (var i = 0; i < b.origTexts.length; i++) {
                    b.origTexts[i].classList.toggle('snmp-native-stale', !!info);
                }
            } else if (b.pill) {
                b.pill.g.classList.toggle('stale', !!info);
            } else { return; }
            if (info) { b.path.style.opacity = '0.5'; }
        });
        if (info) {
            Object.keys(deviceFrames).forEach(function (did) {
                deviceFrames[did].el.setAttribute('stroke', deviceFrames[did].orig);
            });
        }
    }

    function init(opts) {
        opts = opts || {};
        if (!global.CrossCanvas || !global.StatusFeed) { return; }
        COLORS = global.StatusFeed.STATE_COLORS;
        annStyle = opts.annStyle === 'native' ? 'native' : 'chip';
        scanAnnotations();
        scanLabels();
        if (!annBindings.length && !labelBindings.length) { return; }   // nothing bound: stay inert
        feed = new global.StatusFeed({
            url: opts.snmpUrl,
            interval: opts.interval,
            staleMul: opts.staleMul,
            onStatus: applyStatus,
            onStale: applyStale
        });
        feed.start();
    }

    // Re-bind after the board's DOM was replaced under us.
    //
    // Anything that re-renders a layer (the kiosk's optional recolor-to-theme)
    // destroys the elements this layer patched in place and leaves every cached
    // reference pointing at detached nodes - labels would freeze on their last
    // value and links would stop recoloring, silently. Callers MUST call this
    // afterwards. Bindings are rebuilt from the fresh DOM and the last feed
    // reading is repainted immediately, so nothing waits for the next poll.
    function rescan() {
        if (rebinding) { return; }                                      // already re-binding
        if (!annBindings.length && !labelBindings.length) { return; }   // never initialised
        rebinding = true;
        try {
            annBindings.forEach(function (b) {                          // drop the old pills
                if (b.pill && b.pill.g.parentNode) { b.pill.g.parentNode.removeChild(b.pill.g); }
            });
            annBindings = [];
            labelBindings = [];
            deviceFrames = {};
            scanAnnotations();
            scanLabels();
            if (lastDoc) { applyStatus(lastDoc, lastMeta || {}); }
        } finally { rebinding = false; }
    }

    global.SnmpLayer = { init: init, rescan: rescan };
})(typeof window !== 'undefined' ? window : this);
