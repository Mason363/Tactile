//
//  SoundImportView.swift
//  Tactile
//

import AVFoundation
import SwiftUI

/// The audio work behind the import editor, kept UI-free so it can be
/// exercised without a window: waveform peaks for display, and trimming a
/// selection out to the sound library.
enum SoundImportSupport {
    struct Info {
        var bins: [Float]
        var duration: Double
        var frames: AVAudioFramePosition
        var sampleRate: Double
    }

    /// Longer files are cut off here: hover clicks are short, and the
    /// editor stays responsive.
    static let maxSeconds: Double = 120

    /// Streams the file once and reduces it to peak bins for drawing.
    static func loadInfo(from url: URL, binCount: Int = 400) throws -> Info {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = min(file.length, AVAudioFramePosition(maxSeconds * format.sampleRate))
        guard totalFrames > 0 else {
            throw NSError(domain: "Tactile", code: 1, userInfo: [NSLocalizedDescriptionKey: "The file contains no audio."])
        }

        var bins = [Float](repeating: 0, count: binCount)
        let framesPerBin = max(Int(totalFrames) / binCount, 1)
        let chunkFrames: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw NSError(domain: "Tactile", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't read the audio."])
        }

        var frameIndex = 0
        file.framePosition = 0
        while file.framePosition < totalFrames {
            try file.read(into: buffer, frameCount: chunkFrames)
            guard buffer.frameLength > 0 else { break }
            let channels = Int(format.channelCount)
            for frame in 0..<Int(buffer.frameLength) {
                var peak: Float = 0
                for channel in 0..<channels {
                    peak = max(peak, abs(buffer.floatChannelData![channel][frame]))
                }
                let bin = min(frameIndex / framesPerBin, binCount - 1)
                bins[bin] = max(bins[bin], peak)
                frameIndex += 1
                if frameIndex >= Int(totalFrames) { break }
            }
            if frameIndex >= Int(totalFrames) { break }
        }

        return Info(
            bins: bins,
            duration: Double(totalFrames) / format.sampleRate,
            frames: totalFrames,
            sampleRate: format.sampleRate
        )
    }

    /// Writes the selected slice into the sound library as a Core Audio
    /// file and returns its "custom:" identifier.
    static func saveTrimmed(from url: URL, startFraction: Double, endFraction: Double) throws -> String {
        let source = try AVAudioFile(forReading: url)
        let format = source.processingFormat
        let totalFrames = min(source.length, AVAudioFramePosition(maxSeconds * format.sampleRate))
        let startFrame = AVAudioFramePosition(Double(totalFrames) * max(0, min(startFraction, 1)))
        let endFrame = AVAudioFramePosition(Double(totalFrames) * max(0, min(endFraction, 1)))
        guard endFrame > startFrame else {
            throw NSError(domain: "Tactile", code: 3, userInfo: [NSLocalizedDescriptionKey: "The selection is empty."])
        }

        let base = url.deletingPathExtension().lastPathComponent
        var name = base + ".caf"
        var counter = 2
        while FileManager.default.fileExists(atPath: AudioFeedbackEngine.soundsDirectory.appendingPathComponent(name).path) {
            name = "\(base) \(counter).caf"
            counter += 1
        }
        let destination = AudioFeedbackEngine.soundsDirectory.appendingPathComponent(name)

        // The processing format is deinterleaved float, which file creation
        // rejects; describe the file explicitly (AVAudioFile converts on write).
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let writer = try AVAudioFile(forWriting: destination, settings: fileSettings)
        let chunkFrames: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw NSError(domain: "Tactile", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't read the audio."])
        }

        source.framePosition = startFrame
        var remaining = endFrame - startFrame
        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining))
            try source.read(into: buffer, frameCount: toRead)
            guard buffer.frameLength > 0 else { break }
            try writer.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }

        // Reject silence or write failures rather than saving a dud.
        guard NSSound(contentsOf: destination, byReference: true) != nil else {
            try? FileManager.default.removeItem(at: destination)
            throw NSError(domain: "Tactile", code: 4, userInfo: [NSLocalizedDescriptionKey: "Couldn't save a playable clip."])
        }
        return "custom:" + name
    }
}

/// Plays the selected slice of the file being imported.
@MainActor
final class SoundImportPreview {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connected = false

