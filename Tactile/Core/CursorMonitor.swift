//
//  CursorMonitor.swift
//  Tactile
//

import AppKit
import QuartzCore

/// Watches global mouse movement and decides which positions are worth
/// resolving. Everything downstream is driven from here — when the mouse is
/// still, nothing in the app runs.
///
/// Events come from a listen-only CGEventTap rather than NSEvent global
/// monitors: monitors never see events consumed by nested tracking loops
/// (open menus, window drags, control tracking), which made feedback go
/// silent inside menus and submenus. The tap observes at the window-server
/// level, so those all work. NSEvent monitors remain as a fallback if tap
/// creation fails.
///
/// Three gates keep the accessibility queries rare without adding felt lag:
/// 1. A time throttle caps sampling at the configured polling rate, with a
///    trailing-edge sample so the cursor's final resting position is always
///    resolved even when the last mouse event fell inside the throttle window.
/// 2. A small distance gate ignores sub-pixel jitter.
/// 3. A skip region — the frame of the last resolved element — short-circuits
///    sampling entirely while the cursor stays inside the same element.
///
/// All methods must be called on the main thread; the tap's run-loop source
/// lives on the main run loop, so its callback arrives there too.
final class CursorMonitor {
    /// Called with the cursor position in global top-left (accessibility)
    /// coordinates.
    var onSample: ((CGPoint) -> Void)?

    /// Minimum time between samples. Settable while running; new value
    /// applies from the next event.
    var sampleInterval: CFTimeInterval = 1.0 / 60.0

    /// No Lag mode: sample on every mouse event instead of at the polling
    /// rate. The distance gate and skip region still apply, and the resolver
    /// coalesces to one in-flight query, so cost stays bounded.
    var unthrottled = false

    /// Called with every raw mouse position, before any gating — feeds the
    /// visual cursor indicator. Left nil (zero cost) unless the indicator
    /// is on.
    var onRawMove: ((CGPoint) -> Void)?

    /// Fires once each time the cursor touches an outer screen edge.
    var onScreenEdge: (() -> Void)?
    var screenEdgesEnabled = false
    private var atScreenEdge = false

    /// While the cursor stays inside this rect no new samples are emitted.
    /// Set by the pipeline after each resolution.
    var skipRegion: CGRect?

    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?
    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var globalScrollMonitor: Any?
    private var trailingTimer: Timer?

    private var lastSampleTime: CFTimeInterval = 0
    private var lastPoint: CGPoint?

    private let minDistance: CGFloat = 2

    var isRunning: Bool { eventTap != nil || globalMoveMonitor != nil }

    func start() {
        guard !isRunning else { return }
        if !startEventTap() {
            startNSEventMonitors()
        }
    }

    func stop() {
        if let tapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapRunLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        tapRunLoopSource = nil

        for monitor in [globalMoveMonitor, localMoveMonitor, globalScrollMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        globalMoveMonitor = nil
        localMoveMonitor = nil
        globalScrollMonitor = nil
        cancelTrailingSample()
        skipRegion = nil
        lastPoint = nil
        lastSampleTime = 0
    }

    // MARK: - Event sources

    private func startEventTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    let monitor = Unmanaged<CursorMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                    monitor.handleTapEvent(type: type)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        tapRunLoopSource = source
        return true
    }

    private func handleTapEvent(type: CGEventType) {
        switch type {
        case .mouseMoved, .leftMouseDragged:
            handleMove()
        case .scrollWheel:
            handleScroll()
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disables slow taps; re-enable and keep going.
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        default:
            break
        }
    }

    private func startNSEventMonitors() {
        globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.handleMove()
        }
        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handleMove()
            return event
        }
        // Scrolling changes what's under a stationary cursor, so it must
        // invalidate the skip region and trigger a fresh sample.
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] _ in
            self?.handleScroll()
        }
    }

    private func handleMove() {
        if let onRawMove, let point = currentPoint() {
            onRawMove(point)
        }
        let now = CACurrentMediaTime()
        let elapsed = now - lastSampleTime
        if !unthrottled, elapsed < sampleInterval {
            // Throttled — but if this turns out to be the last event of the
            // gesture, the resting position still needs to be resolved.
            scheduleTrailingSample(after: sampleInterval - elapsed)
            return
        }
        sample(now: now)
    }

    private func handleScroll() {
        skipRegion = nil
        handleMove()
    }

    private func sample(now: CFTimeInterval) {
        cancelTrailingSample()
        guard let point = currentPoint() else { return }

        if screenEdgesEnabled {
            checkScreenEdge(point)
        }

        if let lastPoint, hypot(point.x - lastPoint.x, point.y - lastPoint.y) < minDistance {
            return
        }
        if let skipRegion, skipRegion.contains(point) {
            lastPoint = point
            return
        }

        lastSampleTime = now
        lastPoint = point
        onSample?(point)
    }

    private func scheduleTrailingSample(after delay: TimeInterval) {
        guard trailingTimer == nil else { return }
        let timer = Timer(timeInterval: max(delay, 0.005), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.trailingTimer = nil
            self.sample(now: CACurrentMediaTime())
        }
        // .common keeps the trailing sample firing during menu and drag
        // tracking, when the default run loop mode is suspended.
        RunLoop.main.add(timer, forMode: .common)
        trailingTimer = timer
    }

    private func cancelTrailingSample() {
        trailingTimer?.invalidate()
        trailingTimer = nil
    }

    /// Current cursor position in global top-left coordinates — the space
    /// both `AXUIElementCopyElementAtPosition` and AX element frames use.
    private func currentPoint() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    // MARK: - Screen edges

    /// Bumps once when the cursor reaches an outer edge of the display
    /// arrangement (edges shared with another display don't count — the
    /// cursor passes through those). Pure math, no accessibility calls.
    private func checkScreenEdge(_ point: CGPoint) {
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(8, &displays, &count) == .success, count > 0 else { return }
        let bounds = (0..<Int(count)).map { CGDisplayBounds(displays[$0]) }

        guard let screen = bounds.first(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) else { return }

        let others = bounds.filter { $0 != screen }
        let touching =
            (point.x <= screen.minX + 1 && !others.contains { abs($0.maxX - screen.minX) < 2 && $0.minY < point.y && point.y < $0.maxY })
            || (point.x >= screen.maxX - 2 && !others.contains { abs($0.minX - screen.maxX) < 2 && $0.minY < point.y && point.y < $0.maxY })
            || (point.y <= screen.minY + 1 && !others.contains { abs($0.maxY - screen.minY) < 2 && $0.minX < point.x && point.x < $0.maxX })
            || (point.y >= screen.maxY - 2 && !others.contains { abs($0.minY - screen.maxY) < 2 && $0.minX < point.x && point.x < $0.maxX })

        if touching {
            if !atScreenEdge {
                atScreenEdge = true
                onScreenEdge?()
            }
        } else if atScreenEdge,
                  point.x > screen.minX + 8, point.x < screen.maxX - 9,
                  point.y > screen.minY + 8, point.y < screen.maxY - 9 {
            atScreenEdge = false
        }
    }
}
