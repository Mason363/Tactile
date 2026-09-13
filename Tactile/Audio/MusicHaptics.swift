//
//  MusicHaptics.swift
//  Tactile
//

import AppKit
import Combine
import os

// MARK: - Output

/// Where the music is felt: the same routing as the feedback pipeline (the
/// Coast phone, the chosen trackpads through the actuator, or the public
/// engine), callable from any thread.
nonisolated struct HapticPulser: Sendable {
    enum Route: Sendable {
        case phone
        case actuator(ActuatorHapticEngine.Pulser)
        case system
        #if DEBUG
        /// Tests: every pulse goes to a closure instead of a device.
        /// `continuous` stands in for a vibrating trackpad (true) or a
        /// tapping device like the phone (false).
        case recorder(continuous: Bool, @Sendable (PulseScheduler.Item.Kind) -> Void)
        #endif
    }

    let route: Route

    /// Whether this route vibrates continuously (the trackpad actuator with
    /// its parametric waveforms) rather than tapping. The phone and the
    /// public engine tap, so music reaches them as accents instead.
    var canVibrate: Bool {
        if case .actuator(let pulser) = route { return pulser.canVibrate }
        #if DEBUG
        if case .recorder(let continuous, _) = route { return continuous }
        #endif
        return false
    }

    func play(_ kind: PulseScheduler.Item.Kind) {
        #if DEBUG
        if case .recorder(_, let record) = route {
            record(kind)
            return
        }
        #endif
        switch kind {
        case .accent(let strength, let weight):
            accent(strength: strength, weight: weight)
        case .vibration(let level, let chord):
            if case .actuator(let pulser) = route { pulser.chord(chord, level: level) }
        }
    }

    private func accent(strength: Float, weight: Float) {
        switch route {
        case .actuator(let pulser):
            pulser.accent(strength: strength, weight: weight)
        case .phone:
            // The phone plays exact intensities; heavy accents feel rounder.
            let intensity = 0.3 + 0.7 * Double(strength)
            let sharpness = 0.75 - 0.55 * Double(weight)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    PhoneHapticEngine.shared.pulse(intensity: intensity, sharpness: sharpness)
                }
            }
        case .system:
            let pattern: NSHapticFeedbackManager.FeedbackPattern = strength > 0.66 ? .levelChange : strength > 0.33 ? .generic : .alignment
            DispatchQueue.main.async {
                NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
            }
        #if DEBUG
        case .recorder:
            break
        #endif
        }
    }
}

extension HapticPulser {
    /// The route the feedback pipeline takes for these settings.
    @MainActor
    static func current(device: HapticDeviceTarget, enhanced: Bool) -> HapticPulser {
        if device == .iphone, PhoneHapticEngine.shared.isAvailable {
            return HapticPulser(route: .phone)
        }
        if let actuator = ActuatorHapticEngine.shared, enhanced || device.isTrackpadSpecific {
            return HapticPulser(route: .actuator(actuator.makePulser()))
        }
        return HapticPulser(route: .system)
    }
}

// MARK: - Audio queue

