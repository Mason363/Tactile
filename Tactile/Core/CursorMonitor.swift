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
/// Three gates keep the accessibility queries rare:
/// 1. A time throttle caps sampling at ~25 Hz.
/// 2. A distance gate ignores sub-5px jitters.
/// 3. A skip region — the frame of the last resolved element — short-circuits
///    sampling entirely while the cursor stays inside the same element.
///
/// All methods must be called on the main thread; NSEvent monitors deliver
/// their events there.
final class CursorMonitor {
    /// Called with the cursor position in global top-left (accessibility)
    /// coordinates.
    var onSample: ((CGPoint) -> Void)?

    /// While the cursor stays inside this rect no new samples are emitted.
    /// Set by the pipeline after each resolution.
    var skipRegion: CGRect?

    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var globalScrollMonitor: Any?

    private var lastSampleTime: CFTimeInterval = 0
    private var lastPoint: CGPoint?

    private let minInterval: CFTimeInterval = 0.04
    private let minDistance: CGFloat = 5

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
        skipRegion = nil
        lastPoint = nil
        lastSampleTime = 0
    }

    private func handleMove() {
        let now = CACurrentMediaTime()
        guard now - lastSampleTime >= minInterval else { return }
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

    private func handleScroll() {
        skipRegion = nil
        let now = CACurrentMediaTime()
        guard now - lastSampleTime >= minInterval else { return }
        guard let point = currentPoint() else { return }
        lastSampleTime = now
        lastPoint = point
        onSample?(point)
    }

    /// Current cursor position in global top-left coordinates — the space
    /// both `AXUIElementCopyElementAtPosition` and AX element frames use.
    private func currentPoint() -> CGPoint? {
        CGEvent(source: nil)?.location
    }
}
