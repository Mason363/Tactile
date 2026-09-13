//
//  NotificationBannerWatcher.swift
//  Tactile
//

import AppKit
import ApplicationServices

/// Notices notification banners arriving, through the accessibility tree
/// of macOS's Notification Center process. Only the fact that a banner
/// appeared is read: its role, and an identifier so each banner counts
/// once. Never its title, text, or app.
///
/// The first banner on screen brings its own window; a banner arriving
/// while another still shows lands in that window and reports a layout
/// change on itself. Both are watched. Opening Notification Center shows
/// the history as the same kind of element, but inside a list group, and
/// anything in that list is ignored.
@MainActor
final class NotificationBannerWatcher {
    var onBanner: (() -> Void)?

    private static let bundleID = "com.apple.notificationcenterui"
    private static let bannerSubroles: Set<String> = ["AXNotificationCenterBanner", "AXNotificationCenterBannerStack"]
    private static let historyListID = "AXNotificationListItems"

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var watchedApp: NSRunningApplication?
    /// Recently seen banner identifiers, oldest first.
    private var seen: [String] = []
    private var lastFire: CFTimeInterval = 0
    private var healthTimer: Timer?

    var isRunning: Bool { healthTimer != nil }

    func start() {
        guard healthTimer == nil else { return }
        attach()
        // Notification Center can relaunch (a crash, a system update) and
        // the observer goes with it; a cheap periodic check re-attaches.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        detach()
    }

    private func attach() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<NotificationBannerWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.handle(element, notification as String) }
        }
        var created: AXObserver?
        guard AXObserverCreate(app.processIdentifier, callback, &created) == .success, let created else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification] {
            AXObserverAddNotification(created, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        appElement = element
        watchedApp = app
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            if let appElement {
                for name in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification] {
                    AXObserverRemoveNotification(observer, appElement, name as CFString)
                }
            }
        }
        observer = nil
        appElement = nil
        watchedApp = nil
    }

    private func checkHealth() {
        guard watchedApp == nil || watchedApp?.isTerminated == true else { return }
        detach()
        attach()
    }

    // MARK: - Events

    private func handle(_ element: AXUIElement, _ notification: String) {
        if let subrole = Self.string(element, kAXSubroleAttribute), Self.bannerSubroles.contains(subrole) {
            // A banner joining the one on screen reports on itself.
            if !isInHistory(element) { bannerAppeared(element) }
            return
        }
        guard notification == kAXWindowCreatedNotification
            || Self.string(element, kAXRoleAttribute) == kAXWindowRole
        else { return }
        scan(window: element)
    }

    /// Finds the banners a new window carries, never descending into the
    /// history list. A window full of banners at once is Notification
    /// Center opening, not news: remember them, stay quiet.
    private func scan(window: AXUIElement) {
        var pending: [(AXUIElement, Int)] = [(window, 0)]
        var banners: [AXUIElement] = []
        var visited = 0
        while !pending.isEmpty, visited < 80 {
            let (element, depth) = pending.removeFirst()
            visited += 1
            if Self.string(element, kAXIdentifierAttribute) == Self.historyListID { continue }
            if let subrole = Self.string(element, kAXSubroleAttribute), Self.bannerSubroles.contains(subrole) {
                banners.append(element)
                continue
            }
            guard depth < 6, let children = Self.children(element) else { continue }
            pending.append(contentsOf: children.prefix(16).map { ($0, depth + 1) })
        }
        let fresh = banners.filter { !seen.contains(Self.identity($0)) }
        if fresh.count > 2 {
            fresh.forEach { remember(Self.identity($0)) }
            return
        }
        fresh.forEach(bannerAppeared)
    }

    private func bannerAppeared(_ element: AXUIElement) {
        let identity = Self.identity(element)
        guard !seen.contains(identity) else { return }
        remember(identity)
        let now = CACurrentMediaTime()
        // Several at once feel like one.
        guard now - lastFire > 0.8 else { return }
        lastFire = now
        onBanner?()
    }

    private func remember(_ identity: String) {
        seen.append(identity)
        if seen.count > 64 { seen.removeFirst(seen.count - 64) }
    }

    /// Inside Notification Center's history list, a few levels up.
    private func isInHistory(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<3 {
            guard let parent = Self.parent(current) else { return false }
            if Self.string(parent, kAXIdentifierAttribute) == Self.historyListID { return true }
            current = parent
        }
        return false
    }

    // MARK: - AX helpers

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private static func parent(_ element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    /// The banner's own identifier (a UUID per notification), or the
    /// element's identity when it has none.
    private static func identity(_ element: AXUIElement) -> String {
        string(element, kAXIdentifierAttribute) ?? "hash:\(CFHash(element))"
    }
}
