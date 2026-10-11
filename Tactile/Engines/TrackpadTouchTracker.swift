//
//  TrackpadTouchTracker.swift
//  Tactile
//

import Foundation
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
@MainActor
final class TrackpadTouchTracker {
    /// How long after the last contact frame the trackpad still counts as
    /// in use: long enough to bridge a finger lifting at the end of a move,
    /// short enough that a mouse takes over promptly.
    static let grace: CFTimeInterval = 0.3

    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias RegisterFunc = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    private typealias DeviceFunc = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias StartFunc = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void

    private let register: RegisterFunc
    private let unregister: RegisterFunc
    private let start: StartFunc
    private let stop: DeviceFunc

    /// Retained for the life of the app, like the actuators they belong to.
    private var handles: [UnsafeMutableRawPointer] = []
    private var running = false

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

    /// Watches one more haptic trackpad (already retained by the caller).
    func add(_ handle: UnsafeMutableRawPointer) {
        guard !handles.contains(handle) else { return }
        handles.append(handle)
        if running { begin(handle) }
    }

    /// Starts or stops listening for contact frames on every known device.
    func setRunning(_ on: Bool) {
        guard on != running else { return }
        running = on
        for handle in handles {
            if on {
                begin(handle)
            } else {
                unregister(handle, Self.callback)
                stop(handle)
            }
        }
    }

    private func begin(_ handle: UnsafeMutableRawPointer) {
        register(handle, Self.callback)
        start(handle, 0)
    }

    /// True once at least one trackpad is being listened to. Without it,
    /// "no finger" would mean "no idea", and haptics must not be silenced.
    var isReliable: Bool { running && !handles.isEmpty }

    /// Whether a finger touched the trackpad within the grace period.
    var isTouching: Bool { TouchClock.shared.age < Self.grace }
}

/// The time of the latest contact frame, written from the multitouch
/// thread and read from the main thread.
private final class TouchClock: @unchecked Sendable {
    static let shared = TouchClock()

    private let lock = NSLock()
    private var last: CFTimeInterval = -.infinity

    func touched() {
        lock.lock()
        last = CACurrentMediaTime()
        lock.unlock()
    }

    var age: CFTimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return CACurrentMediaTime() - last
    }
}
