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

    private let actuator: UnsafeMutableRawPointer
    private let actuate: ActuateFunc
    private let closeActuator: OpenCloseFunc

    private init?() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else { return nil }

        guard let createSym = dlsym(handle, "MTActuatorCreateFromDeviceID"),
              let openSym = dlsym(handle, "MTActuatorOpen"),
              let closeSym = dlsym(handle, "MTActuatorClose"),
              let actuateSym = dlsym(handle, "MTActuatorActuate")
        else { return nil }

        let create = unsafeBitCast(createSym, to: CreateFunc.self)
        let open = unsafeBitCast(openSym, to: OpenCloseFunc.self)
        self.closeActuator = unsafeBitCast(closeSym, to: OpenCloseFunc.self)
        self.actuate = unsafeBitCast(actuateSym, to: ActuateFunc.self)

        for deviceID in Self.candidateDeviceIDs(handle: handle) {
            guard let actuator = create(deviceID) else { continue }
            if open(actuator) == 0 {
                self.actuator = actuator
                return
            }
            Unmanaged<AnyObject>.fromOpaque(actuator).release()
        }
        return nil
    }

    /// Device IDs worth trying, built-in trackpads first, legacy ID last.
    private static func candidateDeviceIDs(handle: UnsafeMutableRawPointer) -> [UInt64] {
        var builtIn: [UInt64] = []
        var external: [UInt64] = []

        if let listSym = dlsym(handle, "MTDeviceCreateList"),
           let idSym = dlsym(handle, "MTDeviceGetDeviceID") {
            let list = unsafeBitCast(listSym, to: DeviceListFunc.self)
            let getID = unsafeBitCast(idSym, to: DeviceIDFunc.self)
            let isBuiltIn = dlsym(handle, "MTDeviceIsBuiltIn").map {
                unsafeBitCast($0, to: DeviceBoolFunc.self)
            }

            if let devices = list()?.takeRetainedValue() as? [AnyObject] {
                for device in devices {
                    let pointer = Unmanaged.passUnretained(device).toOpaque()
                    var deviceID: UInt64 = 0
                    guard getID(pointer, &deviceID) == 0, deviceID != 0 else { continue }
                    if isBuiltIn?(pointer) ?? false {
                        builtIn.append(deviceID)
                    } else {
                        external.append(deviceID)
                    }
                }
            }
        }

        return builtIn + external + [legacyDeviceID]
    }

    func tick(_ pattern: FeedbackPattern) {
        _ = actuate(actuator, pattern.actuationID, 0, 0, 0)
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
        buzzer.start(actuator: actuator, actuate: actuate, id: pattern.actuationID, gaps: microseconds)
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

        func start(actuator: UnsafeMutableRawPointer, actuate: @escaping ActuateFunc, id: Int32, gaps: [UInt32]) {
            lock.lock()
            generation += 1
            let mine = generation
            lock.unlock()
            guard !gaps.isEmpty else { return }

            let thread = Thread { [weak self] in
                var step = 0
                while let self, self.isCurrent(mine) {
                    _ = actuate(actuator, id, 0, 0, 0)
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
        _ = closeActuator(actuator)
        Unmanaged<AnyObject>.fromOpaque(actuator).release()
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