    func play(url: URL, startFraction: Double, endFraction: Double, volume: Double) {
        stop()
        guard let file = try? AVAudioFile(forReading: url) else { return }
        let format = file.processingFormat
        let totalFrames = min(file.length, AVAudioFramePosition(SoundImportSupport.maxSeconds * format.sampleRate))
        let start = AVAudioFramePosition(Double(totalFrames) * startFraction)
        let count = AVAudioFrameCount(max(Double(totalFrames) * (endFraction - startFraction), 1))

        if !connected {
            engine.attach(player)
            connected = true
        }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        guard (try? engine.start()) != nil else { return }
        player.volume = Float(volume)
        player.scheduleSegment(file, startingFrame: start, frameCount: count, at: nil)
        player.play()
    }

    func stop() {
        if connected { player.stop() }
    }
}

/// The import editor: an accurate waveform of the chosen file, drag handles
/// to crop it, play to hear the selection, and Save to keep it.
struct SoundImportView: View {
    let url: URL
    var onSave: (String) -> Void

    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var info: SoundImportSupport.Info?
    @State private var loadError: String?
    @State private var start: Double = 0
    @State private var end: Double = 1
    @State private var preview = SoundImportPreview()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(url.lastPathComponent)
                .font(.headline)

            if let info {
                WaveformCropView(bins: info.bins, start: $start, end: $end)
                    .frame(height: 120)

                HStack {
                    Text(rangeText(info))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Crop") {
                        start = 0
                        end = 1
                    }
                    .disabled(start == 0 && end == 1)
                }

                Text("Drag the edges to crop. Short clips work best as clicks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ProgressView("Reading audio…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            }

            HStack {
                Button {
                    preview.play(url: url, startFraction: start, endFraction: end, volume: settings.audioVolume)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .disabled(info == nil)

                Spacer()

                Button("Cancel") {
                    preview.stop()
                    dismiss()
                }

                Button("Save Sound") {
                    preview.stop()
                    do {
                        let identifier = try SoundImportSupport.saveTrimmed(from: url, startFraction: start, endFraction: end)
                        onSave(identifier)
                        dismiss()
                    } catch {
                        loadError = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(info == nil || end - start < 0.001)
            }
        }
        .padding(20)
        .frame(width: 520, height: 300)
        .task {
            do {
                info = try SoundImportSupport.loadInfo(from: url)
            } catch {
                loadError = error.localizedDescription
            }
        }
        .onDisappear { preview.stop() }
    }

    private func rangeText(_ info: SoundImportSupport.Info) -> String {
        let from = info.duration * start
        let to = info.duration * end
        return String(format: "%.2fs to %.2fs of %.2fs (%.2fs clip)", from, to, info.duration, to - from)
    }
}

/// The waveform with draggable crop handles. Peaks are drawn as mirrored
/// vertical bars; the area outside the selection is dimmed.
private struct WaveformCropView: View {
    let bins: [Float]
    @Binding var start: Double
    @Binding var end: Double

    private let handleWidth: CGFloat = 8
    private let minimumSpan = 0.005

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .underPageBackgroundColor))

                Canvas { context, size in
                    let count = bins.count
                    guard count > 0 else { return }
                    let step = size.width / CGFloat(count)
                    let mid = size.height / 2
                    let startX = size.width * start
                    let endX = size.width * end
                    for (index, peak) in bins.enumerated() {
                        let x = CGFloat(index) * step + step / 2
                        let half = max(CGFloat(peak) * (mid - 4), 1)
                        let inSelection = x >= startX && x <= endX
                        let color: Color = inSelection ? .accentColor : Color.secondary.opacity(0.35)
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: mid - half))
                        path.addLine(to: CGPoint(x: x, y: mid + half))
                        context.stroke(path, with: .color(color), lineWidth: max(step * 0.7, 1))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Crop handles.
                handle(at: width * start, height: height)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                start = min(max(0, value.location.x / width), end - minimumSpan)
                            }
                    )
                    .accessibilityLabel("Crop start")
                handle(at: width * end, height: height)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                end = max(min(1, value.location.x / width), start + minimumSpan)
                            }
                    )
                    .accessibilityLabel("Crop end")
            }
        }
    }

    private func handle(at x: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .frame(width: handleWidth, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white.opacity(0.85))
                    .frame(width: 2, height: height * 0.4)
            )
            .position(x: x, y: height / 2)
            .contentShape(Rectangle().inset(by: -8))
    }
}