/// The audio-queue half of music haptics: analyzes what plays, times each
/// vibration segment to land with its sound, and keeps them out of the
/// way. Settings and gate state arrive from the main thread through
/// a lock; pulses play on the scheduler's own thread.
nonisolated final class MusicListener: @unchecked Sendable {
    struct Settings: Sendable {
        var intensity: Float = 0.6
        var texture: Float = 0.5
        var pauseWhileNavigating = false
        var pauseDuringCalls = true
        /// Seconds from the tap hearing a sample to the listener hearing
        /// it: Bluetooth headphones play audio well after the tap hears it.
        var latency: TimeInterval = 0
        var pulser: HapticPulser?
    }

    /// Why music is heard but not played right now.
    enum HeldBack: Sendable {
        case cursor
        case call
    }

    struct Report: Sendable {
        /// How much music is being felt right now, 0...1.
        var level: Float
        var isMusic: Bool
        /// Sound that reads as talk, which stays still.
        var isTalk: Bool
        var isSilent: Bool
        var heldBack: HeldBack?
    }

    /// Main thread, about a dozen times a second while audio flows.
    var onReport: (@MainActor (Report) -> Void)?

    private struct Gates {
        var settings = Settings()
        var cursorQuietUntil: CFTimeInterval = 0
        var callActive = false
        var lastInterfaceTap: CFTimeInterval = 0
        var resetRequested = false
        var heldBack: HeldBack?
        var heldBackAt: CFTimeInterval = 0
        var played = 0
    }

    private static let log = Logger(subsystem: "com.masonchen.Tactile", category: "music")

    private let gates = OSAllocatedUnfairLock(initialState: Gates())
    private let scheduler = PulseScheduler()

    // Tap queue.
    private var analyzer: MusicAnalyzer?
    /// Hears the music as partials the trackpad can play.
    private var speaker: SpeakerVoice?
    /// Play time of the next segment to schedule.
    private var nextVibration: UInt64 = 0
    /// Recent chords by play time, so each segment plays the sound that
    /// belongs to the moment it lands on.
    private var chords: [(time: UInt64, chord: Chord)] = []
    private var accents = 0
    private var segments = 0
    private var lastReport: CFTimeInterval = 0
    private var lastLog: CFTimeInterval = 0

    // MARK: Main thread

    func update(_ settings: Settings) {
        gates.withLock { $0.settings = settings }
    }

    /// The tap is starting: bring up the thread pulses play on.
    func start() {
        let gates = self.gates
        scheduler.start { item in
            // The gates are checked as each pulse plays, after any delay.
            let pulser = gates.withLock { state -> HapticPulser? in
                let now = CACurrentMediaTime()
                if state.settings.pauseWhileNavigating, now < state.cursorQuietUntil {
                    state.heldBack = .cursor
                    state.heldBackAt = now
                    return nil
                }
                if state.settings.pauseDuringCalls, state.callActive {
                    state.heldBack = .call
                    state.heldBackAt = now
                    return nil
                }
                // Never on top of an interface tick: it must stay
                // unmistakable.
                guard now - state.lastInterfaceTap > 0.12 else { return nil }
                state.heldBack = nil
                state.played += 1
                return state.settings.pulser
            }
            pulser?.play(item.kind)
        }
    }

    func stop() {
        scheduler.stop()
    }

    /// The cursor is in use: interface ticks own the trackpad for a moment.
    func cursorMoved() {
        let until = CACurrentMediaTime() + 0.7
        gates.withLock { $0.cursorQuietUntil = until }
    }

    func setCallActive(_ active: Bool) {
        gates.withLock { $0.callActive = active }
    }

    /// An interface tick just played.
    func interfaceTapped() {
        let now = CACurrentMediaTime()
        gates.withLock { $0.lastInterfaceTap = now }
    }

    /// A new stream is starting: forget the last one's levels.
    func requestReset() {
        gates.withLock { $0.resetRequested = true }
    }

    // MARK: Tap queue

    /// `hostTime` is when the tap heard the first of these samples.
    func process(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double, hostTime: UInt64) {
        let (settings, reset) = gates.withLock { state -> (Settings, Bool) in
            defer { state.resetRequested = false }
            return (state.settings, state.resetRequested)
        }
        if analyzer?.sampleRate != sampleRate {
            analyzer = MusicAnalyzer(sampleRate: sampleRate)
            speaker = SpeakerVoice(sampleRate: sampleRate)
            nextVibration = 0
            chords.removeAll(keepingCapacity: true)
        } else if reset {
            analyzer?.reset()
            speaker?.reset()
            nextVibration = 0
            chords.removeAll(keepingCapacity: true)
        }
        guard let analyzer else { return }

        let now = mach_absolute_time()
        /// When the listener hears the sample at `frame`, an offset from
        /// these samples.
        func heard(_ frame: Int) -> UInt64 {
            let seconds = Double(frame) / sampleRate + settings.latency
            return seconds >= 0 ? hostTime &+ HostTime.ticks(seconds) : hostTime &- min(hostTime, HostTime.ticks(-seconds))
        }
        let vibrates = settings.pulser?.canVibrate == true

        // What the trackpad will sound: the partials of the sound just
        // heard, held until the segments that land on it are scheduled.
        if vibrates, let speaker {
            speaker.push(samples, count: count)
            let tones = max(1, min(5, Int((settings.texture * 5).rounded(.up))))
            if let chord = speaker.chord(tones: tones) {
                chords.append((time: heard(count), chord: chord))
                if chords.count > 48 { chords.removeFirst(chords.count - 48) }
            }
        }

        analyzer.process(samples, count: count, accent: { accent in
            // Vibrating plays the music itself, so hits need no pulse of
            // their own; the phone and the public engine tap instead.
            guard !vibrates else { return }
            let strength = tapStrength(accent, analyzer, settings)
            guard strength > 0 else { return }
            scheduler.schedule(PulseScheduler.Item(time: max(heard(accent.frame), now),
                                                   kind: .accent(strength: strength, weight: accent.weight)))
            accents += 1
        }, hop: { frame in
            guard vibrates else { return }
            // The vibration runs up to where the analysis has reached, one
            // segment at a time; each segment is a whole sine cycle count,
            // so they chain without a seam.
            let horizon = heard(frame)
            let maxBehind = HostTime.ticks(0.1)
            if nextVibration == 0 || nextVibration &+ maxBehind < horizon {
                nextVibration = horizon > maxBehind ? horizon &- maxBehind : now
            }
            while nextVibration <= horizon {
                let start = nextVibration
                guard let chord = chord(at: start) else { break }
                nextVibration &+= HostTime.ticks(chord.seconds)
                let level = playLevel(chord, analyzer, settings)
                guard level > 0.004, nextVibration >= now else { continue }
                scheduler.schedule(PulseScheduler.Item(time: max(start, now), kind: .vibration(level: level, chord: chord)))
                segments += 1
            }
        })
        report(analyzer)
    }

    /// The chord to play for a segment landing at `time`: the sound the
    /// music was making then, or the most recent one if the analysis has
    /// not caught up yet.
    private func chord(at time: UInt64) -> Chord? {
        var best: Chord?
        for entry in chords where entry.time <= time { best = entry.chord }
        return best ?? chords.last?.chord
    }

    /// How hard to drive the trackpad for this moment of the music: the
    /// chord's own loudness, scaled by the intensity setting, fading out in
    /// quiet passages and while the audio sounds like talk.
    private func playLevel(_ chord: Chord, _ analyzer: MusicAnalyzer, _ settings: Settings) -> Float {
        let presence = min(max((analyzer.musicness - 0.5) * 2, 0), 1)
        guard presence > 0 else { return 0 }
        // Gentle at the bottom of the slider, and at the top strong enough
        // to really play.
        let reach = 0.28 + 0.87 * powf(settings.intensity, 1.3)
        return min(chord.loudness * presence * reach, 1)
    }

    /// Tap strength for the phone and the public engine: every accent is
    /// felt, the song's biggest hits hardest, quiet passages lighter, scaled
    /// by the intensity; none while the audio sounds like talk.
    private func tapStrength(_ accent: MusicAnalyzer.Accent, _ analyzer: MusicAnalyzer, _ settings: Settings) -> Float {
        let presence = min(max((analyzer.musicness - 0.5) * 2, 0), 1)
        guard presence > 0 else { return 0 }
        let shaped = 0.3 + 0.7 * accent.strength
        let loudness = 0.55 + 0.45 * analyzer.energy
        return min(shaped * loudness * presence * (0.35 + 0.9 * settings.intensity), 1)
    }

    private func report(_ analyzer: MusicAnalyzer) {
        let now = CACurrentMediaTime()
        guard now - lastReport > 0.08 else { return }
        lastReport = now
        let (heldBack, played) = gates.withLock { state -> (HeldBack?, Int) in
            if state.heldBack != nil, now - state.heldBackAt > 1 { state.heldBack = nil }
            return (state.heldBack, state.played)
        }
        let isMusic = analyzer.musicness >= 0.5 && !analyzer.isSilent
        if now - lastLog > 2 {
            lastLog = now
            Self.log.debug("music feel musicness=\(analyzer.musicness, privacy: .public) energy=\(analyzer.energy, privacy: .public) gaps=\(analyzer.gapShare, privacy: .public) silent=\(analyzer.isSilent, privacy: .public) accents=\(self.accents, privacy: .public) segments=\(self.segments, privacy: .public) played=\(played, privacy: .public)")
        }
        let report = Report(level: isMusic ? analyzer.energy : 0, isMusic: isMusic,
                            isTalk: !isMusic && !analyzer.isSilent, isSilent: analyzer.isSilent, heldBack: heldBack)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onReport?(report) }
        }
    }
}

