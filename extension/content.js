// Tactile browser bridge - content script.
//
// Reports, per page, which clickable element the cursor is over, using the
// real DOM. This closes the gap the macOS accessibility path fundamentally
// cannot: <div>/<span> controls with a click handler and cursor:pointer but no
// ARIA role never enter the accessibility tree, yet they are exactly the
// "clickable things" Tactile exists to surface.
//
// Detection mirrors the app's ClickabilityClassifier (role -> category) and
// ContextDetector (destructive-label -> danger) so web feels match native
// feels. The script emits an event only when the hovered clickable's identity
// changes - the browser already recomputes hover per frame, so this is nearly
// free - matching Tactile's "one feel per enter" model.

(() => {
  "use strict";

  // Version marker, readable from the page (and DevTools console) as
  // document.documentElement.dataset.tactileBridge - the fastest way to
  // check which build of this script a tab is actually running.
  const BRIDGE_VERSION = "3";
  function stamp() {
    try {
      if (document.documentElement) document.documentElement.dataset.tactileBridge = BRIDGE_VERSION;
    } catch (_) { /* document_start race; the DOMContentLoaded retry covers it */ }
  }
  stamp();
  document.addEventListener("DOMContentLoaded", stamp);

  // Word-boundary danger set, kept in sync with ContextDetector.dangerWords.
  const DANGER_WORDS = new Set([
    "delete", "remove", "trash", "erase", "discard", "uninstall",
    "clear", "reset", "quit", "close", "empty", "eject", "disconnect",
    "terminate", "destroy", "wipe", "forget", "revoke", "unsubscribe",
  ]);

  const MAX_ANCESTORS = 12;

  // The last clickable element we reported, so we fire on enter only.
  let lastEl = null;
  // Its geometry and kind, so a re-rendered node in the same place doesn't
  // read as a new control (hover-reactive sites re-create nodes constantly).
  let lastRect = null;
  let lastCategory = null;
  // The last fired target's destination. Search-result cards repeat one
  // destination across several sibling links (title, quote, metadata row);
  // crossing between them is still the same logical target - one feel.
  let lastHref = null;

  function hrefOf(el) {
    if (!el || !el.closest) return null;
    const anchor = el.closest("a[href]");
    return anchor ? anchor.href : null;
  }
  // Whether the app currently thinks the pointer is inside this page.
  let reportedInViewport = false;

  function boundsOf(el) {
    const r = el.getBoundingClientRect();
    return { x: r.x, y: r.y, w: r.width, h: r.height };
  }

  // Heavy mutual overlap (intersection over union) means the same control
  // re-rendered or mid-hover-animation - sites translate and scale controls
  // on hover, so exact rect equality broke identity on every animation frame
  // and re-fired one control many times. Neighbouring controls share edges,
  // not area, so they never come close to this threshold.
  function sameBounds(a, b) {
    if (!a || !b) return false;
    const ix = Math.max(0, Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x));
    const iy = Math.max(0, Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y));
    const inter = ix * iy;
    const union = a.w * a.h + b.w * b.h - inter;
    return union > 0 && inter / union >= 0.6;
  }

  // Categories whose label names an ACTION the control performs. Links and
  // tabs are navigation - their text is content, so a commit message or
  // headline reading "remove old docs" must not shake as destructive.
  const DANGER_CATEGORIES = new Set(["button", "menuItem", "toggle", "genericPressable"]);

  function isDanger(el, category) {
    if (!DANGER_CATEGORIES.has(category)) return false;
    let text = el.getAttribute("aria-label") || el.getAttribute("title") || "";
    if (text.length < 2) text = (el.textContent || "").replace(/\s+/g, " ").trim();
    // Real action labels are short ("Delete repository"); anything long is
    // content leaking out of a wrapper element, not a label.
    if (!text || text.length > 40) return false;
    return text
      .toLowerCase()
      .split(/[^a-z]+/)
      .some((w) => DANGER_WORDS.has(w));
  }

  function accessibleName(el) {
    const label = el.getAttribute("aria-label") || el.getAttribute("title");
    if (label) return label.trim();
    return (el.textContent || "").replace(/\s+/g, " ").trim();
  }

  // Simple mode's notion of a "primary" target: the main content links you
  // actually navigate to, and prominent labeled controls - not the incidental
  // chrome around them (three-dot menus, favicons, "Read more", icon buttons).
  function isPrimary(el, category) {
    // Navigation is always primary: mode/tab rows, menu bars, nav sections.
    // Their labels are short ("News", "Images"), but they're main targets.
    if (el.closest && el.closest("nav,[role=navigation],[role=tablist],[role=menubar]")) {
      return accessibleName(el).length >= 2;
    }
    if (category === "link") {
      // Result titles are headings, or wrap / sit inside one.
      const headingSel = "h1,h2,h3,h4,h5,[role=heading]";
      if (el.matches(headingSel) || el.closest(headingSel) || el.querySelector(headingSel)) {
        return true;
      }
      // Otherwise, only substantial link text counts - this drops short
      // utility links like "Read more", "Show more", and bare site names.
      return accessibleName(el).length >= 15;
    }
    if (category === "button" || category === "tab" || category === "toggle") {
      if (accessibleName(el).length < 2) return false; // icon-only control
      const r = el.getBoundingClientRect();
      // Drop tiny icon controls (three-dot menus, chevrons); keep real buttons.
      return Math.min(r.width, r.height) >= 24 && r.width * r.height >= 900;
    }
    // menuItem / textField / slider / genericPressable are never "primary".
    return false;
  }

  function ariaBool(el, name) {
    const v = el.getAttribute(name);
    if (v === "true") return true;
    if (v === "false") return false;
    return null;
  }

  function isEnabled(el) {
    if (el.disabled === true) return false;
    if (el.getAttribute("aria-disabled") === "true") return false;
    return true;
  }

  // Maps one element to a Tactile category, or null if it isn't a control.
  // Returns { category, on } - `on` is checked/selected state or null.
  function categoryOf(el) {
    if (el.nodeType !== 1) return null;
    const tag = el.tagName ? el.tagName.toLowerCase() : "";
    const role = (el.getAttribute("role") || "").toLowerCase();

    // ARIA role wins over tag: authors use it precisely to override semantics.
    switch (role) {
      case "button": return { category: "button", on: ariaBool(el, "aria-pressed") };
      case "link": return { category: "link", on: null };
      case "checkbox":
      case "radio":
      case "switch": return { category: "toggle", on: ariaBool(el, "aria-checked") };
      case "tab": return { category: "tab", on: ariaBool(el, "aria-selected") };
      case "menuitem":
      case "menuitemcheckbox":
      case "menuitemradio": return { category: "menuItem", on: ariaBool(el, "aria-checked") };
      case "combobox":
      case "listbox": return { category: "menuItem", on: null };
      case "slider":
      case "spinbutton": return { category: "slider", on: null };
      case "textbox":
      case "searchbox": return { category: "textField", on: null };
      default: break;
    }

    switch (tag) {
      case "a":
        return el.hasAttribute("href") ? { category: "link", on: null } : null;
      case "button":
        return { category: "button", on: null };
      case "select":
        return { category: "menuItem", on: null };
      case "textarea":
        return { category: "textField", on: null };
      case "summary":
        return { category: "toggle", on: el.parentElement && el.parentElement.tagName === "DETAILS" ? el.parentElement.open : null };
      case "input": {
        const type = (el.getAttribute("type") || "text").toLowerCase();
        if (type === "checkbox" || type === "radio") return { category: "toggle", on: el.checked };
        if (type === "range") return { category: "slider", on: null };
        if (type === "button" || type === "submit" || type === "reset" || type === "image") return { category: "button", on: null };
        if (type === "hidden") return null;
        return { category: "textField", on: null };
      }
      default: break;
    }

    if (el.isContentEditable) return { category: "textField", on: null };

    // The accessibility-invisible case: a custom control with no role or
    // semantic tag, recognised only by its pointer cursor. `cursor` is an
    // INHERITED property, so it must originate on this element: otherwise
    // every span, icon, and text line inside a role-less button - or inside
    // a big clickable card - computes to `pointer` too, and one visual
    // control becomes a swarm of fragment "controls" that each fire.
    // (The card case is the worst: the card itself is over the size ceiling
    // and rightly rejected, but its small text lines all pass.) Bounded to
    // control-like sizes (mirroring the app's own sanity check) so big
    // cards, feed wrappers, and page sections never register as controls.
    let cursor = "";
    try { cursor = getComputedStyle(el).cursor; } catch (_) { cursor = ""; }
    if (cursor === "pointer" && !parentHasPointer(el)) {
      const r = el.getBoundingClientRect();
      if (r.width > 0 && r.height > 0 && r.width <= 900 && r.height <= 350 && r.width * r.height <= 160000) {
        return { category: "genericPressable", on: null };
      }
    }
    return null;
  }

  // Whether the pointer cursor is inherited rather than the element's own -
  // the parent computing `pointer` too means the style cascades from above.
  function parentHasPointer(el) {
    const parent = el.parentElement;
    if (!parent || parent === document.body || parent === document.documentElement) return false;
    try { return getComputedStyle(parent).cursor === "pointer"; } catch (_) { return false; }
  }

  // ---- Viewport→screen calibration ---------------------------------------
  // Chrome exposes no API for the viewport's screen origin, and inferring it
  // from window metrics breaks whenever browser chrome isn't all at the top:
  // a side panel shifts the whole viewport right, dev tools shift it up, and
  // page zoom scales everything - each error pushed every reported rect past
  // the app's cross-path tolerance, so the accessibility path stopped
  // recognising bridge fires as the same control and every control fired
  // twice (or more, on hover-churny pages). Real mouse events carry both
  // coordinate spaces at once, so each event calibrates the mapping exactly:
  //   origin = event.screen − event.client · zoom
  // and zoom itself comes from the screen/client distance ratio between
  // far-apart events. Rect error then scales with the cursor's distance to
  // the element - practically zero during a hover - not with window layout.
  const ZOOM_STEPS = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5];
  let calibratedZoom = null;
  let viewportOrigin = null; // [x, y] of the viewport in screen points
  let zoomSample = null;

  function snapZoom(raw) {
    let best = 1;
    let err = Infinity;
    for (const step of ZOOM_STEPS) {
      const e = Math.abs(raw - step);
      if (e < err) { err = e; best = step; }
    }
    return best;
  }

  // Window-metrics fallback for before the first event: right only when all
  // chrome is at the top, but immediately superseded by event calibration.
  function pageZoom() {
    const raw = window.outerWidth / window.innerWidth;
    if (!isFinite(raw) || raw <= 0) return 1;
    return snapZoom(raw);
  }

  function calibrate(e) {
    if (zoomSample) {
      const dc = Math.hypot(e.clientX - zoomSample.cx, e.clientY - zoomSample.cy);
      if (dc >= 150) {
        const ds = Math.hypot(e.screenX - zoomSample.sx, e.screenY - zoomSample.sy);
        if (ds > 0) calibratedZoom = snapZoom(ds / dc);
        zoomSample = { cx: e.clientX, cy: e.clientY, sx: e.screenX, sy: e.screenY };
      }
    } else {
      zoomSample = { cx: e.clientX, cy: e.clientY, sx: e.screenX, sy: e.screenY };
    }
    const z = calibratedZoom ?? pageZoom();
    viewportOrigin = [e.screenX - e.clientX * z, e.screenY - e.clientY * z];
  }

  // The element's frame in global screen coordinates. Used by the app to
  // recognise the same control across paths and to draw the element
  // highlight; the residual error is absorbed by generous tolerances there.
  function screenRect(el) {
    const r = el.getBoundingClientRect();
    const z = calibratedZoom ?? pageZoom();
    let ox, oy;
    if (viewportOrigin) {
      [ox, oy] = viewportOrigin;
    } else {
      ox = window.screenX;
      oy = window.screenY + Math.max(0, window.outerHeight - window.innerHeight * z);
    }
    return [
      Math.round(ox + r.left * z),
      Math.round(oy + r.top * z),
      Math.round(r.width * z),
      Math.round(r.height * z),
    ];
  }

  // Walks up from `start` to the nearest clickable ancestor (label -> control).
  // Semantic matches (role or tag) win over cursor:pointer-only matches even
  // when the pointer match is deeper: cursor:pointer inherits into a control's
  // inner spans, and hover-reactive sites re-create those inner nodes on every
  // mousemove - the semantic ancestor is the identity-stable element.
  function resolveClickable(start) {
    let el = start;
    let pointerMatch = null;
    for (let i = 0; i < MAX_ANCESTORS && el && el.nodeType === 1; i++) {
      if (el === document.body || el === document.documentElement) break;
      const c = categoryOf(el);
      if (c) {
        if (c.category !== "genericPressable") return { el, ...c };
        if (!pointerMatch) pointerMatch = { el, ...c };
      }
      el = el.parentElement;
    }
    return pointerMatch;
  }

  function send(msg) {
    try {
      chrome.runtime.sendMessage(msg);
    } catch (_) {
      // Service worker asleep or extension reloading; the next event retries.
    }
  }

  function reportHover(match) {
    lastEl = match.el;
    lastRect = boundsOf(match.el);
    lastCategory = match.category;
    // Sticky: only a target that HAS a destination replaces the memory, so
    // a button between two fragments of one link doesn't re-arm the link.
    const href = hrefOf(match.el);
    if (href !== null) lastHref = href;
    reportedInViewport = true;
    send({
      type: "hover",
      el: match.category,
      enabled: isEnabled(match.el),
      on: match.on,
      danger: isDanger(match.el, match.category),
      primary: isPrimary(match.el, match.category),
      rect: screenRect(match.el),
      label: accessibleName(match.el).slice(0, 60),
      inViewport: true,
    });
  }

  // Pointer is still in the page but not on a clickable - hand nothing to fire,
  // but keep the app suppressing its accessibility path for this page.
  function reportBlank() {
    if (lastEl === null && reportedInViewport) return;
    lastEl = null;
    lastRect = null;
    lastCategory = null;
    reportedInViewport = true;
    send({ type: "leave", inViewport: true });
  }

  // Pointer left the page entirely (into the tab strip, toolbar, another
  // window). The app hands control back to the accessibility path.
  function reportExit() {
    lastEl = null;
    lastRect = null;
    lastCategory = null;
    lastHref = null;
    reportedInViewport = false;
    send({ type: "leave", inViewport: false });
  }

  function onOver(event) {
    calibrate(event);
    const match = resolveClickable(event.target);
    if (!match) {
      reportBlank();
      return;
    }
    if (match.el === lastEl) return; // Same control - one feel per enter.
    // A different node with the same kind and (roughly) the same geometry is
    // the same control re-rendered under the cursor, not a new one. The rect
    // is re-remembered so identity tracks the control through an animation.
    if (lastEl !== null && match.category === lastCategory && sameBounds(boundsOf(match.el), lastRect)) {
      lastEl = match.el;
      lastRect = boundsOf(match.el);
      return;
    }
    // Same destination as the last fired target: sibling fragments of one
    // logical result (title, quoted text, metadata row all linking to the
    // same page). Deliberately sticky across the blank gaps between them.
    const href = hrefOf(match.el);
    if (href !== null && href === lastHref) {
      lastEl = match.el;
      lastRect = boundsOf(match.el);
      lastCategory = match.category;
      return;
    }
    reportHover(match);
  }

  function onOut(event) {
    // relatedTarget null means the pointer left the document for chrome or
    // another window, not merely crossed into a child/sibling element.
    if (event.relatedTarget !== null) return;
    // ...except when the hovered node was just REMOVED from the DOM (tooltip
    // unmount, hover re-render): that also reports null, but the pointer
    // didn't go anywhere - treating it as an exit wiped the dedupe memory
    // and re-fired the control the pointer was still resting on.
    if (event.target && event.target.isConnected === false) return;
    reportExit();
  }

  document.addEventListener("mouseover", onOver, true);
  document.addEventListener("mouseout", onOut, true);
  // Heartbeat: a throttled ping while the pointer moves inside this page
  // tells the app the page is instrumented, so it can hand feedback back to
  // the accessibility path quickly on pages where content scripts can't run
  // (chrome:// pages, PDFs, the Web Store).
  let lastPing = 0;
  document.addEventListener("mousemove", (e) => {
    calibrate(e);
    const now = Date.now();
    if (now - lastPing > 600) {
      lastPing = now;
      send({ type: "ping", inViewport: true });
    }
  }, true);
  // Belt-and-suspenders: leaving the top document's viewport. documentElement
  // can be null at document_start, so guard it - the mouseout path above still
  // reports the exit regardless. CRITICAL: mouseleave doesn't bubble, but a
  // CAPTURE listener still sees every descendant's mouseleave - crossing from
  // a button's icon to its label fired a full "left the page" exit, wiping
  // the dedupe state and re-firing the same button once per child boundary
  // (the great multi-fire bug). Only the root's own mouseleave counts.
  const root = document.documentElement;
  if (root) root.addEventListener("mouseleave", (e) => { if (e.target === root) reportExit(); }, true);

  // Test hook, inert in the browser (`module` is undefined there). Lets the
  // classifier be unit-tested under Node without a real browser.
  if (typeof module !== "undefined" && module.exports) {
    module.exports = { categoryOf, resolveClickable, isDanger, isEnabled, isPrimary };
  }
})();
