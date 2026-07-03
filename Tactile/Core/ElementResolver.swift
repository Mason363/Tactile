//
//  ElementResolver.swift
//  Tactile
//

import AppKit
import ApplicationServices
import QuartzCore

/// Everything the pipeline needs to know about the element under the cursor.
struct ResolvedElement {
    let element: AXUIElement
    var role: String
    var subrole: String?
    var actions: [String]
    /// Element frame in global top-left coordinates, when the app reports one.
    var frame: CGRect?
    var pid: pid_t
    var bundleID: String?
    var enabled: Bool
    /// Label text, fetched only for clickable elements (danger detection).
    var title: String?
    /// Checked/selected state, fetched only for toggles and tabs.
    var isOn: Bool?
    /// Destination URL, fetched only for links - used to treat sibling
    /// fragments of one result (title, snippet, byline) as a single target.
    var url: String?
    /// Containing window, fetched only when window-boundary feedback is on.
    var window: AXUIElement?
    /// Whether the element is in the system's focused window. Defaults true
    /// so the focus filter is a no-op unless the pipeline asks for it.
    var isInFocusedWindow = true
}

/// Hit-tests the accessibility tree on a background queue.
///
/// Queries run strictly one at a time with latest-wins coalescing: while a
/// query is in flight, newer cursor positions overwrite the pending one and
/// stale positions are never resolved. A short messaging timeout guarantees
/// a hung app can never wedge the pipeline.
final class ElementResolver {
    /// Delivered on the main actor with the position that was resolved.
    var onResolve: (@MainActor (CGPoint, ResolvedElement?) -> Void)?

    /// When true, resolutions include the containing window (one extra AX
    /// call) so the pipeline can feel window-boundary crossings.
    var wantsWindow = false

    /// When true, resolutions record whether the element is in the focused
    /// window, for the buttons-in-focused-window quiet mode.
    var wantsFocusedWindow = false

    private let queue = DispatchQueue(label: "com.masonchen.Tactile.resolver", qos: .userInteractive)
    private let systemWide = AXUIElementCreateSystemWide()

    /// Our own process id. Querying our own AppKit views' accessibility off
    /// the main thread is unsafe (see `hitTest`), so own-process resolutions
    /// are detected up front and run on main.
    private let ownPID = getpid()

    private let stateLock = NSLock()
    private var pendingPoint: CGPoint?
    private var isDraining = false

    private var bundleIDCache: [pid_t: String?] = [:]

    private var cachedFocusedWindow: AXUIElement?
    private var focusedWindowStamp: CFTimeInterval = 0

    private var cachedFocusedMenu: AXUIElement?
    private var focusedMenuStamp: CFTimeInterval = 0

    /// Separate handle for focus queries: they run at most every 400ms, so
    /// they can afford a longer timeout than per-sample hit-testing -
    /// Chromium regularly needs more than 50ms to answer them. The timeout
    /// is still kept tight (100ms): this query runs at the front of every
    /// hit-test on a cache miss, so its worst case bounds the whole
    /// pipeline's worst case.
    private let focusQuery = AXUIElementCreateSystemWide()

    private static let axTimeout: Float = 0.05

    /// Hard ceiling on the speculative ancestor/descent search per hit-test.
    /// The essential first resolution is never budgeted; only the extra work
    /// to recover a clickable element from a container is, so a slow app can
    /// never stall the queue for more than roughly one AX timeout past this.
    private static let searchBudget: CFTimeInterval = 0.03

    /// Most children to inspect at one level during the spatial descent.
    private static let maxChildrenPerLevel: CFIndex = 12

    init() {
        AXUIElementSetMessagingTimeout(systemWide, Self.axTimeout)
        AXUIElementSetMessagingTimeout(focusQuery, 0.1)
    }

