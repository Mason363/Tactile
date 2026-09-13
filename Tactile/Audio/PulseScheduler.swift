//
//  PulseScheduler.swift
//  Tactile
//

import Foundation
import os

/// Host-clock conversions for timing pulses to the sound.
nonisolated enum HostTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Seconds as `mach_absolute_time` ticks; negative counts as zero.
    static func ticks(_ seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }

    /// `mach_absolute_time` ticks back to seconds.
    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}

/// Plays music pulses at exact moments on a thread of its own, so each one
/// lands with its sound however long the speakers or headphones take to
/// play it. Pulses arrive in time order from the audio queue; the thread
/// sleeps until the next one is due and parks while none are queued.
nonisolated final class PulseScheduler: @unchecked Sendable {
    struct Item: Sendable {
        enum Kind: Sendable {
            /// A hit or note attack, for the devices that tap rather than
            /// vibrate (the phone, the public engine): `strength` 0...1,
            /// `weight` crisp to heavy.
            case accent(strength: Float, weight: Float)
            /// One segment of the trackpad playing the music: the partials
            /// to sound together, at `level` 0...1 of full amplitude.
            /// Segments chain end to end, each lasting its chord's length.
            case vibration(level: Float, chord: Chord)
        }

        /// When to play, in `mach_absolute_time` ticks.
        var time: UInt64
        var kind: Kind
    }

    private struct State {
        var queue: [Item] = []
        var head = 0
        var generation = 0
        var wake: DispatchSemaphore?
    }

    private enum Step {
        case stop
        case idle
        case play(Item)
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Starts a new playback thread, ending any previous one. `play` runs
    /// on the new thread.
    func start(play: @escaping @Sendable (Item) -> Void) {
        let wake = DispatchSemaphore(value: 0)
        let (generation, previous) = state.withLock { state -> (Int, DispatchSemaphore?) in
            state.generation += 1
            state.queue.removeAll(keepingCapacity: true)
            state.head = 0
            let previous = state.wake
            state.wake = wake
            return (state.generation, previous)
        }
        previous?.signal()
        let thread = Thread { [self] in
            run(generation: generation, wake: wake, play: play)
        }
        thread.name = "com.masonchen.Tactile.music-pulses"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 1 << 16
        thread.start()
    }

    func stop() {
        let wake = state.withLock { state -> DispatchSemaphore? in
            state.generation += 1
            state.queue.removeAll()
            state.head = 0
            let wake = state.wake
            state.wake = nil
            return wake
        }
        wake?.signal()
    }

    /// Audio queue: queues a pulse. Items come in time order; nothing is
    /// queued while stopped.
    func schedule(_ item: Item) {
        let wake = state.withLock { state -> DispatchSemaphore? in
            guard let wake = state.wake else { return nil }
            if state.head > 512 {
                state.queue.removeFirst(state.head)
                state.head = 0
            }
            state.queue.append(item)
            return wake
        }
        wake?.signal()
    }

    private func run(generation: Int, wake: DispatchSemaphore, play: (Item) -> Void) {
        // A pulse this late is dropped: playing a backlog would bunch the
        // pulses up into a rattle.
        let stale = HostTime.ticks(0.012)
        while true {
            let step = state.withLock { state -> Step in
                guard state.generation == generation else { return .stop }
                guard state.head < state.queue.count else { return .idle }
                return .play(state.queue[state.head])
            }
            switch step {
            case .stop:
                return
            case .idle:
                wake.wait()
            case .play(let item):
                if item.time > mach_absolute_time() { mach_wait_until(item.time) }
                let current = state.withLock { state -> Bool in
                    guard state.generation == generation, state.head < state.queue.count else { return false }
                    state.head += 1
                    return true
                }
                guard current else { continue }
                let now = mach_absolute_time()
                if now < item.time || now - item.time <= stale { play(item) }
            }
        }
    }
}
