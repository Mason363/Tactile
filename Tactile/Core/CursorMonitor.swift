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
/// Three gates keep the accessibility queries rare without adding felt lag:
/// 1. A time throttle caps sampling at the configured polling rate, with a
///    trailing-edge sample so the cursor's final resting position is always
///    resolved even when the last mouse event fell inside the throttle window.
/// 2. A small distance gate ignores sub-pixel jitter.
/// 3. A skip region — the frame of the last resolved element — short-circuits
///    sampling entirely while the cursor stays inside the same element.
///
/// All methods must be called on the main thread; NSEvent monitors deliver
/// their events there.
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

    /// While the cursor stays inside this rect no new samples are emitted.
    /// Set by the pipeline after each resolution.
    var skipRegion: CGRect?

    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var globalScrollMonitor: Any?
    private var trailingTimer: Timer?

    private var lastSampleTime: CFTimeInterval = 0
    private var lastPoint: CGPoint?

    private let minDistance: CGFloat = 2

    var isRunning: Bool { globalMoveMonitor != nil }

    func start() {
        guard globalMoveMonitor == nil else { return }
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

    func stop() {
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

    private func handleMove() {
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
}