    func resolve(at point: CGPoint) {
        stateLock.lock()
        pendingPoint = point
        let shouldStart = !isDraining
        if shouldStart { isDraining = true }
        stateLock.unlock()

        guard shouldStart else { return }
        queue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        while true {
            stateLock.lock()
            guard let point = pendingPoint else {
                isDraining = false
                stateLock.unlock()
                return
            }
            pendingPoint = nil
            stateLock.unlock()

            let resolved = hitTest(at: point)
            if let onResolve {
                // FIFO delivery (DispatchQueue.main, not unstructured Tasks):
                // two resolutions arriving out of order would let a STALE
                // position overwrite a newer one downstream - the dedupe
                // state machine assumes samples arrive in cursor order.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { onResolve(point, resolved) }
                }
            }
        }
    }

    // MARK: - AX queries (background queue only)

    private func hitTest(at point: CGPoint) -> ResolvedElement? {
        // Resolve the element under the cursor. Cross-process AX calls are MIG
        // messages and safe off-main; the copy-at-position hit-test is safe
        // even when it lands on our own process. But the *attribute* queries
        // below are serviced synchronously in-process for our own windows
        // (Sparkle's update dialog, the settings window), and touching an
        // AppKit view off the main thread - e.g. an NSImageView still doing
        // async image preparation for the app icon - trips an assertion and
        // aborts. So if the element belongs to us, redo the whole resolution
        // on the main thread before querying anything about it.
        var elementRef: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elementRef)
        guard error == .success, let element = elementRef else { return nil }

        if !Thread.isMainThread, elementPID(element) == ownPID {
            return DispatchQueue.main.sync { hitTest(at: point) }
        }

        // Web overlay popups (Chromium/Electron menus, selects) defeat the
        // window-server hit-test: it frequently reports the elements *behind*
        // the popup. While such a popup is open it holds accessibility focus,
        // so when the cursor is inside the focused menu, resolve within it.
        if let menu = focusedMenuContainer(), let menuFrame = frameAttribute(menu), menuFrame.contains(point) {
            let deadline = CACurrentMediaTime() + 0.05
            if let item = clickableDescendant(of: menu, containing: point, depth: 3, deadline: deadline, maxPerLevel: 48) {
                return enrich(item)
            }
            // Over popup chrome between items: report the popup itself as
            // inert so elements visually beneath it can't fire.
            var chrome = makeResolved(menu)
            chrome.actions = []
            return chrome
        }

        let resolved = makeResolved(element)
        if isClickable(resolved) {
            // A generic pressable is the weak catch-all bucket, wrong in two
            // opposite ways. It can be a *container* that merely advertises a
            // press action while holding the real controls inside it (SwiftUI
            // Form rows, web and Electron wrappers) - prefer a more specific
            // control under the cursor. And it can be a *fragment*: web
            // engines expose the press action on the descendants of a
            // clickable too, so the image and each text run inside a link or
            // button all report as pressable islands of their own - firing
            // once per island as the cursor crosses a single visual control.
            // Resolve those to the real control above; keep the element when
            // nothing better exists, so genuine <div>-style buttons still fire.
            if ClickabilityClassifier.classify(role: resolved.role, subrole: resolved.subrole, actions: resolved.actions) == .genericPressable {
                let deadline = CACurrentMediaTime() + Self.searchBudget
                if let frame = resolved.frame, frame.width > 420 || frame.height > 120,
                   let specific = specificDescendant(of: element, containing: point, depth: 3, deadline: deadline) {
                    return enrich(specific)
                }
                if let ancestor = semanticAncestor(of: element, containing: point, deadline: deadline) {
                    // The enclosing control is the target: one identity for
                    // the button and everything drawn inside it.
                    if let frame = ancestor.frame, ClickabilityClassifier.isControlSized(frame) {
                        return enrich(ancestor)
                    }
                    // The enclosing control is too big to fire (a whole card
                    // link): keep the fragment, but carry the card's
                    // destination so all its fragments - image, title, text
                    // lines - dedupe as one logical target downstream.
                    var enriched = enrich(resolved)
                    var urlRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(ancestor.element, "AXURL" as CFString, &urlRef) == .success {
                        enriched.url = (urlRef as? URL)?.absoluteString ?? (urlRef as? String)
                    }
                    return enriched
                }
            }
            return enrich(resolved)
        }

        // Everything below is best-effort recovery of a clickable element
        // from a container, capped by a wall-clock deadline so a slow app
        // can never wedge the queue for seconds.
        let deadline = CACurrentMediaTime() + Self.searchBudget

        // The deepest element is often decoration inside the real control -
        // the text label of a button, a span inside a link. Look a few
        // ancestors up for a clickable element that still contains the cursor.
        if let ancestor = clickableAncestor(of: element, containing: point, deadline: deadline) {
            return enrich(ancestor)
        }

        // Some apps (web content especially) hit-test lazily: the padding
        // around a button reports the enclosing group even though the
        // button's own frame contains the point. The button is a child of
        // that group, so descend spatially through containing children.
        if let descendant = clickableDescendant(of: element, containing: point, depth: 2, deadline: deadline) {
            return enrich(descendant)
        }

        // Tab strips (Chrome, native AXTabGroup) hit-test to an inert wrapper
        // several levels above the real tab buttons, which are neither
        // exposed via AXTabs nor reachable by the shallow descent. Resolve
        // the individual tab the cursor is over with a dedicated search.
        if let tab = tabUnderCursor(near: element, point: point) {
            return enrich(tab)
        }

        return enrich(resolved)
    }

    /// Adds the detail attributes downstream features need - label text for
    /// danger detection, checked/selected state, containing window - fetching
    /// each only when something will actually use it.
    private func enrich(_ resolved: ResolvedElement) -> ResolvedElement {
        var enriched = resolved

        if wantsWindow || wantsFocusedWindow {
            var windowRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(resolved.element, "AXWindow" as CFString, &windowRef) == .success,
               let value = windowRef, CFGetTypeID(value) == AXUIElementGetTypeID() {
                enriched.window = (value as! AXUIElement)
            }
        }

        if wantsFocusedWindow {
            if let window = enriched.window, let focused = systemFocusedWindow() {
                enriched.isInFocusedWindow = CFEqual(window, focused)
            } else {
                enriched.isInFocusedWindow = false
            }
        }

        guard let category = ClickabilityClassifier.classify(
            role: resolved.role,
            subrole: resolved.subrole,
            actions: resolved.actions
        ) else { return enriched }

        enriched.title = stringAttribute(resolved.element, "AXTitle")
        if enriched.title?.isEmpty != false {
            enriched.title = stringAttribute(resolved.element, "AXDescription")
        }

        switch category {
        case .toggle:
            enriched.isOn = numberAttribute(resolved.element, "AXValue").map { $0 > 0 }
        case .tab:
            enriched.isOn = boolAttribute(resolved.element, "AXSelected")
                ?? numberAttribute(resolved.element, "AXValue").map { $0 > 0 }
        case .link:
            var urlRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(resolved.element, "AXURL" as CFString, &urlRef) == .success {
                enriched.url = (urlRef as? URL)?.absoluteString ?? (urlRef as? String)
            }
        default:
            break
        }
        return enriched
    }

    /// Walks up to an enclosing AXTabGroup and finds the AXTabButton under
    /// the cursor. Runs on its own budget - it only triggers inside tab
    /// strips, and the found tab's frame gets cached as the skip region.
    private func tabUnderCursor(near element: AXUIElement, point: CGPoint) -> ResolvedElement? {
        let deadline = CACurrentMediaTime() + 0.05
        var current = element
        for _ in 0..<4 {
            if CACurrentMediaTime() >= deadline { return nil }
            if stringAttribute(current, "AXRole") == "AXTabGroup" {
                return tabButton(in: current, containing: point, depth: 7, deadline: deadline)
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, "AXParent" as CFString, &parentRef) == .success,
                  let value = parentRef, CFGetTypeID(value) == AXUIElementGetTypeID()
            else { return nil }
            current = value as! AXUIElement
        }
        return nil
    }

    /// Spatial search: descend only through children whose frame contains
    /// the point (fan-out stays ~1 until the tab row itself) until an
    /// AXTabButton is found.
    private func tabButton(in container: AXUIElement, containing point: CGPoint, depth: Int, deadline: CFTimeInterval) -> ResolvedElement? {
        guard depth > 0 else { return nil }

        for child in boundedChildren(of: container, maxValues: 48) {
            if CACurrentMediaTime() >= deadline { return nil }
            AXUIElementSetMessagingTimeout(child, Self.axTimeout)
            guard let frame = frameAttribute(child), frame.contains(point) else { continue }

            if stringAttribute(child, "AXSubrole") == "AXTabButton" {
                var pid: pid_t = 0
                AXUIElementGetPid(child, &pid)
                return ResolvedElement(
                    element: child,
                    role: stringAttribute(child, "AXRole") ?? "AXRadioButton",
                    subrole: "AXTabButton",
                    actions: actionNames(child),
                    frame: frame,
                    pid: pid,
                    bundleID: bundleID(for: pid),
                    enabled: boolAttribute(child, "AXEnabled") ?? true
                )
            }

            if let found = tabButton(in: child, containing: point, depth: depth - 1, deadline: deadline) {
                return found
            }
        }
        return nil
    }

    /// The process id owning an AX element. `AXUIElementGetPid` reads the pid
    /// stored in the element - it doesn't message the target app - so it's
    /// safe on the background queue even for our own process.
    private func elementPID(_ element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    private func isClickable(_ resolved: ResolvedElement) -> Bool {
        ClickabilityClassifier.classify(
            role: resolved.role,
            subrole: resolved.subrole,
            actions: resolved.actions
        ) != nil
    }

    /// First `maxValues` children only, fetched without materializing the
    /// whole array - critical on web containers with thousands of children.
    private func boundedChildren(of element: AXUIElement, maxValues: CFIndex) -> [AXUIElement] {
        var valuesRef: CFArray?
        let error = AXUIElementCopyAttributeValues(element, "AXChildren" as CFString, 0, maxValues, &valuesRef)
        guard error == .success else { return [] }
        return (valuesRef as? [AXUIElement]) ?? []
    }

    private func clickableDescendant(of element: AXUIElement, containing point: CGPoint, depth: Int, deadline: CFTimeInterval, maxPerLevel: CFIndex = ElementResolver.maxChildrenPerLevel) -> ResolvedElement? {
        guard depth > 0, CACurrentMediaTime() < deadline else { return nil }

        let children = boundedChildren(of: element, maxValues: maxPerLevel)
        guard !children.isEmpty else { return nil }

        for child in children {
            if CACurrentMediaTime() >= deadline { return nil }
            AXUIElementSetMessagingTimeout(child, Self.axTimeout)
            // Frame first: it's the cheap gate that skips children the cursor
            // isn't inside, before the fuller (costlier) resolution.
            guard let frame = frameAttribute(child), frame.contains(point) else { continue }

            let resolved = makeResolved(child)
            if isClickable(resolved) { return resolved }

            // Only the child that contains the point is worth entering, so
            // this stays a narrow spatial path, not a tree walk.
            if let deeper = clickableDescendant(of: child, containing: point, depth: depth - 1, deadline: deadline, maxPerLevel: maxPerLevel) {
                return deeper
            }
        }
        return nil
    }

    /// Categories that justify redirecting a pressable container to a child:
    /// unambiguous interactive controls. Text fields and sliders are left
    /// out deliberately - a pressable row wrapping a text field is usually
    /// *about* the row, and redirecting there would silence it (those
    /// categories are off by default).
    private static let specificCategories: Set<FeedbackCategory> = [.button, .link, .toggle, .tab, .menuItem]

    /// Spatial descent that only accepts an unambiguous control, so a
    /// pressable container resolves to the real button or link inside it,
    /// descending through generic wrappers on the way down.
    private func specificDescendant(of element: AXUIElement, containing point: CGPoint, depth: Int, deadline: CFTimeInterval) -> ResolvedElement? {
        guard depth > 0, CACurrentMediaTime() < deadline else { return nil }

        for child in boundedChildren(of: element, maxValues: Self.maxChildrenPerLevel) {
            if CACurrentMediaTime() >= deadline { return nil }
            AXUIElementSetMessagingTimeout(child, Self.axTimeout)
            guard let frame = frameAttribute(child), frame.contains(point) else { continue }

            let resolved = makeResolved(child)
            let category = ClickabilityClassifier.classify(role: resolved.role, subrole: resolved.subrole, actions: resolved.actions)
            if let category, Self.specificCategories.contains(category) { return resolved }

            if let deeper = specificDescendant(of: child, containing: point, depth: depth - 1, deadline: deadline) {
                return deeper
            }
        }
        return nil
    }

    /// Walks up looking for an unambiguous control (button, link, toggle,
    /// tab, menu item) that contains the point - the identity-stable owner
    /// of a pressable fragment. Generic wrappers along the way are walked
    /// through, structural roles end the walk.
    private func semanticAncestor(of element: AXUIElement, containing point: CGPoint, deadline: CFTimeInterval) -> ResolvedElement? {
        var current = element
        for _ in 0..<4 {
            if CACurrentMediaTime() >= deadline { return nil }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, "AXParent" as CFString, &parentRef) == .success,
                  let parentValue = parentRef, CFGetTypeID(parentValue) == AXUIElementGetTypeID()
            else { return nil }
            let parent = parentValue as! AXUIElement

            let resolved = makeResolved(parent)
            if ["AXWindow", "AXSheet", "AXDrawer", "AXApplication", "AXMenuBar", "AXWebArea"].contains(resolved.role) {
                return nil
            }
            if let category = ClickabilityClassifier.classify(role: resolved.role, subrole: resolved.subrole, actions: resolved.actions),
               Self.specificCategories.contains(category),
               let frame = resolved.frame, frame.contains(point) {
                return resolved
            }
            current = parent
        }
        return nil
    }

    private func clickableAncestor(of element: AXUIElement, containing point: CGPoint, deadline: CFTimeInterval) -> ResolvedElement? {
        var current = element
        for _ in 0..<3 {
            if CACurrentMediaTime() >= deadline { return nil }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, "AXParent" as CFString, &parentRef) == .success,
                  let parentValue = parentRef, CFGetTypeID(parentValue) == AXUIElementGetTypeID()
            else { return nil }
            let parent = parentValue as! AXUIElement

            let resolved = makeResolved(parent)
            // Structural roles end the walk - nothing clickable sits above.
            if ["AXWindow", "AXSheet", "AXDrawer", "AXApplication", "AXMenuBar"].contains(resolved.role) {
                return nil
            }
            if isClickable(resolved), let frame = resolved.frame, frame.contains(point) {
                return resolved
            }
            current = parent
        }
        return nil
    }

    private func makeResolved(_ element: AXUIElement) -> ResolvedElement {
        AXUIElementSetMessagingTimeout(element, Self.axTimeout)

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        return ResolvedElement(
            element: element,
            role: stringAttribute(element, "AXRole") ?? "",
            subrole: stringAttribute(element, "AXSubrole"),
            actions: actionNames(element),
            frame: frameAttribute(element),
            pid: pid,
            bundleID: bundleID(for: pid),
            enabled: boolAttribute(element, "AXEnabled") ?? true
        )
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private func numberAttribute(_ element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    /// The menu container holding accessibility focus, if any - an open
    /// popup keeps focus on itself or one of its items (roving focus follows
    /// the pointer). Cached briefly; returns nil when nothing menu-like is
    /// focused, which is the overwhelmingly common case.
    private func focusedMenuContainer() -> AXUIElement? {
        let now = CACurrentMediaTime()
        if now - focusedMenuStamp < 0.4 { return cachedFocusedMenu }
        focusedMenuStamp = now
        cachedFocusedMenu = nil

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusQuery, "AXFocusedUIElement" as CFString, &focusedRef) == .success,
              let value = focusedRef, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let focused = value as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, Self.axTimeout)

        switch stringAttribute(focused, "AXRole") ?? "" {
        case "AXMenu":
            cachedFocusedMenu = focused
        case "AXMenuItem", "AXMenuButton":
            // Climb to the enclosing AXMenu - it spans the whole popup
            // including header chrome. Fall back to the immediate parent.
            var container = focused
            var best: AXUIElement?
            for _ in 0..<3 {
                var parentRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(container, "AXParent" as CFString, &parentRef) == .success,
                      let parentValue = parentRef, CFGetTypeID(parentValue) == AXUIElementGetTypeID()
                else { break }
                container = parentValue as! AXUIElement
                AXUIElementSetMessagingTimeout(container, Self.axTimeout)
                if best == nil { best = container }
                if stringAttribute(container, "AXRole") == "AXMenu" {
                    best = container
                    break
                }
            }
            cachedFocusedMenu = best
        default:
            break
        }
        return cachedFocusedMenu
    }

    /// The window with system-wide keyboard focus, cached briefly since it
    /// changes rarely and the lookup costs two AX calls.
    private func systemFocusedWindow() -> AXUIElement? {
        let now = CACurrentMediaTime()
        if now - focusedWindowStamp < 0.25 { return cachedFocusedWindow }
        focusedWindowStamp = now

        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, "AXFocusedApplication" as CFString, &appRef) == .success,
              let appValue = appRef, CFGetTypeID(appValue) == AXUIElementGetTypeID()
        else { cachedFocusedWindow = nil; return nil }
        let app = appValue as! AXUIElement
        AXUIElementSetMessagingTimeout(app, Self.axTimeout)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXFocusedWindow" as CFString, &windowRef) == .success,
              let windowValue = windowRef, CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else { cachedFocusedWindow = nil; return nil }

        cachedFocusedWindow = (windowValue as! AXUIElement)
        return cachedFocusedWindow
    }

    private func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private func frameAttribute(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXPosition" as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, "AXSize" as CFString, &sizeRef) == .success
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue = positionRef, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: position, size: size)
    }

    private func bundleID(for pid: pid_t) -> String? {
        if let cached = bundleIDCache[pid] { return cached }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        bundleIDCache[pid] = bundleID
        if bundleIDCache.count > 256 { bundleIDCache.removeAll() }
        return bundleID
    }
}
