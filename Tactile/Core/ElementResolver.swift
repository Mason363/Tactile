//
//  ElementResolver.swift
//  Tactile
//

import AppKit
import ApplicationServices

/// Everything the pipeline needs to know about the element under the cursor.
struct ResolvedElement {
    let element: AXUIElement
    let role: String
    let subrole: String?
    let actions: [String]
    /// Element frame in global top-left coordinates, when the app reports one.
    let frame: CGRect?
    let pid: pid_t
    let bundleID: String?
    let enabled: Bool
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

    private let queue = DispatchQueue(label: "com.masonchen.Tactile.resolver", qos: .userInteractive)
    private let systemWide = AXUIElementCreateSystemWide()

    private let stateLock = NSLock()
    private var pendingPoint: CGPoint?
    private var isDraining = false

    private var bundleIDCache: [pid_t: String?] = [:]

    private static let axTimeout: Float = 0.1

    /// Hard ceiling on the speculative ancestor/descent search per hit-test.
    /// The essential first resolution is never budgeted; only the extra work
    /// to recover a clickable element from a container is, so a slow app can
    /// never stall the queue for more than roughly one AX timeout past this.
    private static let searchBudget: CFTimeInterval = 0.03

    /// Most children to inspect at one level during the spatial descent.
    private static let maxChildrenPerLevel: CFIndex = 12

    init() {
        AXUIElementSetMessagingTimeout(systemWide, Self.axTimeout)
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
                Task { @MainActor in onResolve(point, resolved) }
            }
        }
    }

    // MARK: - AX queries (background queue only)

    private func hitTest(at point: CGPoint) -> ResolvedElement? {
        var elementRef: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elementRef)
        guard error == .success, let element = elementRef else { return nil }

        let resolved = makeResolved(element)
        if isClickable(resolved) { return resolved }

        // Everything below is best-effort recovery of a clickable element
        // from a container, capped by a wall-clock deadline so a slow app
        // can never wedge the queue for seconds.
        let deadline = CACurrentMediaTime() + Self.searchBudget

        // The deepest element is often decoration inside the real control —
        // the text label of a button, a span inside a link. Look a few
        // ancestors up for a clickable element that still contains the cursor.
        if let ancestor = clickableAncestor(of: element, containing: point, deadline: deadline) {
            return ancestor
        }

        // Some apps (web content especially) hit-test lazily: the padding
        // around a button reports the enclosing group even though the
        // button's own frame contains the point. The button is a child of
        // that group, so descend spatially through containing children.
        if let descendant = clickableDescendant(of: element, containing: point, depth: 2, deadline: deadline) {
            return descendant
        }

        return resolved
    }

    private func isClickable(_ resolved: ResolvedElement) -> Bool {
        ClickabilityClassifier.classify(
            role: resolved.role,
            subrole: resolved.subrole,
            actions: resolved.actions
        ) != nil
    }

    /// First `maxValues` children only, fetched without materializing the
    /// whole array — critical on web containers with thousands of children.
    private func boundedChildren(of element: AXUIElement, maxValues: CFIndex) -> [AXUIElement] {
        var valuesRef: CFArray?
        let error = AXUIElementCopyAttributeValues(element, "AXChildren" as CFString, 0, maxValues, &valuesRef)
        guard error == .success else { return [] }
        return (valuesRef as? [AXUIElement]) ?? []
    }

    private func clickableDescendant(of element: AXUIElement, containing point: CGPoint, depth: Int, deadline: CFTimeInterval) -> ResolvedElement? {
        guard depth > 0, CACurrentMediaTime() < deadline else { return nil }

        let children = boundedChildren(of: element, maxValues: Self.maxChildrenPerLevel)
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
            if let deeper = clickableDescendant(of: child, containing: point, depth: depth - 1, deadline: deadline) {
                return deeper
            }
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
            // Structural roles end the walk — nothing clickable sits above.
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
