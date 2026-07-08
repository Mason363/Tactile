//
//  ActuatorHapticEngine.swift
//  Tactile
//

import AppKit

/// Enhanced haptics: drives the trackpad actuator directly through the
/// private MultitouchSupport framework (the approach HapticPad and HapticKey
/// use). Unlike the public API, actuation IDs map to physically distinct
/// strengths, so Light/Standard/Firm become real intensity levels.
///
/// Every haptic trackpad gets its own actuator, built-in and Magic Trackpad
/// alike, and `target` picks which of them feel each tick. The public API
/// offers no such routing, so device choice always goes through here.
///
/// Everything is resolved at runtime with dlopen/dlsym and probed once; if
/// the framework, symbols, or actuator are missing - or break in a macOS
/// update - `shared` is nil and callers fall back to the public engine.
/// Nothing is linked at build time.
@MainActor
final class ActuatorHapticEngine: FeedbackEngine {
    /// Actuator device ID on pre-Apple Silicon Macs, kept as a fallback.
    /// Modern hardware uses different IDs, so devices are enumerated first.
    private static let legacyDeviceID: UInt64 = 0x200000001

    private typealias CreateFunc = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    private typealias OpenCloseFunc = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias ActuateFunc = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32
    private typealias DeviceListFunc = @convention(c) () -> Unmanaged<CFArray>?
    private typealias DeviceIDFunc = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias DeviceBoolFunc = @convention(c) (UnsafeMutableRawPointer) -> Bool

    static let shared: ActuatorHapticEngine? = ActuatorHapticEngine()

    /// True when a Force Touch (haptic) trackpad is present. Opening an
    /// actuator only succeeds on hardware that can produce haptics, so this
    /// doubles as the capability check for feedback in general: both the
    /// enhanced actuator and the public engine need such a trackpad, and
    /// without one Tactile has nothing to tap.
    static var hasHapticTrackpad: Bool { shared != nil }

    /// One opened actuator per haptic trackpad. Actuators are never closed
    /// while the app runs - the buzz thread may still hold one - so a
    /// device that disconnects is only marked absent.
    private struct Device {
        let id: UInt64
        let isBuiltIn: Bool
        let actuator: UnsafeMutableRawPointer
        var present: Bool
    }

    private var devices: [Device] = []

    /// Which trackpads feel the ticks. A choice whose device isn't
    /// connected degrades to every present device, never to silence.
    var target: HapticDeviceTarget = .all

    private let create: CreateFunc
    private let openActuator: OpenCloseFunc
    private let closeActuator: OpenCloseFunc
    private let actuate: ActuateFunc
    private let listDevices: DeviceListFunc?
    private let getDeviceID: DeviceIDFunc?
    private let deviceIsBuiltIn: DeviceBoolFunc?

    private init?() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else { return nil }

        guard let createSym = dlsym(handle, "MTActuatorCreateFromDeviceID"),
              let openSym = dlsym(handle, "MTActuatorOpen"),
              let closeSym = dlsym(handle, "MTActuatorClose"),
              let actuateSym = dlsym(handle, "MTActuatorActuate")
        else { return nil }

        create = unsafeBitCast(createSym, to: CreateFunc.self)
        openActuator = unsafeBitCast(openSym, to: OpenCloseFunc.self)
        closeActuator = unsafeBitCast(closeSym, to: OpenCloseFunc.self)
        actuate = unsafeBitCast(actuateSym, to: ActuateFunc.self)
        listDevices = dlsym(handle, "MTDeviceCreateList").map { unsafeBitCast($0, to: DeviceListFunc.self) }
        getDeviceID = dlsym(handle, "MTDeviceGetDeviceID").map { unsafeBitCast($0, to: DeviceIDFunc.self) }
        deviceIsBuiltIn = dlsym(handle, "MTDeviceIsBuiltIn").map { unsafeBitCast($0, to: DeviceBoolFunc.self) }

