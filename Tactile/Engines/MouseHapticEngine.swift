//
//  MouseHapticEngine.swift
//  Tactile
//
//  Routes ticks to a mouse with a haptic motor of its own: the Logitech MX
//  Master 4, which has one under the thumb. The hand moving the cursor
//  feels the ticks in the mouse, no trackpad involved.
//
//  The mouse is driven natively, over the vendor protocol it already
//  speaks (see `HapticMouseLink`): no Logitech software takes part, and
//  Logi Options+ can run alongside. Same privacy shape as the rest of
//  Tactile: no network, and nothing is read from the mouse but the answers
//  to Tactile's own requests, never its movement, buttons, or keys.
//
//  The mouse is a choice in the device chooser while it is connected, and
//  the choice outlives it: a mouse that is asleep, off, or left at the desk
//  hands feedback back to the trackpads until it answers again.
//

import Combine
import Foundation

final class MouseHapticEngine: ObservableObject {
    static let shared = MouseHapticEngine()

    /// A mouse with a haptic motor is connected, awake or resting. Main
    /// thread published; the device chooser watches it.
    @Published private(set) var isConnected = false
    /// The mouse's own name ("MX Master 4"), when it gave one.
    @Published private(set) var mouseName: String?
    /// The mouse answers, so a tick sent now lands.
    @Published private(set) var isAvailable = false

    /// The device choice, mirrored from settings like the actuator's target.
    var target: HapticDeviceTarget = .all

    /// Who wants the mouse watched. The link runs while anyone does.
    enum Holder {
        case pipeline
        case onboarding
    }

    private var holders: Set<Holder> = []
    private let link = HapticMouseLink()

    private init() {
        link.onChange = { status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MouseHapticEngine.shared.apply(status) }
            }
        }
    }

    private func apply(_ status: HapticMouseLink.Status) {
        // A stopped link's last word can arrive after the next start.
        guard !holders.isEmpty || !status.connected else { return }
        if isConnected != status.connected { isConnected = status.connected }
        if mouseName != status.name { mouseName = status.name }
        if isAvailable != status.reachable { isAvailable = status.reachable }
    }

    /// Starts watching for a haptic mouse on behalf of `holder`. Costs
    /// nothing while none is around: the link waits for the system to
    /// report one.
    func hold(_ holder: Holder) {
        guard holders.insert(holder).inserted, holders.count == 1 else { return }
        link.start()
    }

    func release(_ holder: Holder) {
        guard holders.remove(holder) != nil, holders.isEmpty else { return }
        link.stop()
        apply(HapticMouseLink.Status())
    }

    /// Looks again for a mouse paired since the watch began.
    func rescan() {
        link.rescan()
    }

    // MARK: - Routing

    /// True when this Mac has no haptic trackpad, so the mouse is the only
    /// thing Tactile can tap and needs no choosing.
    private var isOnlyDevice: Bool { ActuatorHapticEngine.shared == nil }

    /// Whether the mouse is where feedback is meant to go: it was chosen,
    /// or there is nothing else.
    var isWanted: Bool { target == .mouse || isOnlyDevice }

    /// Whether a tick fired right now belongs in the mouse. It follows the
    /// hand: a finger on a haptic trackpad feels the tick there instead,
    /// since a mouse nobody is holding only rattles on the desk.
    var carriesTick: Bool {
        guard isWanted else { return false }
        guard isAvailable else {
            // Wanted and not answering: the hand may just be back on it.
            link.nudge()
            return false
        }
        // A contact frame in the last moment is proof enough of a finger;
        // only its absence would need the tracker to be trusted.
        if ActuatorHapticEngine.shared?.touches?.isTouching == true { return false }
        return true
    }

    // MARK: - FeedbackEngine

    /// The motor's built-in waveforms that are over in an instant, by their
    /// HID++ IDs. The rest of its table (0x05...0x0E: alerts, jingles, a
    /// ringing) are whole patterns seconds long, no use as a tick.
    nonisolated enum Tick: UInt8 {
        case sharpStateChange = 0x00
        case dampStateChange = 0x01
        case sharpCollision = 0x02
        case dampCollision = 0x03
        case subtleCollision = 0x04
        case whisperCollision = 0x1B
    }

    /// Light, Standard, and Firm as the mouse's three collisions, crisper
    /// as they get stronger. How hard they all hit is the mouse's own
    /// haptic level, set in Logi Options+ and left alone here.
    nonisolated static func tick(for pattern: FeedbackPattern) -> Tick {
        switch pattern {
        case .alignment: return .subtleCollision
        case .generic: return .dampCollision
        case .levelChange: return .sharpCollision
        }
    }

    func tick(_ pattern: FeedbackPattern) {
        link.play(Self.tick(for: pattern).rawValue)
    }

    /// A later pulse of a waveform already begun. The mouse's radio naps
    /// when idle and wakes late; said this way, the pulse keeps its
    /// distance from the one before it instead of bunching up behind it.
    func step(_ pattern: FeedbackPattern) {
        link.play(Self.tick(for: pattern).rawValue, isStep: true)
    }

    // MARK: - Pulses from any thread

    /// The mouse for music haptics, which play from their own timing
    /// thread. The mouse cannot hold a pitch, so music reaches it as taps.
    nonisolated struct Pulser: Sendable {
        fileprivate let link: HapticMouseLink

        func accent(strength: Float) {
            let tick: Tick = strength > 0.66 ? .sharpCollision : strength > 0.33 ? .dampCollision : .subtleCollision
            link.play(tick.rawValue)
        }
    }

    func makePulser() -> Pulser {
        Pulser(link: link)
    }
}

extension MouseHapticEngine: FeedbackEngine {}
