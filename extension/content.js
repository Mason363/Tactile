// Tactile browser bridge — content script.
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
// changes — the browser already recomputes hover per frame, so this is nearly
// free — matching Tactile's "one feel per enter" model.

(() => {
  "use strict";

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
  let lastRectKey = null;
  let lastCategory = null;
  // Whether the app currently thinks the pointer is inside this page.
  let reportedInViewport = false;

  function rectKey(el) {
    const r = el.getBoundingClientRect();
    return `${Math.round(r.x)},${Math.round(r.y)},${Math.round(r.width)},${Math.round(r.height)}`;
  }

  function isDanger(el) {
    const label = el.getAttribute("aria-label") || el.getAttribute("title") || "";
    // Own text only (not descendants' full subtree) keeps this cheap and
    // avoids a whole container's copy leaking destructive words onto a wrapper.
    let text = label;
    if (text.length < 2) text = (el.textContent || "").slice(0, 80);
    if (!text) return false;
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
  // actually navigate to, and prominent labeled controls — not the incidental
  // chrome around them (three-dot menus, favicons, "Read more", icon buttons).
  function isPrimary(el, category) {
    if (category === "link") {
      // Result titles are headings, or wrap / sit inside one.
      const headingSel = "h1,h2,h3,h4,h5,[role=heading]";
      if (el.matches(headingSel) || el.closest(headingSel) || el.querySelector(headingSel)) {
        return true;
      }
      // Otherwise, only substantial link text counts — this drops short
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
  // Returns { category, on } — `on` is checked/selected state or null.
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
    // semantic tag, recognised only by its pointer cursor. Guard against
    // page-sized elements that merely inherit cursor:pointer.
    let cursor = "";
    try { cursor = getComputedStyle(el).cursor; } catch (_) { cursor = ""; }
    if (cursor === "pointer") {
      const r = el.getBoundingClientRect();
      const coversViewport = r.width >= innerWidth * 0.9 && r.height >= innerHeight * 0.9;
      if (!coversViewport && r.width > 0 && r.height > 0) {
        return { category: "genericPressable", on: null };
      }
    }
    return null;
  }

  // Walks up from `start` to the nearest clickable ancestor (label -> control).
  // Semantic matches (role or tag) win over cursor:pointer-only matches even
  // when the pointer match is deeper: cursor:pointer inherits into a control's
  // inner spans, and hover-reactive sites re-create those inner nodes on every
  // mousemove — the semantic ancestor is the identity-stable element.
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
    lastRectKey = rectKey(match.el);
    lastCategory = match.category;
    reportedInViewport = true;
    send({
      type: "hover",
      el: match.category,
      enabled: isEnabled(match.el),
      on: match.on,
      danger: isDanger(match.el),
      primary: isPrimary(match.el, match.category),
      inViewport: true,
    });
  }

  // Pointer is still in the page but not on a clickable — hand nothing to fire,
  // but keep the app suppressing its accessibility path for this page.
  function reportBlank() {
    if (lastEl === null && reportedInViewport) return;
    lastEl = null;
    lastRectKey = null;
    lastCategory = null;
    reportedInViewport = true;
    send({ type: "leave", inViewport: true });
  }

  // Pointer left the page entirely (into the tab strip, toolbar, another
  // window). The app hands control back to the accessibility path.
  function reportExit() {
    lastEl = null;
    lastRectKey = null;
    lastCategory = null;
    reportedInViewport = false;
    send({ type: "leave", inViewport: false });
  }

  function onOver(event) {
    const match = resolveClickable(event.target);
    if (!match) {
      reportBlank();
      return;
    }
    if (match.el === lastEl) return; // Same control — one feel per enter.
    // A different node with the same kind and geometry is the same control
    // re-rendered under the cursor, not a new one.
    if (lastEl !== null && match.category === lastCategory && rectKey(match.el) === lastRectKey) {
      lastEl = match.el;
      return;
    }
    reportHover(match);
  }

  function onOut(event) {
    // relatedTarget null means the pointer left the document for chrome or
    // another window, not merely crossed into a child/sibling element.
    if (event.relatedTarget === null) reportExit();
  }

  document.addEventListener("mouseover", onOver, true);
  document.addEventListener("mouseout", onOut, true);
  // Belt-and-suspenders: leaving the top document's viewport. documentElement
  // can be null at document_start, so guard it — the mouseout path above still
  // reports the exit regardless.
  const root = document.documentElement;
  if (root) root.addEventListener("mouseleave", reportExit, true);

  // Test hook, inert in the browser (`module` is undefined there). Lets the
  // classifier be unit-tested under Node without a real browser.
  if (typeof module !== "undefined" && module.exports) {
    module.exports = { categoryOf, resolveClickable, isDanger, isEnabled, isPrimary };
  }
})();
