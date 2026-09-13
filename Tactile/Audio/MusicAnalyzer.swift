//
//  MusicAnalyzer.swift
//  Tactile
//

import Accelerate
import Foundation

/// Hears whatever the Mac plays the way a drummer would: every hit and note
/// attack becomes an accent, and the sound's loudness and register become a
/// vibration that runs underneath. Nothing is sorted into instruments: a
/// kick, a piano chord, and a guitar strum are all accents that sit lower
/// or higher, so every kind of music is felt the same way.
///
/// Talk is told apart by its gaps: a voice keeps dropping away between
/// syllables and words, while music keeps sounding. While the audio sounds
/// like talk, `musicness` falls and the feel fades out.
///
/// Attacks come from spectral flux (the rise of every frequency bin over its
/// neighbors a moment earlier, so vibrato and sustained notes don't count),
/// judged against the music's own recent flux, so volume and mastering
/// don't matter. Pure DSP with no allocation after init, testable offline.
/// One instance per audio queue; not thread-safe.
nonisolated final class MusicAnalyzer {
    struct Accent {
        /// Where the attack is, as an offset from the first sample passed to
        /// the current `process` call. Usually negative: an attack is only
        /// sure once the sound has moved past it.
        var frame: Int
        /// How strong the attack is next to this music's recent ones, 0...1.
        var strength: Float
        /// How much of the attack is low (a kick, a bass note, a low chord)
        /// rather than high (a snare, a pluck), 0...1.
        var weight: Float
    }

    /// Measured on drum tracks with known hits, real music of many kinds,
    /// audiobooks, narration, and synthetic and recorded voices.
    struct Tuning {
        /// How far above the recent flux an attack must rise, in mean
        /// deviations.
        var sensitivity: Float = 2.2
        /// The shortest gap between two accents, seconds.
        var minGap: Double = 0.06
        /// Loudness below the music's loud parts that maps onto energy, dB.
        var energySpanDB: Float = 24
        /// The share of the last `gapWindow` seconds spent `gapDepth` dB
        /// under the sound's mean level. At `speechGaps` the audio is talk,
        /// at `musicGaps` music: narration sits around 0.2-0.3, music
        /// under 0.1.
        var speechGaps: Float = 0.18
        var musicGaps: Float = 0.08
        var gapDepth: Float = 10
        var gapWindow: Double = 2.5
        /// Where the analysis window's reading lands, from its end, as a
        /// share of the window; calibrated on tracks with known hits.
        var attackOffset: Double = 0.5
    }

    let sampleRate: Double
    let tuning: Tuning

    /// 0...1: how loud the music is next to its own loud parts.
    private(set) var energy: Float = 0
    /// 0...1: how much of the sound right now is low.
    private(set) var weight: Float = 0
    /// 0...1: 0 while the audio sounds like talk, 1 for music. Kept across
    /// `reset()`, so the next song is felt from its first beat.
    private(set) var musicness: Float = 0
    /// True while the stream is effectively silent.
    private(set) var isSilent = true
    /// Readings behind the decisions, for tests.
    private(set) var flux: Float = 0
    private(set) var threshold: Float = 0
    private(set) var gapShare: Float = 0

    static let windowSize = 1024
    static let hop = 256

    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let frame: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imag: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>
    private let logSpectrum: UnsafeMutablePointer<Float>
    /// The log spectra of the last two hops; flux compares against the older.
    private let previous: UnsafeMutablePointer<Float>
    private let older: UnsafeMutablePointer<Float>
    private let bins: Int
    private let lowBins: Int
    private let fluxBins: Int
    private let energyBins: ClosedRange<Int>
    private let binHz: Float

    private var filled = 0
    private var frames = 0
    /// Stream position, in samples, of the next sample to arrive.
    private var position = 0

    // Peak picking over the flux, one hop of lookahead.
    private var fluxBefore: Float = 0
    private var fluxLast: Float = 0
    private var weightLast: Float = 0
    private var thresholdLast: Float = 0
    private var fluxMean: Float = 0
    private var fluxDeviation: Float = 0
    private var peakReference: Float = 0
    private var lastAccent = -Int.max / 2

    // Loudness and its reference.
    private var smoothedDB: Float = -120
    private var referenceDB: Float = -30
    private var quietHops = 0

    // Levels of the last `gapWindow` seconds of sounding hops.
    private let history: UnsafeMutablePointer<Float>
    private let historySize: Int
    private var historyIndex = 0
    private var historyCount = 0
    private var historySum: Float = 0

    private let meanSmoothing: Float
    private let peakFall: Float
    private let attack: Float
    private let release: Float
    private let referenceRise: Float
    private let referenceFall: Float
    private let musicRise: Float
    private let musicFall: Float
    private let minGapHops: Int
    private let silenceHops: Int

    init(sampleRate: Double, tuning: Tuning = Tuning()) {
        self.sampleRate = sampleRate
        self.tuning = tuning
        let size = Self.windowSize
        bins = size / 2
        binHz = Float(sampleRate) / Float(size)
        lowBins = max(1, Int(150 / binHz))
        fluxBins = min(bins - 1, Int(12_000 / binHz))
        energyBins = max(1, Int(40 / binHz)) ... min(bins - 1, Int(6_000 / binHz))
        setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
        window = .allocate(capacity: size)
        vDSP_hann_window(window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        frame = .allocate(capacity: size)
        frame.initialize(repeating: 0, count: size)
        windowed = .allocate(capacity: size)
        windowed.initialize(repeating: 0, count: size)
        real = .allocate(capacity: bins)
        real.initialize(repeating: 0, count: bins)
        imag = .allocate(capacity: bins)
        imag.initialize(repeating: 0, count: bins)
        magnitudes = .allocate(capacity: bins)
        magnitudes.initialize(repeating: 0, count: bins)
        logSpectrum = .allocate(capacity: bins)
        logSpectrum.initialize(repeating: 0, count: bins)
        previous = .allocate(capacity: bins)
        previous.initialize(repeating: 0, count: bins)
        older = .allocate(capacity: bins)
        older.initialize(repeating: 0, count: bins)

        let hopSeconds = Double(Self.hop) / sampleRate
        historySize = max(8, Int(tuning.gapWindow / hopSeconds))
        history = .allocate(capacity: historySize)
        history.initialize(repeating: 0, count: historySize)
        meanSmoothing = Float(1 - exp(-hopSeconds / 0.3))
        peakFall = Float(exp(-hopSeconds / 3))
        attack = Float(1 - exp(-hopSeconds / 0.01))
        release = Float(1 - exp(-hopSeconds / 0.15))
        referenceRise = Float(1 - exp(-hopSeconds / 0.5))
        referenceFall = Float(1 - exp(-hopSeconds / 8))
        musicRise = Float(1 - exp(-hopSeconds / 1.0))
        musicFall = Float(1 - exp(-hopSeconds / 0.35))
        minGapHops = max(1, Int(tuning.minGap / hopSeconds))
        silenceHops = Int(0.25 / hopSeconds)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        for pointer in [window, frame, windowed, real, imag, magnitudes, logSpectrum, previous, older, history] {
            pointer.deallocate()
        }
    }

    /// Forgets the last stream: a new song starts from scratch, except for
    /// whether it was music.
    func reset() {
        frame.update(repeating: 0, count: Self.windowSize)
        previous.update(repeating: 0, count: bins)
        older.update(repeating: 0, count: bins)
        history.update(repeating: 0, count: historySize)
        filled = 0
        frames = 0
        historyIndex = 0
        historyCount = 0
        historySum = 0
        fluxBefore = 0
        fluxLast = 0
        weightLast = 0
        thresholdLast = 0
        fluxMean = 0
        fluxDeviation = 0
        peakReference = 0
        lastAccent = -Int.max / 2
        smoothedDB = -120
        referenceDB = -30
        quietHops = 0
        energy = 0
        weight = 0
        isSilent = true
    }

    /// Feeds samples. `accent` is called for each attack; `hop` after each
    /// ~5 ms analysis step, with the step's reading position (an offset like
    /// `Accent.frame`), when `energy`, `weight`, and `musicness` have just
    /// been updated.
    func process(_ samples: UnsafePointer<Float>, count: Int, accent: (Accent) -> Void, hop: (Int) -> Void) {
        let start = position
        var offset = 0
        let size = Self.windowSize
        let hopSize = Self.hop
        while offset < count {
            // Slide the window by one hop once a hop of new samples is in.
            let take = min(hopSize - filled, count - offset)
            (frame + size - hopSize + filled).update(from: samples + offset, count: take)
            filled += take
            offset += take
            position += take
            guard filled == hopSize else { break }
            analyze(streamStart: start, accent: accent)
            hop(position - Int(tuning.attackOffset * Double(size)) - start)
            frame.update(from: frame + hopSize, count: size - hopSize)
            filled = 0
        }
    }

    private func analyze(streamStart: Int, accent: (Accent) -> Void) {
        let size = Self.windowSize
        frames += 1
        vDSP_vmul(frame, 1, window, 1, windowed, 1, vDSP_Length(size))
        var split = DSPSplitComplex(realp: real, imagp: imag)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: bins) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(bins))
        }
        vDSP_fft_zrip(setup, &split, 1, 10, FFTDirection(FFT_FORWARD))
        imag[0] = 0
        real[0] = 0
        vDSP_zvabs(&split, 1, magnitudes, 1, vDSP_Length(bins))
        var scale = 1 / Float(size)
        vDSP_vsmul(magnitudes, 1, &scale, magnitudes, 1, vDSP_Length(bins))

        // Loudness and weight of the sound right now.
        var power: Float = 0
        var low: Float = 0
        for bin in energyBins {
            let magnitude = magnitudes[bin]
            let squared = magnitude * magnitude
            power += squared
            if bin <= lowBins { low += squared }
        }
        let decibels = 10 * log10(max(power, 1e-14))
        weight = power > 0 ? low / power : 0
        updateLoudness(decibels)
        updateMusicness(decibels)

        // Spectral flux against the spectrum two hops back, widened by a
        // bin each way so vibrato and slides don't read as attacks.
        var fluxNow: Float = 0
        var lowFlux: Float = 0
        for bin in 1...fluxBins {
            let value = log(1 + 100 * magnitudes[bin])
            logSpectrum[bin] = value
            let reference = max(older[bin - 1], older[bin], older[min(bin + 1, bins - 1)])
            let rise = value - reference
            if rise > 0 {
                fluxNow += rise
                if bin <= lowBins { lowFlux += rise }
            }
        }
        older.update(from: previous, count: bins)
        previous.update(from: logSpectrum, count: bins)
        flux = fluxNow
        // Weight: how hard the low bins rose next to the rest, bin for bin.
        let lowAverage = lowFlux / Float(lowBins)
        let highAverage = (fluxNow - lowFlux) / Float(max(fluxBins - lowBins, 1))
        let weightNow = lowAverage + highAverage > 0 ? lowAverage / (lowAverage + highAverage) : 0

        // The previous hop is an accent if it peaked above the threshold.
        let hopIndex = frames - 1
        if fluxLast > fluxBefore, fluxLast >= fluxNow, fluxLast > thresholdLast,
           hopIndex - 1 - lastAccent >= minGapHops, !isSilent {
            lastAccent = hopIndex - 1
            peakReference = max(peakReference, fluxLast)
            let span = max(peakReference - thresholdLast, 1e-6)
            let strength = min(max((fluxLast - thresholdLast) / span, 0), 1)
            // The previous hop's window ended a hop before this one.
            let attackPosition = position - Self.hop - Int(tuning.attackOffset * Double(size))
            accent(Accent(frame: attackPosition - streamStart, strength: strength, weight: weightLast))
        }
        peakReference *= peakFall

        // The threshold follows the flux's own recent behavior.
        thresholdLast = fluxMean + tuning.sensitivity * fluxDeviation + 0.5
        fluxMean += (fluxNow - fluxMean) * meanSmoothing
        fluxDeviation += (abs(fluxNow - fluxMean) - fluxDeviation) * meanSmoothing
        threshold = thresholdLast
        fluxBefore = fluxLast
        fluxLast = fluxNow
        weightLast = weightNow
    }

    private func updateLoudness(_ decibels: Float) {
        smoothedDB += (decibels - smoothedDB) * (decibels > smoothedDB ? attack : release)
        quietHops = decibels < -60 ? quietHops + 1 : 0
        isSilent = quietHops >= silenceHops
        if !isSilent {
            let smoothing = smoothedDB > referenceDB ? referenceRise : referenceFall
            referenceDB += (smoothedDB - referenceDB) * smoothing
            referenceDB = min(max(referenceDB, -34), -6)
        }
        let bottom = referenceDB - tuning.energySpanDB
        energy = isSilent ? 0 : min(max((smoothedDB - bottom) / tuning.energySpanDB, 0), 1)
    }

    private func updateMusicness(_ decibels: Float) {
        // Silence between songs is not a gap.
        guard !isSilent else { return }
        let level = max(decibels, -99)
        if historyCount == historySize { historySum -= history[historyIndex] }
        history[historyIndex] = level
        historySum += level
        historyIndex = (historyIndex + 1) % historySize
        historyCount = min(historyCount + 1, historySize)
        guard historyCount >= historySize / 3 else { return }

        let limit = historySum / Float(historyCount) - tuning.gapDepth
        var gaps = 0
        for index in 0..<historyCount where history[index] < limit { gaps += 1 }
        gapShare = Float(gaps) / Float(historyCount)
        let target = min(max((tuning.speechGaps - gapShare) / (tuning.speechGaps - tuning.musicGaps), 0), 1)
        // Rising takes a full window, so a sentence spoken without a pause
        // never passes for music; falling starts as soon as gaps show.
        if target > musicness, historyCount < historySize { return }
        musicness += (target - musicness) * (target > musicness ? musicRise : musicFall)
    }
}
