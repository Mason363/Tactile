//
//  TrackpadTouchTracker.swift
//  Tactile
//

import AppKit
import IOKit
import QuartzCore

/// Remembers when a finger last touched a haptic trackpad, so haptics can
/// stand down while the cursor is being moved by an external mouse instead.
///
/// Mouse events carry no device identity, but a trackpad only moves the
/// cursor while a finger is on it, and a mouse never produces contact
/// frames. The frames come from the same private MultitouchSupport
/// framework the actuator uses, resolved at runtime; if it can't be
/// resolved, `init` returns nil and haptics are simply never suppressed.
///
/// Devices are handed over by `ActuatorHapticEngine`, which already knows
/// which multitouch devices have an actuator, so a Magic Mouse's touch
/// surface is never watched. Nothing is started until `setRunning(true)`.
///
/// Device objects stop reporting after the Mac sleeps or a trackpad
/// reconnects, so while running the tracker asks for a fresh scan on wake
/// and whenever a multitouch device attaches.
@MainActor
final class TrackpadTouchTracker {
    /// How long after the last contact frame the trackpad still counts as
    /// in use: long enough to bridge a finger lifting at the end of a move,
    /// short enough that a mouse takes over promptly.
    static let grace: CFTimeInterval = 0.3

    /// How long a woken or newly attached trackpad gets to settle before
    /// the framework is asked to list it.
    private static let settle: TimeInterval = 1.5

    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias RegisterFunc = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    private typealias DeviceFunc = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias StartFunc = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void

    private let register: RegisterFunc
    private let unregister: RegisterFunc
    private let start: StartFunc
    private let stop: DeviceFunc

    /// The framework's objects for the haptic trackpads, from the latest scan.
    private var devices: [AnyObject] = []
    private var running = false

    /// When listening last (re)started. Only a contact frame after this
    /// proves frames are reaching us; `.infinity` while nothing is trusted.
    private var armedAt: CFTimeInterval = .infinity

    /// Asks `ActuatorHapticEngine` to scan again; it answers with `watch(_:)`.
    var rescan: (() -> Void)?

    private var wakeObserver: NSObjectProtocol?
    private var attachPort: IONotificationPortRef?
    private var attachIterator: io_iterator_t = 0
    private var pendingRescan: DispatchWorkItem?

    private static let callback: Callback = { _, _, touchCount, _, _ in
        if touchCount > 0 { TouchClock.shared.touched() }
        return 0
    }

    init?() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let framework = dlopen(path, RTLD_NOW),
              let registerSym = dlsym(framework, "MTRegisterContactFrameCallback"),
              let unregisterSym = dlsym(framework, "MTUnregisterContactFrameCallback"),
              let startSym = dlsym(framework, "MTDeviceStart"),
              let stopSym = dlsym(framework, "MTDeviceStop")
        else { return nil }
        register = unsafeBitCast(registerSym, to: RegisterFunc.self)
        unregister = unsafeBitCast(unregisterSym, to: RegisterFunc.self)
        start = unsafeBitCast(startSym, to: StartFunc.self)
        stop = unsafeBitCast(stopSym, to: DeviceFunc.self)
    }

    /// Replaces the watched trackpads with the latest scan. Every scan
    /// hands over fresh objects, so listening restarts on all of them.
    func watch(_ found: [AnyObject]) {
        if running { devices.forEach(end) }
        devices = found
        if running { devices.forEach(begin) }
    }

    /// Starts or stops listening for contact frames on every known device.
    func setRunning(_ on: Bool) {
        guard on != running else { return }
        running = on
        if on {
            armedAt = CACurrentMediaTime()
            devices.forEach(begin)
            observeDeviceChanges()
        } else {
            armedAt = .infinity
            devices.forEach(end)
            stopObservingDeviceChanges()
        }
    }

    private func begin(_ device: AnyObject) {
        let handle = Unmanaged.passUnretained(device).toOpaque()
        register(handle, Self.callback)
        start(handle, 0)
    }

    private func end(_ device: AnyObject) {
        let handle = Unmanaged.passUnretained(device).toOpaque()
        unregister(handle, Self.callback)
        stop(handle)
    }

    /// True once a finger has been seen since listening last started.
    /// Until then "no finger" could just as well mean "no frames" (a
    /// trackpad still waking, a framework change), and haptics must not
    /// be silenced on a guess.
    var isReliable: Bool { running && !devices.isEmpty && TouchClock.shared.last > armedAt }

    /// Whether a finger touched the trackpad within the grace period.
    var isTouching: Bool { CACurrentMediaTime() - TouchClock.shared.last < Self.grace }

    // MARK: - Wake and attach

    private func observeDeviceChanges() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The old objects may have gone quiet during sleep.
                self.armedAt = .infinity
                self.scheduleRescan()
            }
        }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, IOServiceMatching("AppleMultitouchDevice"),
            { refcon, iterator in
                TrackpadTouchTracker.drain(iterator)
                guard let refcon else { return }
                let tracker = Unmanaged<TrackpadTouchTracker>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { tracker.scheduleRescan() }
            },
            Unmanaged.passUnretained(self).toOpaque(), &iterator
        )
        guard result == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            return
        }
        // Draining arms the notification; the devices already present
        // came with the last scan.
        Self.drain(iterator)
        attachPort = port
        attachIterator = iterator
    }

    private func stopObservingDeviceChanges() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        if attachIterator != 0 { IOObjectRelease(attachIterator) }
        attachIterator = 0
        if let attachPort { IONotificationPortDestroy(attachPort) }
        attachPort = nil
        pendingRescan?.cancel()
        pendingRescan = nil
    }

    /// One scan per burst of notifications, after the devices settle.
    private func scheduleRescan() {
        pendingRescan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                self.rescan?()
                if self.armedAt == .infinity { self.armedAt = CACurrentMediaTime() }
            }
        }
        pendingRescan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    private nonisolated static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }
}

/// The time of the latest contact frame, written from the multitouch
/// thread and read from the main thread.
private nonisolated final class TouchClock: @unchecked Sendable {
    static let shared = TouchClock()

    private let lock = NSLock()
    private var latest: CFTimeInterval = -.infinity

    func touched() {
        lock.lock()
        latest = CACurrentMediaTime()
        lock.unlock()
    }

    var last: CFTimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}