// MARK: - Coordinator

/// Feel the music: the trackpad plays whatever the Mac is playing, sounding
/// the music's own notes under the finger through its haptic motor.
/// Owns the audio tap and decides when it runs, and keeps the feel under
/// the music rather than on top of it:
/// - it listens only while something plays, and only with permission;
/// - it stays still while the audio sounds like talk;
/// - it steps aside while you use the cursor, so interface ticks stay
///   unmistakable, and during calls;
/// - it never plays on top of an interface tick.
@MainActor
final class MusicHaptics: ObservableObject {
    enum Status: Equatable {
        /// The feature is off, or Tactile is paused.
        case off
        /// Waiting for the system audio permission prompt.
        case needsPermission
        /// The permission was declined.
        case denied
        /// Nothing is playing.
        case waiting
        /// Something plays, but nothing is felt yet.
        case listening
        case feeling
        /// The audio sounds like talk, which stays still.
        case talk
        case pausedForCursor
        case pausedForCall
        /// The tap has heard only silence since it started while an app
        /// plays: the telltale of a missing permission (a paused video
        /// holding its audio open was heard before it paused).
        case hearingNothing
        /// Core Audio refused the tap.
        case unavailable
    }

    struct Configuration: Equatable {
        var enabled = false
        var intensity: Double = 0.6
        var texture: Double = 0.5
        var pauseWhileNavigating = false
        var pauseDuringCalls = true
        var syncOffsetMs: Double = 0
    }

