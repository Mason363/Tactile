//
//  SpeakerVoice.swift
//  Tactile
//

import Accelerate
import Foundation

/// Up to a handful of the music's partials, as the trackpad will play them,
/// with the segment length the lead partial asks for.
nonisolated struct Chord: Sendable {
    struct Partial: Sendable {
        /// Already folded into the range the motor can play.
        var hz: Float
        /// 0...1, summing to 1 across the chord.
        var amplitude: Float
    }

    var partials: [Partial]
    /// How long this segment runs, in the firmware's ticks of 1/24 ms.
    var lengthTicks: Int
    /// 0...1, how hard this moment of the music should be played, measured
    /// against the music's own recent loudness.
    var loudness: Float

    var seconds: TimeInterval { Double(lengthTicks) / 24_000 }
}

/// Hears the music the way a speaker would have to play it: a long FFT over
/// the stream, the strongest partials picked out of it, each folded into the
/// range the trackpad's motor can actually produce, handed over as a chord.
///
/// The motor cannot go below about 94 Hz, so bass is folded up an octave or
/// two. That is what a small speaker does with bass anyway, and it keeps the
/// tune recognizable: folding by octaves preserves the note, only its
/// register moves.
///
/// Nothing here decides when to play. That is the listener's job.
/// Pure DSP with no allocation after init beyond the chord itself.
nonisolated final class SpeakerVoice {
    struct Tuning {
        /// The range the motor plays well: it cannot go under ~94 Hz, and
        /// turns thin and harsh up high.
        var lowHz: Double = 90
        var highHz: Double = 600
        /// The part of the music worth looking at. Below this is rumble,
        /// above it the partials stop carrying the tune.
        var fromHz: Double = 40
        var toHz: Double = 1600
        /// Partials this far under the lead are left out, so a single
        /// sustained note plays as one clean tone instead of a smear.
        var floor: Float = 0.08
    }

    /// The hardest the motor is ever driven, as an amplitude scale. Set by
    /// ear: at this much the trackpad genuinely sounds the music, and it is
    /// only reached by the loudest passages at full intensity.
    static let ceiling: Float = 0.6

    let sampleRate: Double
    let tuning: Tuning

    /// 4096 points puts the bins about 12 Hz apart at 48 kHz, and the
    /// interpolation below takes each peak to within a hertz or so, enough
    /// to hold a bass line's pitch steady.
    static let windowSize = 4096

    private let setup: FFTSetup
    private let order: vDSP_Length
    private let bins: Int
    private let binHz: Float
    private let firstBin: Int
    private let lastBin: Int

    private let window: UnsafeMutablePointer<Float>
    private let frame: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imag: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>

    private var filled = 0
    /// The music's own recent loudness, so a loud master keeps its dynamics
    /// instead of sitting on the ceiling.
    private var reference: Float = 0

    init(sampleRate: Double, tuning: Tuning = Tuning()) {
        self.sampleRate = sampleRate
        self.tuning = tuning
        let size = Self.windowSize
        order = vDSP_Length(log2(Double(size)).rounded())
        bins = size / 2
        binHz = Float(sampleRate) / Float(size)
        firstBin = max(2, Int(tuning.fromHz / Double(binHz)))
        lastBin = min(bins - 2, Int(tuning.toHz / Double(binHz)))
        setup = vDSP_create_fftsetup(order, FFTRadix(kFFTRadix2))!
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
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        for pointer in [window, frame, windowed, real, imag, magnitudes] { pointer.deallocate() }
    }

    func reset() {
        frame.update(repeating: 0, count: Self.windowSize)
        filled = 0
        reference = 0
    }

    /// Keeps the most recent window of sound. Cheap: just a slide and a copy.
    func push(_ samples: UnsafePointer<Float>, count: Int) {
        let size = Self.windowSize
        if count >= size {
            frame.update(from: samples + count - size, count: size)
        } else {
            frame.update(from: frame + count, count: size - count)
            (frame + size - count).update(from: samples, count: count)
        }
        filled = min(filled + count, size)
    }

    /// The chord for the sound held right now, or nil while there is not yet
    /// a full window or nothing worth playing. `tones` caps how many partials
    /// are played at once.
    func chord(tones: Int) -> Chord? {
        guard filled >= Self.windowSize, tones >= 1, firstBin < lastBin else { return nil }
        let size = Self.windowSize

        // How hard to play this moment: loud next to the music's own recent
        // loudness, so quiet passages stay quiet and loud ones swell, with an
        // absolute gate so near-silence is never normalized back up.
        var power: Float = 0
        vDSP_measqv(frame, 1, &power, vDSP_Length(size))
        let rms = sqrtf(power)
        reference += (rms - reference) * (rms > reference ? 0.25 : 0.02)
        let relative = reference > 1e-5 ? rms / (reference * 1.25) : 0
        let loudness = min(relative, 1) * min(rms * 30, 1)
        vDSP_vmul(frame, 1, window, 1, windowed, 1, vDSP_Length(size))
        var split = DSPSplitComplex(realp: real, imagp: imag)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: bins) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(bins))
        }
        vDSP_fft_zrip(setup, &split, 1, order, FFTDirection(FFT_FORWARD))
        real[0] = 0
        imag[0] = 0
        vDSP_zvabs(&split, 1, magnitudes, 1, vDSP_Length(bins))

        // Every local peak, placed between its bins so the pitch is right.
        var peaks: [(hz: Double, amplitude: Float)] = []
        peaks.reserveCapacity(24)
        for bin in firstBin...lastBin where magnitudes[bin] > magnitudes[bin - 1] && magnitudes[bin] >= magnitudes[bin + 1] {
            let left = magnitudes[bin - 1], middle = magnitudes[bin], right = magnitudes[bin + 1]
            let curve = left - 2 * middle + right
            let shift = curve == 0 ? 0 : 0.5 * (left - right) / curve
            peaks.append((Double((Float(bin) + shift) * binHz), middle))
        }
        guard !peaks.isEmpty else { return nil }
        peaks.sort { $0.amplitude > $1.amplitude }

        // Fold each into range by octaves, merging any that land on the same
        // tone once folded.
        var folded: [(hz: Double, amplitude: Float)] = []
        folded.reserveCapacity(tones * 2)
        for peak in peaks.prefix(24) {
            var hz = peak.hz
            while hz < tuning.lowHz { hz *= 2 }
            while hz > tuning.highHz { hz /= 2 }
            guard hz >= tuning.lowHz else { continue }
            if let index = folded.firstIndex(where: { abs($0.hz - hz) < max(4, hz * 0.03) }) {
                folded[index].amplitude += peak.amplitude
            } else {
                folded.append((hz, peak.amplitude))
            }
            if folded.count >= tones * 2 { break }
        }
        folded.sort { $0.amplitude > $1.amplitude }
        var chosen = Array(folded.prefix(tones))
        // A speaker reproduces what is there: one sustained note should play
        // as one tone, not as a crowd of near-silent ones.
        if let lead = chosen.first?.amplitude {
            chosen = chosen.filter { $0.amplitude >= lead * tuning.floor }
        }
        let total = chosen.reduce(Float(0)) { $0 + $1.amplitude }
        guard total > 0, let lead = chosen.first?.hz else { return nil }
        let partials = chosen.map { Chord.Partial(hz: Float($0.hz), amplitude: $0.amplitude / total) }
        return Chord(partials: partials, lengthTicks: Self.segmentTicks(forHz: lead), loudness: loudness)
    }

    /// How long a segment led by this tone should run, on the firmware's tick
    /// grid: a whole number of the lead's cycles, kept between 192 and 255
    /// ticks (8...10.6 ms). Whole cycles are what let one segment run into
    /// the next without a seam, and the range stays under the firmware's cap
    /// while keeping the driver clear of the rate where it stalls.
    static func segmentTicks(forHz hz: Double) -> Int {
        let period = max(40, min(255, Int((24_000 / max(hz, 1)).rounded())))
        let cycles = max(1, Int((192.0 / Double(period)).rounded(.up)))
        return min(255, cycles * period)
    }
}
