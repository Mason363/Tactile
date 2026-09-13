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
    /// Actuator, actuation ID, level flags, strength scale, and duration scale
    /// (0 leaves either scale at the waveform's own value).
    fileprivate typealias ActuateFunc = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32
    fileprivate typealias CreateActuationFunc = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
    fileprivate typealias PlayActuationFunc = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32
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
    private let playActuation: PlayActuationFunc?
    private let createActuation: CreateActuationFunc?

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
        // Parametric waveforms, described the way the trackpad's own clicks
        // are. They are what lets music be played as sound rather than as
        // clicks; without them music falls back to the stock clicks.
        playActuation = dlsym(handle, "MTActuationActuate").map { unsafeBitCast($0, to: PlayActuationFunc.self) }
        createActuation = dlsym(handle, "MTActuationCreateFromDictionary").map { unsafeBitCast($0, to: CreateActuationFunc.self) }

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
        // The phone is not an actuator; reaching this engine anyway means
        // the pipeline already degraded (phone gone, enhanced haptics on),
        // so behave like "all".
        case .iphone: matched = pool
        }
        return (matched.isEmpty ? pool : matched).map(\.actuator)
    }

    func tick(_ pattern: FeedbackPattern) {
        for actuator in targetActuators {
            _ = actuate(actuator, pattern.actuationID, 0, 0, 0)
        }
    }

    // MARK: - Pulses from any thread

    /// The current target's actuators, able to pulse from any thread: music
    /// haptics play from their own timing thread, where a main-thread hop
    /// would add jitter. Take a new one when the target changes; actuators
    /// are never closed, so a snapshot can't outlive its handles.
    nonisolated struct Pulser: @unchecked Sendable {
        fileprivate let actuators: [UnsafeMutableRawPointer]
        fileprivate let actuate: ActuateFunc
        fileprivate let play: PlayActuationFunc?
        fileprivate let create: CreateActuationFunc?

        /// Whether this pulser can play the music itself (it needs the
        /// parametric waveforms) rather than only discrete taps.
        var canVibrate: Bool { create != nil && play != nil }

        /// One segment of the trackpad playing the music: its partials
        /// sounded together as one waveform, at `level` 0...1 of full
        /// amplitude. The segment is a whole number of the lead partial's
        /// cycles, so sending them end to end runs without a seam.
        func chord(_ chord: Chord, level: Float) {
            guard let create, let play, level > 0, !chord.partials.isEmpty else { return }
            let milliseconds = Double(chord.lengthTicks) / 24
            let tones = chord.partials.map { partial in
                ["Type": "Sine", "Amplitude": Double(partial.amplitude), "DurationMS": milliseconds,
                 "DelayMS": 0.0, "FrequencykHz": Double(partial.hz) / 1000] as [String: Any]
            }
            let shape: [String: Any] = [
                // A silent Gaussian base: the driver plays tones only on one.
                "BaseWaveform": ["Type": "Gaussian", "Amplitude": 0.0, "DurationMS": milliseconds],
                "Tones": tones,
            ]
            guard let actuation = create(shape as CFDictionary, 0) else { return }
            let scale = SpeakerVoice.ceiling * min(level, 1)
            for actuator in actuators {
                _ = play(actuation, actuator, 0, scale, 0)
            }
            Unmanaged<AnyObject>.fromOpaque(actuation).release()
        }

        /// A music accent for the fallback path, when the parametric
        /// waveforms are missing (an old macOS): the stock strong click,
        /// scaled. `weight` is ignored here.
        func accent(strength: Float, weight: Float) {
            let scale = 0.35 + 0.95 * min(max(strength, 0), 1)
            for actuator in actuators {
                _ = actuate(actuator, 6, 0, scale, 0)
            }
        }
    }

    func makePulser() -> Pulser {
        Pulser(actuators: targetActuators, actuate: actuate, play: playActuation, create: createActuation)
    }

    // MARK: - Held tones

    /// Holds a note on the trackpad for as long as it runs: the motor sounds
    /// `hz`, with `level` shaping its loudness over time (0 is silence, 1 is
    /// full). This is a real tone, not a stream of taps, so it feels and
    /// sounds like one unbroken vibration. Falls back to the old tap loop
    /// where the parametric waveforms are missing.
    func startTone(hz: Double, level: @escaping @Sendable (TimeInterval) -> Double,
                   fallback: FeedbackPattern, fallbackGaps: [TimeInterval]) {
        let pulser = makePulser()
        if pulser.canVibrate {
            toneLoop.start(pulser: pulser, hz: hz, level: level)
        } else {
            let microseconds = fallbackGaps.map { UInt32(max($0, 0.004) * 1_000_000) }
            toneLoop.startTaps(actuators: targetActuators, actuate: actuate,
                               id: fallback.actuationID, gaps: microseconds)
        }
    }

    func stopTone() {
        toneLoop.stop()
    }

    /// Sounds a single note and lets it finish, for one step of a waveform.
    /// Independent of the held tone, so a waveform never cancels a hover
    /// vibration or the other way round.
    func playTone(hz: Double, level: Double, milliseconds: Double) {
        let pulser = makePulser()
        guard pulser.canVibrate else {
            tick(level > 0.75 ? .levelChange : level > 0.4 ? .generic : .alignment)
            return
        }
        ToneLoop.playOnce(pulser: pulser, hz: hz, level: level, seconds: milliseconds / 1000)
    }

    private let toneLoop = ToneLoop()

    /// The tone thread. Segments are whole cycles on the firmware's tick
    /// grid, sent end to end, which is what makes a held note sound like one
    /// note instead of a rattle. Generation counting makes stop/start
    /// race-free: the thread re-checks before every segment and exits the
    /// moment it is stale.
    private final class ToneLoop {
        private let lock = NSLock()
        private var generation = 0

        func start(pulser: Pulser, hz: Double, level: @escaping @Sendable (TimeInterval) -> Double) {
            let mine = bump()
            let thread = Thread { [weak self] in
                Self.run(hz: hz, pulser: pulser, level: level) { self?.isCurrent(mine) ?? false }
            }
            thread.name = "com.masonchen.Tactile.tone"
            thread.qualityOfService = .userInteractive
            thread.stackSize = 1 << 16
            thread.start()
        }

        /// One note that stops itself, with a short fade so it ends cleanly
        /// rather than cutting off.
        static func playOnce(pulser: Pulser, hz: Double, level: Double, seconds: TimeInterval) {
            let thread = Thread {
                let fade = min(0.03, seconds / 3)
                Self.run(hz: hz, pulser: pulser, level: { elapsed in
                    guard elapsed < seconds else { return -1 }
                    let remaining = seconds - elapsed
                    return remaining < fade ? level * (remaining / fade) : level
                }, keepGoing: { true })
            }
            thread.name = "com.masonchen.Tactile.note"
            thread.qualityOfService = .userInteractive
            thread.stackSize = 1 << 16
            thread.start()
        }

        /// The old behaviour, for trackpads whose driver has no parametric
        /// waveforms: taps fast enough to approximate a buzz.
        func startTaps(actuators: [UnsafeMutableRawPointer], actuate: @escaping ActuateFunc,
                       id: Int32, gaps: [UInt32]) {
            let mine = bump()
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

        /// Sends segments back to back until the level goes negative or the
        /// caller says to stop. A level of zero stays silent without ending
        /// the note, so a rhythm can pulse without tearing down the thread.
        private static func run(hz: Double, pulser: Pulser,
                                level: @Sendable (TimeInterval) -> Double,
                                keepGoing: () -> Bool) {
            let ticks = SpeakerVoice.segmentTicks(forHz: hz)
            let chord = Chord(partials: [Chord.Partial(hz: Float(hz), amplitude: 1)],
                              lengthTicks: ticks, loudness: 1)
            let segment = HostTime.ticks(chord.seconds)
            let start = mach_absolute_time()
            var next = start
            while keepGoing() {
                let elapsed = HostTime.seconds(next &- start)
                let now = level(elapsed)
                guard now >= 0 else { return }
                if now > 0.004 { pulser.chord(chord, level: Float(now)) }
                next &+= segment
                if next > mach_absolute_time() { mach_wait_until(next) } else { next = mach_absolute_time() }
            }
        }

        func stop() {
            _ = bump()
        }

        private func bump() -> Int {
            lock.lock()
            defer { lock.unlock() }
            generation += 1
            return generation
        }

        private func isCurrent(_ mine: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return mine == generation
        }
    }

    deinit {
        toneLoop.stop()
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