    @Published private(set) var status: Status = .off
    /// How much music is felt right now, 0...1, for the settings meter.
    @Published private(set) var level: Float = 0
    /// The app playing right now, for the settings readout.
    @Published private(set) var sourceName: String?

    private let tap = SystemAudioTap()
    private let listener = MusicListener()
    private let log = Logger(subsystem: "com.masonchen.Tactile", category: "music")

    private var configuration = Configuration()
    private var pulser = HapticPulser(route: .system)
    private var pipelineActive = false
    private var playing: Set<AudioProcessMonitor.Client> = []
    private var permission = AudioCapturePermission.status
    private var askedForPermission = false
    private var tapWanted = false
    private var tapRunning = false
    private var tapFailed = false
    private var outputLatency: TimeInterval = 0
    private var lastReport: MusicListener.Report?
    private var lastFelt: CFTimeInterval = -.infinity
    private var silentSince: Date?
    /// Whether this tap session has heard anything but silence.
    private var heardSound = false
    private var idleStop: Timer?

    init() {
        let listener = self.listener
        tap.onSamples = { samples, count, rate, hostTime in
            listener.process(samples, count: count, sampleRate: rate, hostTime: hostTime)
        }
        tap.onEvent = { [weak self] event in self?.tapEvent(event) }
        listener.onReport = { [weak self] report in self?.received(report) }
    }

    var isListening: Bool { tapRunning }

    // MARK: Inputs

    func update(_ configuration: Configuration, pulser: HapticPulser, pipelineActive: Bool) {
        let turnedOn = configuration.enabled && !self.configuration.enabled
        self.configuration = configuration
        self.pulser = pulser
        self.pipelineActive = pipelineActive
        if turnedOn {
            // A fresh try: re-read the permission, and allow one more
            // attempt after a failure.
            permission = AudioCapturePermission.status
            tapFailed = false
        }
        pushSettings()
        refresh()
    }

