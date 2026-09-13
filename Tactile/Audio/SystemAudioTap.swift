//
//  SystemAudioTap.swift
//  Tactile
//

import Accelerate
import CoreAudio
import Foundation
import os

/// Listens to what the Mac is playing, for music haptics: a Core Audio
/// process tap on every app's output except Tactile's own, read through a
/// private aggregate device. Audio is handed to `onSamples` as mono floats
/// on the tap's own queue, analyzed there, and never stored or sent
/// anywhere.
///
/// The tap is unmuted (playback is untouched) and private, and so is the
/// aggregate device, so nothing shows up in the Sound menu or Audio MIDI
/// Setup. When the default output device changes (headphones connect), the
/// tap is rebuilt on the new one.
nonisolated final class SystemAudioTap: @unchecked Sendable {
    enum Event: Sendable {
        /// Audio is flowing. `outputLatency` is how long it takes from the
        /// tap to the listener's ears through the current output device.
        case started(sampleRate: Double, outputLatency: TimeInterval)
        case failed(OSStatus)
        case stopped
    }

    /// Tap queue: mono samples, their count, their sample rate, and the
    /// host time the tap heard the first of them. Set before the first
    /// `start()`.
    var onSamples: ((UnsafePointer<Float>, Int, Double, UInt64) -> Void)?
    /// Main thread.
    var onEvent: (@MainActor (Event) -> Void)?

    private let control = DispatchQueue(label: "com.masonchen.Tactile.audio-tap.control")
    private let io = DispatchQueue(label: "com.masonchen.Tactile.audio-tap", qos: .userInteractive)
    private let log = Logger(subsystem: "com.masonchen.Tactile", category: "music")

    // Control-queue confined.
    private var wanted = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    private struct Failure: Error {
        let status: OSStatus
    }

    func start() {
        control.async {
            guard !self.wanted else { return }
            self.wanted = true
            self.listenForDeviceChanges()
            self.build()
        }
    }

    func stop() {
        control.async {
            guard self.wanted else { return }
            self.wanted = false
            self.stopListeningForDeviceChanges()
            self.teardown()
            self.report(.stopped)
        }
    }

    // MARK: - Build

    private func build() {
        teardown()
        guard wanted else { return }
        do {
            let own = Self.processObject(for: getpid())
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
            description.uuid = UUID()
            description.name = "Tactile"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            var tap = AudioObjectID(kAudioObjectUnknown)
            try Self.check(AudioHardwareCreateProcessTap(description, &tap))
            tapID = tap

            let format = try Self.tapFormat(tap)
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, format.mSampleRate > 0
            else { throw Failure(status: kAudioHardwareUnsupportedOperationError) }

            var composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Tactile",
                kAudioAggregateDeviceUIDKey: "com.masonchen.Tactile.listen." + UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            // Clocked by the output device when it only plays. A device
            // that also records (a USB headset) would have its microphone
            // started along with it, so then the tap runs on its own clock.
            let output = Self.defaultOutputDevice()
            if let output, let uid = Self.uid(output), !Self.hasInput(output) {
                composition[kAudioAggregateDeviceMainSubDeviceKey] = uid
                composition[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid]]
            }
            var aggregate = AudioObjectID(kAudioObjectUnknown)
            try Self.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate))
            aggregateID = aggregate

            let mixer = Mixer(format: format)
            let deliver = onSamples
            var proc: AudioDeviceIOProcID?
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, io) { _, input, inputTime, _, _ in
                let stamp = inputTime.pointee
                let start = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : mach_absolute_time()
                mixer.mix(input) { samples, count, offset in
                    deliver?(samples, count, mixer.sampleRate, start &+ HostTime.ticks(Double(offset) / mixer.sampleRate))
                }
            })
            procID = proc
            try Self.check(AudioDeviceStart(aggregate, proc))

            let latency = output.map(Self.outputLatency) ?? 0
            log.debug("music tap started rate=\(format.mSampleRate, privacy: .public) channels=\(format.mChannelsPerFrame, privacy: .public) latency=\(latency, privacy: .public) clocked=\(composition[kAudioAggregateDeviceMainSubDeviceKey] != nil, privacy: .public)")
            report(.started(sampleRate: format.mSampleRate, outputLatency: latency))
        } catch {
            let status = (error as? Failure)?.status ?? kAudioHardwareUnspecifiedError
            log.error("music tap failed status=\(status, privacy: .public)")
            teardown()
            report(.failed(status))
        }
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func report(_ event: Event) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onEvent?(event) }
        }
    }

    // MARK: - Output device changes

    private func listenForDeviceChanges() {
        guard deviceListener == nil else { return }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.wanted else { return }
            self.build()
        }
        if AudioObjectAddPropertyListenerBlock(Self.system, &address, control, block) == noErr {
            deviceListener = block
        }
    }

    private func stopListeningForDeviceChanges() {
        guard let deviceListener else { return }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(Self.system, &address, control, deviceListener)
        self.deviceListener = nil
    }

    // MARK: - Mixing

    /// Folds each IO cycle's tap buffers down to mono. One per build, used
    /// only on the IO queue.
    private final class Mixer {
        let sampleRate: Double
        private let buffer: UnsafeMutablePointer<Float>
        private let capacity = 4096

        init(format: AudioStreamBasicDescription) {
            sampleRate = format.mSampleRate
            buffer = .allocate(capacity: capacity)
        }

        deinit { buffer.deallocate() }

        /// Delivers mono chunks with their frame offset into the cycle.
        func mix(_ list: UnsafePointer<AudioBufferList>, deliver: (UnsafePointer<Float>, Int, Int) -> Void) {
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            guard let first = buffers.first, first.mData != nil else { return }
            if buffers.count == 1 {
                // Interleaved: every channel in one buffer.
                let channels = max(1, Int(first.mNumberChannels))
                let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                let samples = first.mData!.assumingMemoryBound(to: Float.self)
                var offset = 0
                while offset < frames {
                    let n = min(capacity, frames - offset)
                    let base = samples + offset * channels
                    vDSP_mmov(base, buffer, 1, vDSP_Length(n), vDSP_Length(channels), 1)
                    if channels > 1 {
                        for channel in 1..<channels {
                            vDSP_vadd(buffer, 1, base + channel, vDSP_Stride(channels), buffer, 1, vDSP_Length(n))
                        }
                        var scale = 1 / Float(channels)
                        vDSP_vsmul(buffer, 1, &scale, buffer, 1, vDSP_Length(n))
                    }
                    deliver(buffer, n, offset)
                    offset += n
                }
            } else {
                // Non-interleaved: one buffer per channel.
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                var offset = 0
                while offset < frames {
                    let n = min(capacity, frames - offset)
                    var used = 0
                    for channel in buffers {
                        guard let data = channel.mData, Int(channel.mDataByteSize) / MemoryLayout<Float>.size >= offset + n else { continue }
                        let samples = data.assumingMemoryBound(to: Float.self) + offset
                        if used == 0 {
                            buffer.update(from: samples, count: n)
                        } else {
                            vDSP_vadd(buffer, 1, samples, 1, buffer, 1, vDSP_Length(n))
                        }
                        used += 1
                    }
                    guard used > 0 else { return }
                    var scale = 1 / Float(used)
                    vDSP_vsmul(buffer, 1, &scale, buffer, 1, vDSP_Length(n))
                    deliver(buffer, n, offset)
                    offset += n
                }
            }
        }
    }

    // MARK: - Core Audio

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw Failure(status: status) }
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
        var address = address(selector, scope: scope)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object) == noErr,
              object != kAudioObjectUnknown
        else { return nil }
        return object
    }

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        guard let format = value(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()) else {
            throw Failure(status: kAudioHardwareUnknownPropertyError)
        }
        return format
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        guard let device = value(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown)),
              device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    private static func uid(_ device: AudioObjectID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func streams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        var address = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        !streams(device, scope: kAudioObjectPropertyScopeInput).isEmpty
    }

    /// Device latency, safety offset, stream latency, and one IO buffer:
    /// the path from a sample leaving the tap to it reaching the ears.
    private static func outputLatency(_ device: AudioObjectID) -> TimeInterval {
        let output = kAudioObjectPropertyScopeOutput
        let rate = value(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0
        guard rate > 0 else { return 0 }
        let latency = value(device, kAudioDevicePropertyLatency, scope: output, initial: UInt32(0)) ?? 0
        let safety = value(device, kAudioDevicePropertySafetyOffset, scope: output, initial: UInt32(0)) ?? 0
        let buffer = value(device, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)) ?? 0
        let stream = streams(device, scope: output).first
            .flatMap { value($0, kAudioStreamPropertyLatency, initial: UInt32(0)) } ?? 0
        return Double(latency + safety + buffer + stream) / rate
    }
}