        refreshDevices()
        if devices.isEmpty, let actuator = create(Self.legacyDeviceID) {
            if openActuator(actuator) == 0 {
                devices.append(Device(id: Self.legacyDeviceID, isBuiltIn: true, actuator: actuator, present: true))
            } else {
                Unmanaged<AnyObject>.fromOpaque(actuator).release()
            }
        }
        if devices.isEmpty { return nil }
    }

    // MARK: - Devices

    /// Re-scans connected trackpads: newly connected ones get an actuator
    /// opened, missing ones are marked absent. Existing actuators are left
    /// open so an in-flight buzz can never touch a freed handle; actuating
    /// an absent device is a harmless error return.
    func refreshDevices() {
        guard let listDevices, let getDeviceID,
              let scanned = listDevices()?.takeRetainedValue() as? [AnyObject]
        else { return }

        var found: [(id: UInt64, isBuiltIn: Bool)] = []
        for device in scanned {
            let pointer = Unmanaged.passUnretained(device).toOpaque()
            var deviceID: UInt64 = 0
            guard getDeviceID(pointer, &deviceID) == 0, deviceID != 0 else { continue }
            found.append((deviceID, deviceIsBuiltIn?(pointer) ?? false))
        }
        // An empty scan is a framework hiccup, not zero trackpads.
        guard !found.isEmpty else { return }

        let foundIDs = Set(found.map(\.id))
        for index in devices.indices {
            devices[index].present = foundIDs.contains(devices[index].id)
        }

        // Only devices whose actuator opens count: mice and other
        // multitouch hardware without a haptic motor fail here.
        let known = Set(devices.map(\.id))
        for candidate in found where !known.contains(candidate.id) {
            guard let actuator = create(candidate.id) else { continue }
            if openActuator(actuator) == 0 {
                devices.append(Device(id: candidate.id, isBuiltIn: candidate.isBuiltIn, actuator: actuator, present: true))
            } else {
                Unmanaged<AnyObject>.fromOpaque(actuator).release()
            }
        }
    }

    /// True when more than one haptic trackpad is connected right now,
    /// the only time a destination choice means anything.
    var hasMultipleDevices: Bool { presentDevices.count > 1 }

    var hasBuiltInDevice: Bool { presentDevices.contains(where: \.isBuiltIn) }

    var hasExternalDevice: Bool { presentDevices.contains { !$0.isBuiltIn } }

    private var presentDevices: [Device] { devices.filter(\.present) }

    /// The actuators the current target maps to, with two safety nets: an
    /// all-absent device list falls back to every opened actuator, and a
    /// target with no matching device falls back to the whole pool.
    private var targetActuators: [UnsafeMutableRawPointer] {
        let pool = presentDevices.isEmpty ? devices : presentDevices
        let matched: [Device]
        switch target {
        case .all: matched = pool
        case .builtIn: matched = pool.filter(\.isBuiltIn)
        case .external: matched = pool.filter { !$0.isBuiltIn }
        }
        return (matched.isEmpty ? pool : matched).map(\.actuator)
    }

    func tick(_ pattern: FeedbackPattern) {
        for actuator in targetActuators {
            _ = actuate(actuator, pattern.actuationID, 0, 0, 0)
        }
    }

    // MARK: - Continuous buzz

    /// Runs the actuator fast enough that individual pulses blur into a
    /// continuous vibration - main-thread timers can't hold a steady beat
    /// below ~30ms, so the pulse loop gets its own thread with a hard floor
    /// of 4ms (250 pulses/sec). Power and thermals stay inside the driver's
    /// own limits: each call plays the same predefined waveform the system
    /// uses for its haptics, just scheduled back-to-back.
    func startBuzz(_ pattern: FeedbackPattern, gaps: [TimeInterval]) {
        let microseconds = gaps.map { UInt32(max($0, 0.004) * 1_000_000) }
        buzzer.start(actuators: targetActuators, actuate: actuate, id: pattern.actuationID, gaps: microseconds)
    }

    func stopBuzz() {
        buzzer.stop()
    }

    private let buzzer = Buzzer()

    /// The pulse loop. Generation counting makes stop/start race-free: the
    /// thread re-checks the generation before every pulse and exits the
    /// moment it's stale.
    private final class Buzzer {
        private let lock = NSLock()
        private var generation = 0

        func start(actuators: [UnsafeMutableRawPointer], actuate: @escaping ActuateFunc, id: Int32, gaps: [UInt32]) {
            lock.lock()
            generation += 1
            let mine = generation
            lock.unlock()
            guard !gaps.isEmpty, !actuators.isEmpty else { return }

            let thread = Thread { [weak self] in
                var step = 0
                while let self, self.isCurrent(mine) {
                    for actuator in actuators {
                        _ = actuate(actuator, id, 0, 0, 0)
                    }
                    usleep(gaps[step % gaps.count])
                    step += 1
                }
            }
            thread.name = "com.masonchen.Tactile.buzz"
            thread.qualityOfService = .userInteractive
            thread.stackSize = 1 << 16
            thread.start()
        }

        func stop() {
            lock.lock()
            generation += 1
            lock.unlock()
        }

        private func isCurrent(_ mine: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return mine == generation
        }
    }

    deinit {
        buzzer.stop()
        for device in devices {
            _ = closeActuator(device.actuator)
            Unmanaged<AnyObject>.fromOpaque(device.actuator).release()
        }
    }
}

private extension FeedbackPattern {
    /// Known actuation IDs by strength: 3 is weak, 4 is medium, 6 is strong.
    var actuationID: Int32 {
        switch self {
        case .alignment: return 3
        case .generic: return 4
        case .levelChange: return 6
        }
    }
}