    /// Feed every snapshot from the audio client monitor.
    func clientsChanged(playing: Set<AudioProcessMonitor.Client>, recording: Set<AudioProcessMonitor.Client>) {
        self.playing = playing
        // A call is a Dock app holding the microphone (dictation and
        // "Hey Siri" run in system processes and don't count).
        listener.setCallActive(recording.contains { $0.isRegularApp })
        let app = playing.first { $0.isRegularApp }?.appBundleID
        sourceName = app.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName }
        refresh()
    }

    func cursorMoved() {
        if tapRunning { listener.cursorMoved() }
    }

    func interfaceTapped() {
        if tapRunning { listener.interfaceTapped() }
    }

    /// Asks for the system audio permission (the prompt appears once; after
    /// a refusal only System Settings can change it).
    func requestPermission() {
        askedForPermission = true
        AudioCapturePermission.request { [weak self] granted in
            guard let self else { return }
            switch granted {
            case true?: self.permission = .authorized
            case false?: self.permission = .denied
            case nil: self.permission = .authorized // No way to ask: the tap prompts itself.
            }
            self.refresh()
        }
    }

    /// Re-reads the permission, for when the user comes back from System
    /// Settings.
    func refreshPermission() {
        let current = AudioCapturePermission.status
        guard current != permission else { return }
        permission = current
        refresh()
    }

    // MARK: State

    /// From the tap hearing a sample to the listener hearing it, plus the
    /// user's nudge.
    private var latency: TimeInterval {
        outputLatency + configuration.syncOffsetMs / 1000
    }

    private func pushSettings() {
        listener.update(MusicListener.Settings(
            intensity: Float(configuration.intensity),
            texture: Float(configuration.texture),
            pauseWhileNavigating: configuration.pauseWhileNavigating,
            pauseDuringCalls: configuration.pauseDuringCalls,
            latency: latency,
            pulser: pulser
        ))
    }

    private func refresh() {
        guard configuration.enabled, pipelineActive else {
            stopTap(now: true)
            status = .off
            return
        }
        switch permission {
        case .denied:
            stopTap(now: true)
            status = .denied
            return
        case .undetermined:
            status = .needsPermission
            if !askedForPermission { requestPermission() }
            return
        case .authorized:
            break
        }
        guard !tapFailed else {
            status = .unavailable
            return
        }
        if playing.isEmpty {
            // Keep listening a moment: the gap between two songs isn't the end.
            stopTap(now: false)
        } else {
            startTap()
        }
        status = derivedStatus()
    }

    private func derivedStatus() -> Status {
        guard !playing.isEmpty else { return .waiting }
        guard tapRunning, let report = lastReport else { return .listening }
        // Only silence since the tap started hints at a missing permission,
        // unless the system confirmed it: then an app really is playing
        // silence (the iOS Simulator, a paused video).
        if !AudioCapturePermission.canCheck, let silentSince, Date().timeIntervalSince(silentSince) > 5 { return .hearingNothing }
        // The readout holds a moment through the quiet between phrases.
        let feltRecently = CACurrentMediaTime() - lastFelt < 2
        if !feltRecently { return report.isTalk ? .talk : .listening }
        switch report.heldBack {
        case .cursor?: return .pausedForCursor
        case .call?: return .pausedForCall
        case nil: return .feeling
        }
    }

    private func startTap() {
        idleStop?.invalidate()
        idleStop = nil
        guard !tapWanted else { return }
        tapWanted = true
        listener.requestReset()
        listener.start()
        lastReport = nil
        lastFelt = -.infinity
        silentSince = nil
        heardSound = false
        tap.start()
    }

    private func stopTap(now: Bool) {
        guard tapWanted else { return }
        if now {
            idleStop?.invalidate()
            idleStop = nil
            tapWanted = false
            tapRunning = false
            tap.stop()
            listener.stop()
            level = 0
            return
        }
        guard idleStop == nil else { return }
        let timer = Timer(timeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.idleStop = nil
                if self.playing.isEmpty { self.stopTap(now: true) }
                self.status = self.configuration.enabled && self.pipelineActive ? self.derivedStatus() : .off
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleStop = timer
    }

    private func tapEvent(_ event: SystemAudioTap.Event) {
        switch event {
        case .started(_, let latency):
            guard tapWanted else { return }
            tapRunning = true
            outputLatency = latency
            pushSettings()
        case .failed(let code):
            log.error("music tap unavailable: \(code, privacy: .public)")
            tapWanted = false
            tapRunning = false
            tapFailed = true
            listener.stop()
            level = 0
        case .stopped:
            tapRunning = false
        }
        if configuration.enabled, pipelineActive { status = derivedStatus() }
        if tapFailed, configuration.enabled { status = .unavailable }
    }

    private func received(_ report: MusicListener.Report) {
        guard tapRunning else { return }
        lastReport = report
        if !report.isSilent { heardSound = true }
        if report.isSilent, !playing.isEmpty, !heardSound {
            if silentSince == nil { silentSince = Date() }
        } else {
            silentSince = nil
        }
        if report.isMusic { lastFelt = CACurrentMediaTime() }
        if report.level != level { level = report.level }
        let next = derivedStatus()
        if next != status { status = next }
    }
}
