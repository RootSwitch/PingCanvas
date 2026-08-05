/*
 * kiosk-init.js - boots the PingCanvas kiosk.
 *
 * Runs after CrossCanvas's app.js (loaded with window.CROSSCANVAS_EMBED = true, so the
 * editor never prompts, never autosaves, never warns on unload). This file is
 * the ONLY glue between the synced renderer and the status feed:
 *
 *   1. read URL params (?board=…&status=…&interval=…&staleMul=…)
 *   2. fetch the .xcanvas board once -> window.CrossCanvas.load() -> fitToView()
 *   3. draw one status ring per device (own SVG group - never touches the model)
 *   4. wire StatusFeed: recolor rings, roll up zones, update HUD, stale banner
 *
 * Everything here reads CrossCanvas only through the tiny window.CrossCanvas hook, so
 * renderer updates flow in via tools/sync-from-crosscanvas.ps1 with no porting.
 */
(function () {
    'use strict';

    var params = new URLSearchParams(location.search);
    var explicitBoard = params.get('board');
    var explicitStatus = params.get('status');
    var explicitSnmp = params.get('snmp');
    var boardUrl = explicitBoard || 'board.xcanvas';
    // An un-parameterized kiosk searches the layouts this app actually ships
    // in, in order:
    //   board.xcanvas       standalone - the board sits beside kiosk.html
    //   data/board.xcanvas  suite install - nginx serves the shared data root
    //                       at /data/, and both the setup script and the
    //                       LaunchCanvas tile put boards there
    //   board.netdraw       pre-rename standalone data folders
    // Without the middle one, typing a bare kiosk.html on a suite install
    // showed the starter board's "place a board here" guidance while a real
    // board sat one directory away - accurate from the file's point of view,
    // and thoroughly confusing from the operator's. An explicit ?board= is
    // still never second-guessed.
    var boardFallbacks = explicitBoard ? [] : ['data/board.xcanvas', 'board.netdraw'];
    var statusUrl = explicitStatus || 'status.json';
    var snmpUrl = explicitSnmp;                       // may be derived once the board is found

    // 'data/board.xcanvas' -> 'data/'   |   'board.xcanvas' -> ''
    function dirOf(u) { var i = String(u).lastIndexOf('/'); return i < 0 ? '' : String(u).slice(0, i + 1); }
    // Numeric params are parsed defensively: a wall URL is typed by hand, often
    // once, and then runs for months. A junk value must degrade to the default,
    // never to NaN - `?margin=abc` used to reach fitToView(NaN) and render the
    // whole board to a "NaN NaN NaN NaN" viewBox, i.e. a blank wall, and a junk
    // shiftInterval became setInterval(fn, NaN), which fires every ~4ms.
    // min/max also clamp nonsense like a negative or zero interval.
    function numParam(name, def, min, max) {
        var raw = params.get(name);
        if (raw === null || raw === '') { return def; }
        var v = parseFloat(raw);
        if (!isFinite(v)) { return def; }
        if (min != null && v < min) { v = min; }
        if (max != null && v > max) { v = max; }
        return v;
    }

    var snmpInterval = numParam('snmpInterval', null, 1);
    var interval = numParam('interval', null, 1);
    var staleMul = numParam('staleMul', 2, 0.1);
    var boardWatch = numParam('boardwatch', 30, 0, 3600);   // 0 = never re-check the board
    var margin = numParam('margin', 60, 0, 5000);
    var showGrid = params.get('grid') === '1';        // grid OFF by default in kiosk
    var bgColor = params.get('bg');                   // e.g. ?bg=%23111827 (dark) or ?bg=white
    var showLatency = params.get('latency') !== '0';  // response-time labels ON by default
    var themeParam = params.get('theme');             // one theme, e.g. ?theme=blueprint
    var themesParam = params.get('themes');           // rotate: csv, a group name, or 'all'
    var themeIntervalSec = numParam('themeInterval', 900, 5);
    // ?themeOrder=shuffle - rotate in random order instead of list order. The
    // themes() roster is grouped Paper-first, so a list-order ?themes=all wall
    // spends its first hours in muted parchments before any Night theme
    // appears; shuffle mixes the groups from the first interval.
    var themeShuffle = (params.get('themeOrder') || '').toLowerCase() === 'shuffle';
    // ?themeName=1 - show the current theme's name in the HUD, swatched in the
    // theme's own accent. Off by default: a wall for visitors should not
    // explain itself, but the wall you tune themes ON wants the name visible.
    var showThemeName = params.get('themeName') === '1';
    var themeBg = params.get('themeBg') !== '0';      // theme picks the canvas color (ON)
    // ?themeRecolor=1|all           restyle every kind
    // ?themeRecolor=devices,zones   restyle only these (the rest keep their colors)
    // A board whose KEY encodes meaning in connection/text-box colors wants
    // exactly that exclusion - recoloring those kinds silently invalidates the
    // legend, which is the main way this feature can mislead rather than fail.
    var RECOLOR_KINDS = ['devices', 'zones', 'connections', 'textBoxes'];
    var themeRecolorOpts = (function () {
        var raw = (params.get('themeRecolor') || '').trim();
        if (!raw || raw === '0') { return null; }                  // off
        if (raw === '1' || raw.toLowerCase() === 'all') { return {}; }   // all kinds (opts default true)
        var want = raw.toLowerCase().split(',').map(function (s) { return s.trim(); });
        var opts = {}, any = false;
        RECOLOR_KINDS.forEach(function (k) {
            var on = want.indexOf(k.toLowerCase()) >= 0;
            opts[k] = on;
            if (on) { any = true; }
        });
        return any ? opts : null;      // no recognised kind named = treat as off
    })();
    var shiftPx = numParam('shift', 0, 0, 200);           // 0 = off
    var shiftIntervalSec = numParam('shiftInterval', 300, 30);

    document.body.classList.add('kiosk');

    // --- Keyboard: the board is inert, so no key may reach the editor -------
    // kiosk.css makes the canvas pointer-events:none, but KEY events still
    // reach the editor's document-level handler, which is fully live: Escape
    // deselects (re-rendering the connection and device layers), arrow keys
    // nudge objects, Ctrl+D duplicates, Ctrl+O opens a file dialog.
    //
    // Escape was the one that bit in practice - pressed reflexively to leave
    // F11 fullscreen, it re-rendered the layers and so restored the annotation
    // texts the SNMP overlay had hidden (they reappear under the pills), while
    // silently detaching that overlay's cached path/label nodes, which stops
    // link recoloring and the CPU frame tint without any visible error.
    //
    // Capture on window fires before the editor's document-level listeners, so
    // stopping propagation there neutralises all of them. Deliberately NOT
    // preventDefault: browser-level keys (F11, F5, Ctrl+W) must keep working,
    // and those are handled by the browser rather than by a page listener.
    ['keydown', 'keyup', 'keypress'].forEach(function (evt) {
        window.addEventListener(evt, function (e) { e.stopPropagation(); }, true);
    });

    // --- Theme rotation ----------------------------------------------------
    // A wall display sits on one image for months, so even an IPS panel can
    // retain it. Rotating the theme repaints the largest, most-constant area
    // (the canvas background plus the chrome) on a timer, which spreads the
    // load per pixel for free. Devices/zones/connections deliberately keep
    // their own colors: on a MONITORING wall those encode status, so rotating
    // them would fight that encoding - and it would need a layer re-render,
    // which wipes the SNMP overlay's in-place DOM patches.
    //
    //   ?theme=blueprint                    one theme, no rotation
    //   ?themes=night&themeInterval=600     rotate a group every 10 min
    //   ?themes=ink,blueprint,garnet        rotate an explicit list
    //   ?themes=all                         rotate every theme
    //   ?themeBg=0                          keep the board's own background
    var themeRotation = [], themeIdx = 0;

    function resolveThemes(spec) {
        if (!spec || !window.CrossCanvas || !window.CrossCanvas.themes) { return []; }
        var all = window.CrossCanvas.themes();      // [] on an older synced app.js
        if (spec.toLowerCase() === 'all') { return all; }
        // Each csv item is a group name ('night') OR a theme id ('ink'), so a
        // mixed list like `night,ink` works - matching a group only when the
        // WHOLE spec was a group name meant `?themes=night,ink` silently
        // collapsed to one theme and never rotated. Unknown names are dropped,
        // not fatal; duplicates are removed so a ring never repeats a theme.
        var out = [], seen = {};
        spec.split(',').forEach(function (s) {
            var want = s.trim().toLowerCase();
            if (!want) { return; }
            all.forEach(function (t) {
                if (t.group.toLowerCase() !== want && t.id.toLowerCase() !== want) { return; }
                if (seen[t.id]) { return; }
                seen[t.id] = true;
                out.push(t);
            });
        });
        return out;
    }

    // Set the canvas background AND keep the board's labels legible on it.
    // Resolve any CSS color (hex or name) to [r,g,b] via the browser. Cached:
    // the contrast pass asks for the same handful of zone fills repeatedly.
    var rgbCache = {};
    function toRGB(color) {
        if (rgbCache[color] !== undefined) { return rgbCache[color]; }
        var probe = document.createElement('span');
        probe.style.color = color;
        // CSSOM silently REJECTS an invalid value, leaving the property empty -
        // without this check getComputedStyle returns the INHERITED color
        // (black) and a typo like ?bg=drakblue reads as a pitch-dark canvas,
        // which flips every label to light text on a still-white board: the
        // whole wall goes blank with no error anywhere.
        if (probe.style.color === '') { rgbCache[color] = null; return null; }
        document.body.appendChild(probe);
        // Decimals matter: rgba() alpha is 0.5, not 5.
        var parts = (getComputedStyle(probe).color.match(/[\d.]+/g) || []).map(Number);
        probe.remove();
        rgbCache[color] = parts.length >= 3 ? parts : null;   // [r,g,b] or [r,g,b,a]
        return rgbCache[color];
    }
    // Perceived brightness, ITU-R BT.601, 0..255. Under 140 reads as "dark"
    // (the same threshold CrossCanvas's own surfaceIsDarkAt uses).
    function brightness(rgb) { return 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]; }

    var canvasRGB = null;

    function setCanvasBg(color) {
        var cbg = document.getElementById('canvas-bg');
        if (!cbg) { return; }
        var rgb = toRGB(color);
        if (!rgb) { return; }        // unusable color: leave the board untouched
        cbg.setAttribute('fill', color);
        canvasRGB = rgb;
        // The theme's own light-on-dark text color when it has one
        // (--se-dk-txt on light-chrome themes, --se-txt on dark-chrome ones).
        var st = document.documentElement.style;
        var txt = (st.getPropertyValue('--se-dk-txt') || st.getPropertyValue('--se-txt') || '').trim();
        st.setProperty('--pc-board-text', txt || '#e8e8e8');
        applyLabelContrast();
    }

    // Keep board label text legible against whatever is UNDER it.
    //
    // Boards are authored on a white canvas and carry fill="#333" text, so a
    // dark canvas hides it. But recoloring every label globally is wrong: a
    // light zone sitting on a dark canvas is still a light surface, and light
    // text on it disappears just as badly (the shipped starter board does
    // exactly this). So decide PER LABEL, compositing zone fills over the
    // canvas the way CrossCanvas's own surfaceIsDarkAt does.
    //
    // Tagging elements with a class (rather than re-rendering) is deliberate:
    // a CSS rule outranks the fill presentation attribute, and re-rendering a
    // layer would wipe the SNMP overlay's in-place label swaps and tints.
    function applyLabelContrast() {
        if (!canvasRGB || !window.CrossCanvas || !window.CrossCanvas.svg) { return; }
        var svg = window.CrossCanvas.svg();
        var ctm = svg.getScreenCTM();
        if (!ctm) { return; }
        var inv = ctm.inverse();
        var zones = window.CrossCanvas.zones ? window.CrossCanvas.zones() : [];
        var texts = svg.querySelectorAll(
            '#zones-layer text, #connections-layer text, #devices-layer text');
        for (var i = 0; i < texts.length; i++) {
            var el = texts[i];
            var box = el.getBoundingClientRect();
            if (!box.width && !box.height) { continue; }        // hidden (e.g. SNMP-swapped)
            // Screen -> canvas units, so this works at any zoom/viewBox.
            var pt = svg.createSVGPoint();
            pt.x = box.left + box.width / 2;
            pt.y = box.top + box.height / 2;
            pt = pt.matrixTransform(inv);
            // Composite every zone containing the point, in draw order.
            var r = canvasRGB[0], g = canvasRGB[1], b = canvasRGB[2];
            for (var z = 0; z < zones.length; z++) {
                var zn = zones[z];
                if (pt.x < zn.x || pt.x > zn.x + zn.w || pt.y < zn.y || pt.y > zn.y + zn.h) { continue; }
                var zf = toRGB(zn.fill || '#e8f4fd');
                if (!zf) { continue; }
                // Fold the FILL's own alpha into the zone opacity. Dropping it
                // made `transparent` (what the draw.io/Visio importers emit for
                // an unfilled shape) composite as opaque BLACK, which flipped
                // every label inside that zone to light text and hid it.
                var a = (zn.opacity != null ? zn.opacity : 1) * (zf.length > 3 ? zf[3] : 1);
                r = zf[0] * a + r * (1 - a);
                g = zf[1] * a + g * (1 - a);
                b = zf[2] * a + b * (1 - a);
            }
            el.classList.toggle('pc-on-dark', brightness([r, g, b]) < 140);
        }
    }

    function paintTheme(t) {
        window.CrossCanvas.theme(t.id);           // chrome vars only, never persisted
        // Opt-in: restyle the BOARD's own objects too (device tints, zone fills,
        // connection ink, label colors) - the editor's Recolor to Theme, run on
        // the in-memory copy only. Nothing is ever written back to the .xcanvas.
        //
        // Off by default because it is not universally safe: a board whose
        // colors carry MEANING (role, site, VLAN) loses that meaning, and on a
        // monitoring wall device colors can read as status. Opt in when the
        // board is decorative enough to survive it.
        if (themeRecolorOpts && window.CrossCanvas.recolor) {
            window.CrossCanvas.recolor(themeRecolorOpts);
            // The recolor re-rendered three layers, so everything patched into
            // the board's DOM is gone: re-bind the SNMP overlay (its cached
            // nodes are detached now) and re-tag label contrast. Status rings
            // live in the kiosk's own overlay group and are positioned from
            // model geometry, so they are unaffected.
            if (window.SnmpLayer && window.SnmpLayer.rescan) { window.SnmpLayer.rescan(); }
        }
        // An explicit ?bg= is the operator's own choice and always wins.
        if (themeBg && !bgColor && t.canvasDark) { setCanvasBg(t.canvasDark); }
        applyLabelContrast();   // also covers ?themeBg=0, where setCanvasBg never runs
        // ?themeName=1 chip. The kiosk page IS the CrossCanvas document, so
        // the applied theme's chrome vars are live on :root - the swatch is
        // painted with var(--se-accent) in CSS and follows every repaint with
        // no bookkeeping here; only the text needs setting.
        var chip = document.getElementById('kiosk-theme-name');
        if (chip) { chip.textContent = t.label; }
    }

    // Fisher-Yates, in place. Rotation order is presentation, not identity,
    // so shuffling the resolved list never affects which themes show - only
    // when.
    function shuffleThemes(list) {
        for (var i = list.length - 1; i > 0; i--) {
            var j = Math.floor(Math.random() * (i + 1));
            var tmp = list[i]; list[i] = list[j]; list[j] = tmp;
        }
    }

    function startThemes() {
        if (!window.CrossCanvas || !window.CrossCanvas.theme) { return; }   // older app.js: no-op
        themeRotation = resolveThemes(themesParam);
        if (!themeRotation.length) { themeRotation = resolveThemes(themeParam); }
        if (!themeRotation.length) { return; }
        if (themeShuffle) { shuffleThemes(themeRotation); }
        paintTheme(themeRotation[0]);
        if (themeRotation.length < 2 || !(themeIntervalSec > 0)) { return; }
        setInterval(function () {
            themeIdx = (themeIdx + 1) % themeRotation.length;
            // Reshuffle each time the ring wraps so the order stays fresh on a
            // wall that runs for weeks - guarding against the new first theme
            // repeating the one currently showing (a swap with a random other
            // slot, which preserves the shuffle's uniformity well enough for
            // wallpaper).
            if (themeShuffle && themeIdx === 0 && themeRotation.length > 2) {
                var last = themeRotation[themeRotation.length - 1];
                shuffleThemes(themeRotation);
                if (themeRotation[0].id === last.id) {
                    var k = 1 + Math.floor(Math.random() * (themeRotation.length - 1));
                    var tmp = themeRotation[0];
                    themeRotation[0] = themeRotation[k]; themeRotation[k] = tmp;
                }
            }
            paintTheme(themeRotation[themeIdx]);
        }, Math.max(5, themeIntervalSec) * 1000);
    }

    // --- Pixel orbit (burn-in) ---------------------------------------------
    // Theme rotation repaints the backdrop but never MOVES anything, and
    // burn-in tracks static high-contrast EDGES - zone borders, device
    // outlines - which is why a taskbar or snapped-window edge ghosts on a
    // panel long before its middle does. So nudge the whole diagram a few
    // pixels around a small ring on a slow timer; no edge sits on one line of
    // pixels for more than one interval.
    //
    //   ?shift=8&shiftInterval=300     8px ring, moving every 5 minutes
    //
    // Done by translating the viewBox rather than the SVG element: the
    // background and grid rects are re-anchored to the shifted window, so the
    // canvas stays full-bleed with no gap creeping in at an edge. It is a
    // single attribute write per step - deliberately not animated, since a
    // smooth tween would cost real CPU on a Pi for something meant to be
    // barely perceptible.
    var ORBIT = [[0, 0], [1, 0], [1, 1], [0, 1], [-1, 1], [-1, 0], [-1, -1], [0, -1], [1, -1]];
    var orbitIdx = 0, baseVB = null;

    function captureViewBase() {
        var svg = window.CrossCanvas.svg();
        var vb = (svg.getAttribute('viewBox') || '').split(/[\s,]+/).map(Number);
        baseVB = (vb.length === 4 && vb[2] > 0) ? vb : null;
    }

    function applyOrbit() {
        if (!baseVB || !(shiftPx > 0)) { return; }
        var container = document.getElementById('canvas-container');
        var vpW = container ? container.clientWidth : 0;
        if (!vpW) { return; }
        var unitsPerPx = baseVB[2] / vpW;          // viewBox units per screen pixel
        var p = ORBIT[orbitIdx % ORBIT.length];
        // Move the WINDOW the opposite way so the content appears to move +p.
        var x = baseVB[0] - p[0] * shiftPx * unitsPerPx;
        var y = baseVB[1] - p[1] * shiftPx * unitsPerPx;
        window.CrossCanvas.svg().setAttribute('viewBox',
            x + ' ' + y + ' ' + baseVB[2] + ' ' + baseVB[3]);
        ['canvas-bg', 'grid-overlay'].forEach(function (id) {
            var r = document.getElementById(id);
            if (r) { r.setAttribute('x', x); r.setAttribute('y', y); }
        });
        // The HUD and down-panel are static pixels too. The stale banner is
        // full-width, so shifting it would open a gap at one edge - left put.
        var t = 'translate(' + (p[0] * shiftPx) + 'px,' + (p[1] * shiftPx) + 'px)';
        ['kiosk-hud', 'kiosk-down'].forEach(function (id) {
            var e = document.getElementById(id);
            if (e) { e.style.transform = t; }
        });
    }

    function startOrbit() {
        if (!(shiftPx > 0)) { return; }
        // NB: never re-capture the base here - the current viewBox is already
        // shifted, so treating it as the base would make offsets accumulate
        // and walk the board off screen. The base is captured only right after
        // fitToView (load and resize), which always yields an unshifted box.
        setInterval(function () {
            orbitIdx++;
            applyOrbit();
        }, Math.max(30, shiftIntervalSec) * 1000);
    }

    // --- HUD + stale banner (fixed overlays, not part of the board) --------
    var banner = document.createElement('div');
    banner.id = 'stale-banner';
    document.body.appendChild(banner);

    var COLORS = window.StatusFeed.STATE_COLORS;
    var hud = document.createElement('div');
    hud.id = 'kiosk-hud';
    ['up', 'degraded', 'down', 'unmonitored'].forEach(function (s) {
        var item = document.createElement('span');
        item.className = 'legend-item';
        // The swatch is an OUTLINE, not a filled block, so it mirrors what is
        // actually on the board - a ring - and can carry the same dash pattern.
        // A legend that only varies by colour cannot be used by the people the
        // dash patterns are there for.
        item.innerHTML = '<span class="legend-swatch st-' + s + '" style="border-color:' + COLORS[s] +
            '"></span><span id="count-' + s + '">0</span>&nbsp;' + s;
        hud.appendChild(item);
    });
    var clock = document.createElement('span');
    clock.className = 'clock';
    clock.textContent = 'waiting for status…';
    hud.appendChild(clock);
    if (showThemeName) {
        // Same anatomy as a legend item so it reads as part of the HUD, but
        // the swatch is FILLED with the live theme accent (a status swatch is
        // an outline - the difference keeps it from reading as a fifth state).
        var themeItem = document.createElement('span');
        themeItem.className = 'legend-item theme-name-item';
        themeItem.innerHTML = '<span class="theme-name-swatch"></span>' +
            '<span id="kiosk-theme-name"></span>';
        hud.appendChild(themeItem);
    }
    document.body.appendChild(hud);

    // Down-device panel: bottom-right, same style as the HUD, grows upward,
    // shown only when something is down. Populated in applyStatus.
    var downPanel = document.createElement('div');
    downPanel.id = 'kiosk-down';
    document.body.appendChild(downPanel);
    var DOWN_LIST_CAP = 15;   // wall-safe: cap the list, summarize the rest

    function renderDownList(names) {
        downPanel.innerHTML = '';
        if (!names.length) { downPanel.classList.remove('show'); return; }
        names = names.slice().sort();
        var title = document.createElement('div');
        title.className = 'down-title';
        title.textContent = 'Down (' + names.length + ')';
        downPanel.appendChild(title);
        names.slice(0, DOWN_LIST_CAP).forEach(function (n) {
            var row = document.createElement('div');
            row.className = 'down-item';
            var lbl = document.createElement('span');
            lbl.textContent = n;                      // textContent: board labels are untrusted
            var dot = document.createElement('span');
            dot.className = 'down-dot';
            row.appendChild(lbl);
            row.appendChild(dot);
            downPanel.appendChild(row);
        });
        if (names.length > DOWN_LIST_CAP) {
            var more = document.createElement('div');
            more.className = 'down-more';
            more.textContent = '+ ' + (names.length - DOWN_LIST_CAP) + ' more';
            downPanel.appendChild(more);
        }
        downPanel.classList.add('show');
    }

    function fail(msg) {
        banner.textContent = msg;
        banner.classList.add('show');
    }

    if (!window.CrossCanvas) { fail('CrossCanvas embed hook missing - re-run tools/sync-from-crosscanvas.ps1'); return; }

    // --- status overlay --------------------------------------------------
    var SVGNS = 'http://www.w3.org/2000/svg';
    var deviceRings = [];   // { key, el }
    var zoneRings = [];     // { el, keys: [] }
    var lastGenerated = null;
    var isStale = false;

    function keyOf(dev) {
        var f = dev.fields || {};
        var k = f['Monitor ID'] || f['IP-Address'] || null;
        // Trim to match the poller, which trims Monitor ID / IP before keying
        // the status file - an untrimmed stray space here would never match.
        return k != null ? String(k).trim() || null : null;
    }

    function buildOverlay() {
        var svg = window.CrossCanvas.svg();
        var g = document.createElementNS(SVGNS, 'g');
        g.id = 'status-overlay';

        // Zone rings first (under device rings), one per zone that contains
        // monitored devices; shown only when the zone's worst state warrants
        // attention. Membership = device center inside the zone rect.
        window.CrossCanvas.zones().forEach(function (z) {
            var keys = [];
            window.CrossCanvas.devices().forEach(function (d) {
                var cx = d.x + d.w / 2, cy = d.y + d.h / 2;
                if (keyOf(d) && cx >= z.x && cx <= z.x + z.w && cy >= z.y && cy <= z.y + z.h) {
                    keys.push(keyOf(d));
                }
            });
            if (!keys.length) return;
            var r = document.createElementNS(SVGNS, 'rect');
            // zone-ring marks it as a ZONE outline, not a device: the red body
            // wash and pulse on st-down are scoped away from these, because
            // washing an entire zone red would drown the devices inside it.
            r.setAttribute('class', 'status-ring zone-ring');
            r.setAttribute('x', z.x - 6); r.setAttribute('y', z.y - 6);
            r.setAttribute('width', z.w + 12); r.setAttribute('height', z.h + 12);
            r.setAttribute('rx', 12);
            r.style.display = 'none';
            g.appendChild(r);
            zoneRings.push({ el: r, keys: keys });
        });

        window.CrossCanvas.devices().forEach(function (d) {
            // No IP-Address / Monitor ID = opted out of monitoring: no ring,
            // no legend count. The field that makes monitoring possible is the
            // field that declares intent - a UPS shown for its label stats, an
            // internet cloud, a decorative stencil just render as themselves.
            // (A device that HAS a key but is missing from the feed still gets
            // the solid gray "unmonitored" ring - that's real drift and stays
            // worth flagging.) On a wall of ringed devices, a ringless one is
            // its own at-a-glance answer.
            var key = keyOf(d);
            if (!key) { return; }
            var r = document.createElementNS(SVGNS, 'rect');
            r.setAttribute('class', 'status-ring');
            // Hug the device: labels sit right below the frame, so a wide ring
            // clips the label's first line. 3px offset + the 4px stroke = 5px
            // reach, which stays above the label text's ascent line.
            r.setAttribute('x', d.x - 3); r.setAttribute('y', d.y - 3);
            r.setAttribute('width', d.w + 6); r.setAttribute('height', d.h + 6);
            r.setAttribute('rx', 7);
            r.setAttribute('stroke', COLORS.unmonitored);
            g.appendChild(r);

            // Response-time label, drawn above the device (labels are usually
            // below); filled per-poll in applyStatus when the feed has latency.
            var lat = document.createElementNS(SVGNS, 'text');
            lat.setAttribute('class', 'status-latency');
            lat.setAttribute('x', d.x + d.w / 2);
            lat.setAttribute('y', d.y - 14);
            lat.setAttribute('text-anchor', 'middle');
            g.appendChild(lat);

            var name = (d.fields && d.fields.Hostname) ? d.fields.Hostname
                     : ((d.label || '').split('\n')[0] || key || 'device');
            deviceRings.push({ key: key, el: r, lat: lat, name: name });
        });

        svg.appendChild(g);
    }

    var RANK = { down: 3, degraded: 2, unknown: 1, up: 0, unmonitored: 0 };

    function applyStatus(doc, meta) {
        var devicesByIp = doc.devices || {};   // StatusFeed now hands over the whole doc
        lastGenerated = meta.generated;
        var counts = { up: 0, degraded: 0, down: 0, unknown: 0, unmonitored: 0 };
        var stateByKey = {};
        var downNames = [];

        deviceRings.forEach(function (ring) {
            var s = window.StatusFeed.stateFor(devicesByIp, ring.key);
            // A foreign/hand-edited feed can carry states we don't know
            // ("flapping", …) - fold them into unknown instead of painting
            // stroke="undefined" (invisible ring, dropped from every count).
            if (!COLORS[s]) { s = 'unknown'; }
            counts[s] = (counts[s] || 0) + 1;
            if (ring.key) { stateByKey[ring.key] = s; }
            if (s === 'down') { downNames.push(ring.name); }
            ring.el.setAttribute('stroke', COLORS[s]);
            // The st-<state> class carries a DASH PATTERN that says the same
            // thing the colour does. up and degraded used to differ by hue
            // alone (#2e9b57 vs #d9a406) - the classic red-green confusion
            // pair - so to a deuteranope a degrading device read as healthy,
            // the worst direction for that to fail. Patterns live in
            // kiosk.css; st-down additionally applies the translucent red body
            // wash, which must be CSS and not a fill attribute here (the
            // stylesheet's `fill: none` on .status-ring would override any
            // attribute value - CSS beats SVG presentation attributes).
            ring.el.setAttribute('class', 'status-ring st-' + s);
            if (ring.lat) {
                var e = window.StatusFeed.entryFor(devicesByIp, ring.key);
                ring.lat.textContent =
                    (showLatency && e && e.latencyMs != null) ? (e.latencyMs + ' ms') : '';
            }
        });
        renderDownList(downNames);

        zoneRings.forEach(function (zr) {
            var worst = 'up';
            zr.keys.forEach(function (k) {
                var s = stateByKey[k] || 'unknown';
                if (RANK[s] > RANK[worst]) { worst = s; }
            });
            var alert = worst === 'down' || worst === 'degraded';
            zr.el.style.display = alert ? '' : 'none';
            if (alert) {
                zr.el.setAttribute('stroke', COLORS[worst]);
                // Same dash encoding as devices, so a zone flagged for a
                // DEGRADED member is tellable from one flagged for a DOWN
                // member without reading the colour.
                zr.el.setAttribute('class', 'status-ring zone-ring st-' + worst);
            }
        });

        document.getElementById('count-up').textContent = counts.up;
        document.getElementById('count-degraded').textContent = counts.degraded;
        document.getElementById('count-down').textContent = counts.down;
        document.getElementById('count-unmonitored').textContent =
            counts.unmonitored + counts.unknown;

        document.getElementById('canvas').classList.toggle('stale', meta.stale);
    }

    function applyStale(info) {
        isStale = !!info;
        if (info) {
            if (info.reason === 'fetch') {
                banner.textContent = 'Stale - Status Feed Unreachable, Check Poller';
            } else if (info.reason === 'badtime' || !isFinite(info.ageSec)) {
                banner.textContent = 'Stale - Status Timestamp Invalid, Check Poller';
            } else {
                banner.textContent = 'Stale - Status Data is ' + Math.round(info.ageSec) + 's Old, Check Poller';
            }
        }
        banner.classList.toggle('show', isStale);
        clock.classList.toggle('stale', isStale);
        document.getElementById('canvas').classList.toggle('stale', isStale);
    }

    // "updated Ns ago" ticker, independent of the poll cadence.
    setInterval(function () {
        if (!lastGenerated) { return; }
        var t = Date.parse(lastGenerated);
        if (!isFinite(t)) { clock.textContent = 'status timestamp invalid'; return; }
        var age = Math.max(0, Math.round((Date.now() - t) / 1000));
        clock.textContent = 'updated ' + age + 's ago';
    }, 1000);

    // --- boot --------------------------------------------------------------
    // When the board is ABSENT (404), fall through to the starter board that
    // ships with the app: an unmonitored example plus place-your-board
    // instructions, so a fresh install shows guidance instead of an error.
    // That now includes an explicit ?board= that 404s - the suite's launcher
    // tile and setup script wire ?board=data/board.xcanvas from day one, so
    // a brand-new box hits that URL before any board has been uploaded. To
    // keep a production wall whose board file VANISHED from masquerading as
    // a fresh install, the ticker names the missing path in that case.
    //
    // ABSENT vs BROKEN still matters: only a 404 falls through. A board that
    // exists but fails (HTTP 5xx, invalid JSON from a truncated copy,
    // network error) must fail LOUDLY with its own name.
    var starterActive = false;
    var missingBoardPath = null;   // explicit ?board= that 404'd (absent, not broken)
    function fetchBoardJson(url) {
        return fetch(url, { cache: 'no-store' }).then(function (r) {
            if (!r.ok) {
                var e = new Error('HTTP ' + r.status);
                e.missing = (r.status === 404);
                throw e;
            }
            return r.json().then(null, function (pe) {
                throw new Error('not valid board JSON (' + pe.message + ')');
            });
        });
    }
    // --- board-change watcher ------------------------------------------------
    // The board is fetched ONCE, so a swap underneath a running wall leaves the
    // display frozen on the old one - and the poller re-reads the board every
    // cycle, so the two disagree immediately. That is worse than stale: a device
    // whose IP or Monitor ID changed keeps being probed under a NEW feed key
    // while its old element, bound to the old key, renders gray "unmonitored".
    // Red turning gray reads as "resolved" when it means "no longer watched".
    // Nobody is standing at a wall display to press F5, so the kiosk notices for
    // itself. Cheap: one HEAD per interval against a static file.
    //
    // The fingerprint is whatever the server will commit to - ETag, then
    // Last-Modified, then Content-Length. If it offers none of those the value
    // is a constant, so the wall never reloads rather than reloading forever on
    // a server that cannot answer the question.
    function boardFingerprint(url) {
        return fetch(url, { method: 'HEAD', cache: 'no-store' }).then(function (r) {
            if (!r.ok) { return null; }               // absent (404) is a state too
            return r.headers.get('etag')
                || r.headers.get('last-modified')
                || r.headers.get('content-length')
                || 'present';
        }).catch(function () { return undefined; });  // transient: undefined = "no opinion"
    }

    function watchBoard(url) {
        if (!boardWatch) { return; }
        var baseline;
        boardFingerprint(url).then(function (fp) {
            baseline = fp;
            setInterval(function () {
                boardFingerprint(url).then(function (fp2) {
                    // undefined means the check itself failed (a blip, or the web
                    // tier restarting). Only a real, different answer reloads -
                    // a wall that reloads on every network hiccup is worse than
                    // one that is briefly stale.
                    if (fp2 === undefined || fp2 === baseline) { return; }
                    baseline = fp2;
                    location.reload();
                });
            }, boardWatch * 1000);
        });
    }

    function starterOrDie() {
        return fetchBoardJson('starter-board.xcanvas').catch(function () {
            // Starter missing too (partial deploy): report the board
            // the operator needs to create, not our fallback file.
            throw new Error('not found - place a board file here (the bundled starter board is also missing from this deployment)');
        });
    }
    // Walk the remaining default locations. Only a 404 advances to the next:
    // anything else (5xx, truncated JSON) is LOUD and names the file it hit,
    // because a board that EXISTS but is broken must never masquerade as a
    // fresh install.
    function tryFallbacks(list) {
        if (!list.length) { starterActive = true; return starterOrDie(); }
        var next = list[0];
        return fetchBoardJson(next)
            .then(function (data) { boardUrl = next; return data; })
            .catch(function (err) {
                if (!err.missing) { boardUrl = next; throw err; }
                return tryFallbacks(list.slice(1));
            });
    }

    fetchBoardJson(boardUrl)
        .catch(function (err) {
            if (!err.missing) { throw err; }            // BROKEN: always loud
            if (explicitBoard) {
                // Explicit ?board= that is absent: starter guidance, but
                // remember the path so the ticker can name it.
                starterActive = true;
                missingBoardPath = boardUrl;
                return starterOrDie();
            }
            return tryFallbacks(boardFallbacks);
        })
        .then(function (data) {
            window.CrossCanvas.load(data);
            startThemes();
            // Tab title: show the board's name only when it carries one worth
            // showing. The defaults ('board' from board.xcanvas, CrossCanvas's
            // 'network-diagram') are the absence of a name, not a name - a
            // single-wall deploy reads "PingCanvas - Monitor" with zero setup,
            // while naming boards (the multi-board case) labels tabs for free.
            var t = (data.diagramTitle || '').trim();
            if (/^(board|network-diagram)$/i.test(t)) { t = ''; }
            document.title = 'PingCanvas - ' + (t || 'Monitor');
            window.CrossCanvas.fitToView(margin);
            // Grid off by default (?grid=1 to keep it); optional solid background.
            if (!showGrid) {
                var gr = document.getElementById('grid-overlay');
                if (gr) { gr.style.display = 'none'; }
            }
            if (bgColor && /^(#[0-9a-fA-F]{3,8}|[a-zA-Z]+)$/.test(bgColor)) {
                setCanvasBg(bgColor);
            }
            buildOverlay();
            captureViewBase();
            startOrbit();
            window.addEventListener('resize', function () {
                window.CrossCanvas.fitToView(margin);   // resets the viewBox...
                captureViewBase();                      // ...so re-base, then
                applyOrbit();                           // restore the offset
            });

            // The starter board monitors nothing - polling status.json would
            // only raise a misleading stale banner. Park the clock instead.
            if (starterActive) {
                document.title = 'PingCanvas - Get Started';
                clock.textContent = missingBoardPath
                    ? 'no board at ' + missingBoardPath + ' yet'
                    : 'starter board - nothing is monitored yet';
                // Watch the path the operator is going to fill, not the starter
                // we fell back to: this is the fresh-install case, where the
                // first upload should light the wall up without anyone walking
                // over to it.
                watchBoard(missingBoardPath || boardUrl);
                return;
            }

            // Where the board was FOUND tells us which layout this deployment
            // uses, so the sibling feeds default to that same directory rather
            // than to the web root. Without this, a suite install found its
            // board under /data/ and then read a status file that was never
            // there - a live-looking wall with every device permanently gray.
            // Explicit ?status= / ?snmp= always win.
            var feedDir = dirOf(boardUrl);
            if (!explicitStatus) { statusUrl = feedDir + 'status.json'; }
            if (!explicitSnmp) { snmpUrl = feedDir + 'snmp-status.json'; }

            var feed = new window.StatusFeed({
                url: statusUrl,
                interval: interval,
                staleMul: staleMul,
                onStatus: applyStatus,
                onStale: applyStale
            });
            feed.start();
            watchBoard(boardUrl);

            // SNMP link overlay. The path is now derived from the board's
            // directory rather than requiring ?snmp=, which is safe because
            // SnmpLayer.init returns immediately when the board carries no
            // {CODE} bindings - a board that never mentions SNMP opens no feed
            // and costs nothing. A board that DOES mention it clearly wants the
            // data, and previously got nothing unless the URL was typed in full.
            if (snmpUrl && window.SnmpLayer) {
                window.SnmpLayer.init({ snmpUrl: snmpUrl, interval: snmpInterval, staleMul: staleMul,
                                        annStyle: params.get('annstyle') });
            }
        })
        .catch(function (err) { fail('Board failed to load: ' + boardUrl + ' (' + err.message + ')'); });
})();
