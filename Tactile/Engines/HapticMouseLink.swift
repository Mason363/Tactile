//
//  HapticMouseLink.swift
//  Tactile
//

import Foundation
import IOKit
import IOKit.hid
import os

/// The HID++ 2.0 conversation with a mouse that has a haptic motor.
///
/// HID++ is the vendor protocol every Logitech device speaks. A request is
/// one 20-byte report, `11 <slot> <feature> <function|software ID>` plus 16
/// parameter bytes, and the answer echoes those first four bytes. Features
/// sit at per-device indexes, looked up by ID through the root feature
/// (index 0). The haptic motor is feature 0x19B0:
///
///   function 0  capabilities: bytes 4...7 are a mask of the waveforms the
///               motor has, bit N for waveform N
///   function 1  configuration: flags (bit 0 = haptics on), level 0...100
///   function 2  set configuration, same layout
///   function 4  play waveform N; the answer means it was taken
///
/// The mouse is found two ways. Behind a Logi Bolt receiver it answers at
/// its pairing slot (1...6) on the receiver's vendor interface (usage page
/// FF00), and the receiver itself says which slots hold a mouse (register
/// B5, 5N). Connected directly over Bluetooth it answers at slot FF on
/// usage FF43/0202 of its single HID device; macOS opens that device only
/// with Input Monitoring, which Tactile never asks for, so the direct
/// route is taken only where that permission already exists.
///
/// Measured on an MX Master 4 over Bolt: an answer takes 12-25 ms while the
/// link is busy, and up to a second once it has been quiet for about half a
/// second (the mouse's radio naps, and a request waits for it to wake). A
/// moving mouse keeps its own link busy, so a hover tick lands at once; a
/// resting mouse never errors, it is only late. Only a mouse that is off,
/// or switched to another computer, fails.
///
/// Three rules follow. One play is in flight at a time: sending them faster
/// than the receiver drains them stalls the whole channel for seconds. A
/// play that woke the radio lands late, so the later steps of its waveform
/// are moved back by the same nap and the waveform keeps its rhythm. And a
/// tick of its own that had to wait is dropped rather than played late: the
/// cursor has moved on, and a late tick is worse than none.
///
/// Nothing here polls. The mouse is looked for when the link starts, when a
/// receiver attaches, and whenever a tick wanted it and could not have it
/// (`nudge`), which is exactly when the hand is back on it.
///
/// Everything runs on one serial queue: a stalled device blocks that queue,
/// never the feedback pipeline. Only answers carrying Tactile's software ID
/// are parsed; every other report on the channel is dropped unread.
nonisolated final class HapticMouseLink: @unchecked Sendable {
    /// What the link knows, handed to `onChange` whenever it changes.
    struct Status: Equatable, Sendable {
        /// A mouse with a haptic motor is connected, awake or resting.
        var connected = false
        /// The mouse's own name ("MX Master 4"), when it gave one.
        var name: String?
        /// It answers, so a tick sent now lands.
        var reachable = false
    }

    /// Called on the link's queue. Set once, before `start`.
    var onChange: (@Sendable (Status) -> Void)?

    /// The low nibble of every request's function byte, marking it and its
    /// answer as Tactile's. Logi Options+, Solaar, and the rest each use
    /// their own, so several can share the channel.
    private static let softwareID: UInt8 = 0x03
    private static let logitech = 0x046D
    private static let hapticFeature: UInt16 = 0x19B0
    private static let nameFeature: UInt16 = 0x0005
    /// The slot of a mouse connected directly rather than through a receiver.
    private static let directSlot: UInt8 = 0xFF
    /// HID++ 1.0 device kinds in a receiver's pairing record: mouse, trackball.
    private static let pointerKinds: Set<UInt8> = [2, 8]

    /// How long an answer may take. A resting mouse needs up to a second.
    private static let patience: TimeInterval = 2
    /// The least time between two plays.
    private static let minimumGap = UInt64(30_000_000)
    /// A play still waiting this long after it was due is dropped.
    private static let staleAfter = UInt64(80_000_000)
    /// An answer slower than this means the play woke the radio from a nap.
    private static let napAfter = UInt64(80_000_000)
    /// What an answer takes while the link is awake.
    private static let usualAnswer = UInt64(15_000_000)
    /// The most plays that wait at once.
    private static let queueLimit = 8
    /// How long the mouse's haptics switch is trusted before it is read again.
    private static let configurationLife = UInt64(60_000_000_000)
    /// The least time between two looks for a mouse that is not answering.
    private static let nudgeGap = UInt64(1_000_000_000)

    private struct Mouse {
        /// Index of the haptic feature on this device.
        var feature: UInt8
        /// The waveforms its motor has, bit N for waveform N.
        var waveforms: UInt32
        var name: String?
        var reachable = true
        /// The configuration flags and level as last read; nil until read.
        var flags: UInt8?
        var level: UInt8 = 0
        var configurationAt: UInt64 = 0
        /// A play is on its way and unanswered.
        var inFlight = false
        var sentAt: UInt64 = 0
        /// Counts plays, so a timeout can tell its own play from a later one.
        var serial = 0
        /// Plays waiting their turn, in the order they are due. A step is
        /// a later pulse of a waveform already begun.
        var waiting: [(waveform: UInt8, due: UInt64, isStep: Bool)] = []
        /// The nap the current waveform's first pulse woke the radio from,
        /// which its later steps are moved back by.
        var lag: UInt64 = 0
        /// A pump is already scheduled for the head of the queue.
        var pumpScheduled = false
    }

    private enum Answer {
        /// The reply's parameter bytes, always 16.
        case data([UInt8])
        /// Turned down with an error code, by the mouse itself or, when it
        /// could not be reached, by its receiver.
        case refused(code: UInt8, byReceiver: Bool)
        case silence
    }

    /// One HID device that carries HID++: a receiver's vendor interface or
    /// a directly connected mouse. Only ever touched on the link's queue.
    private final class Endpoint: @unchecked Sendable {
        let device: IOHIDDevice
        let isReceiver: Bool
        /// Slots that hold a mouse nobody has asked about haptics yet.
        var candidates: Set<UInt8> = []
        /// Slots whose device answered and has no haptic motor.
        var ruledOut: Set<UInt8> = []
        var probing: Set<UInt8> = []
        var mice: [UInt8: Mouse] = [:]
        var pending: [UInt32: (token: Int, handler: (Answer) -> Void)] = [:]

        init(device: IOHIDDevice, isReceiver: Bool) {
            self.device = device
            self.isReceiver = isReceiver
        }
    }

    private let queue = DispatchQueue(label: "com.masonchen.Tactile.mouse", qos: .userInteractive)
    private let log = Logger(subsystem: "com.masonchen.Tactile", category: "mouse")

    // Queue-confined state.
    private var manager: IOHIDManager?
    private var endpoints: [Endpoint] = []
    private var tokens = 0
    private var lastNudge: UInt64 = 0
    private var published = Status()

    private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

    // MARK: - Lifecycle

    /// Starts watching for a haptic mouse. Costs nothing until one shows up.
    func start() {
        queue.async { [self] in
            guard manager == nil else { return }
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            var matches: [[String: Any]] = [[
                kIOHIDVendorIDKey: Self.logitech,
                kIOHIDDeviceUsagePageKey: 0xFF00,
                kIOHIDDeviceUsageKey: 1,
            ]]
            // A Bluetooth mouse is one HID device with its pointer and keys
            // inside, which macOS guards with Input Monitoring. Opening it
            // without the permission would put up the system prompt, so it
            // is matched only where the permission was already given.
            if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted {
                matches.append([
                    kIOHIDVendorIDKey: Self.logitech,
                    kIOHIDDeviceUsagePageKey: 0xFF43,
                    kIOHIDDeviceUsageKey: 0x0202,
                ])
            }
            IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.attached, context)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.detached, context)
            IOHIDManagerRegisterInputReportCallback(manager, Self.reported, context)
            // Devices already present are reported from inside the calls
            // below, so the manager is in place first.
            self.manager = manager
            // Open comes before activation: opening registers on each
            // device, which IOKit traps on once the device is active.
            IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDispatchQueue(manager, queue)
            // The handler keeps the manager alive until cancellation is done.
            IOHIDManagerSetCancelHandler(manager) { _ = manager }
            IOHIDManagerActivate(manager)
        }
    }

    func stop() {
        queue.async { [self] in
            guard let manager else { return }
            self.manager = nil
            endpoints.removeAll()
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerCancel(manager)
            publish()
        }
    }

    /// Looks again for mice paired since the link started.
    func rescan() {
        queue.async { [self] in
            for endpoint in endpoints {
                endpoint.ruledOut.removeAll()
                if endpoint.isReceiver {
                    readPairings(endpoint)
                } else if endpoint.mice.isEmpty {
                    probe(endpoint, slot: Self.directSlot)
                }
            }
        }
    }

    /// A tick wanted the mouse and it was not answering: look for it now.
    /// Called on every such tick, so it only acts once a second.
    func nudge() {
        queue.async { [self] in
            let now = Self.now
            guard now &- lastNudge > Self.nudgeGap else { return }
            lastNudge = now
            for endpoint in endpoints {
                for slot in endpoint.candidates { probe(endpoint, slot: slot) }
                for (slot, mouse) in endpoint.mice where !mouse.reachable { probe(endpoint, slot: slot) }
            }
        }
    }

    /// Plays one of the motor's waveforms, from any thread. `isStep` marks
    /// a later pulse of a waveform already begun, which keeps its distance
    /// from the pulse before it; anything else is a tick of its own, where
    /// only the newest matters. Nothing happens while no mouse answers.
    func play(_ waveform: UInt8, isStep: Bool = false) {
        queue.async { [self] in
            guard let (endpoint, slot) = current, var mouse = endpoint.mice[slot] else { return }
            let now = Self.now
            var due = now
            if isStep {
                due &+= mouse.lag
            } else {
                mouse.lag = 0
                mouse.waiting.removeAll { !$0.isStep }
            }
            guard mouse.waiting.count < Self.queueLimit else { return }
            let index = mouse.waiting.firstIndex { $0.due > due } ?? mouse.waiting.endIndex
            mouse.waiting.insert((waveform, due, isStep), at: index)
            endpoint.mice[slot] = mouse
            pump(endpoint, slot: slot)
        }
    }

    // MARK: - Devices

    private static let attached: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<HapticMouseLink>.fromOpaque(context).takeUnretainedValue().attach(device)
    }

    private static let detached: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<HapticMouseLink>.fromOpaque(context).takeUnretainedValue().detach(device)
    }

    private static let reported: IOHIDReportCallback = { context, _, sender, _, reportID, report, length in
        guard let context, let sender else { return }
        let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
        Unmanaged<HapticMouseLink>.fromOpaque(context).takeUnretainedValue()
            .receive(device, id: UInt8(truncatingIfNeeded: reportID), UnsafeBufferPointer(start: report, count: length))
    }

    private func attach(_ device: IOHIDDevice) {
        guard manager != nil, endpoint(for: device) == nil else { return }
        let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] ?? []
        func has(_ page: Int, _ usage: Int) -> Bool {
            pairs.contains {
                $0[kIOHIDDeviceUsagePageKey] as? Int == page && $0[kIOHIDDeviceUsageKey] as? Int == usage
            }
        }
        if has(0xFF43, 0x0202) {
            let endpoint = Endpoint(device: device, isReceiver: false)
            endpoint.candidates = [Self.directSlot]
            endpoints.append(endpoint)
            probe(endpoint, slot: Self.directSlot)
        } else if has(0xFF00, 1), has(0xFF00, 2) {
            // Short and long collections together are the mark of HID++.
            let endpoint = Endpoint(device: device, isReceiver: true)
            endpoints.append(endpoint)
            readPairings(endpoint)
        }
    }

    private func detach(_ device: IOHIDDevice) {
        endpoints.removeAll { CFEqual($0.device, device) }
        publish()
    }

    private func endpoint(for device: IOHIDDevice) -> Endpoint? {
        endpoints.first { CFEqual($0.device, device) }
    }

    /// The mouse ticks go to: the first one that answers.
    private var current: (Endpoint, UInt8)? {
        for endpoint in endpoints {
            for (slot, mouse) in endpoint.mice where mouse.reachable { return (endpoint, slot) }
        }
        return nil
    }

    // MARK: - Finding the mouse

    /// Asks a receiver for the pairing record of each slot. Paired slots
    /// answer even while their device sleeps; empty ones answer with an
    /// error that is simply not acted on.
    private func readPairings(_ endpoint: Endpoint) {
        for slot: UInt8 in 1...6 {
            let report: [UInt8] = [0x10, 0xFF, 0x83, 0xB5, 0x50 + slot, 0, 0]
            _ = IOHIDDeviceSetReport(endpoint.device, kIOHIDReportTypeOutput, 0x10, report, report.count)
        }
    }

    /// Asks one slot whether it has a haptic motor, then learns the rest.
    /// Also how a known mouse that stopped answering is found again.
    private func probe(_ endpoint: Endpoint, slot: UInt8) {
        guard endpoint.probing.insert(slot).inserted else { return }
        let id = Self.hapticFeature
        ask(endpoint, slot: slot, feature: 0, function: 0, [UInt8(id >> 8), UInt8(id & 0xFF)]) { [self] answer in
            switch answer {
            case .data(let data) where data[0] != 0:
                if var mouse = endpoint.mice[slot] {
                    mouse.feature = data[0]
                    mouse.reachable = true
                    mouse.inFlight = false
                    mouse.waiting.removeAll()
                    endpoint.mice[slot] = mouse
                    endpoint.probing.remove(slot)
                    readConfiguration(endpoint, slot: slot)
                    publish()
                } else {
                    describe(endpoint, slot: slot, feature: data[0])
                }
            case .data, .refused(code: 1, byReceiver: true):
                // It answered and has no haptics, or does not speak HID++ 2.0.
                endpoint.probing.remove(slot)
                endpoint.candidates.remove(slot)
                endpoint.ruledOut.insert(slot)
            case .refused, .silence:
                // Off, or away on another computer. The next nudge asks again.
                endpoint.probing.remove(slot)
            }
        }
    }

    /// Reads a newly found mouse's waveforms and name, then lists it.
    private func describe(_ endpoint: Endpoint, slot: UInt8, feature: UInt8) {
        ask(endpoint, slot: slot, feature: feature, function: 0) { [self] answer in
            guard case .data(let data) = answer else {
                endpoint.probing.remove(slot)
                return
            }
            let waveforms = UInt32(data[4]) << 24 | UInt32(data[5]) << 16 | UInt32(data[6]) << 8 | UInt32(data[7])
            readName(endpoint, slot: slot) { [self] name in
                endpoint.probing.remove(slot)
                endpoint.candidates.remove(slot)
                let product = endpoint.isReceiver
                    ? nil
                    : IOHIDDeviceGetProperty(endpoint.device, kIOHIDProductKey as CFString) as? String
                endpoint.mice[slot] = Mouse(feature: feature, waveforms: waveforms, name: name ?? product)
                log.debug("mouse found slot=\(slot, privacy: .public) feature=\(feature, privacy: .public) waveforms=\(waveforms, privacy: .public)")
                readConfiguration(endpoint, slot: slot)
                publish()
            }
        }
    }

    /// The device's own name, through feature 0x0005: its length, then the
    /// characters 16 at a time.
    private func readName(_ endpoint: Endpoint, slot: UInt8, then: @escaping (String?) -> Void) {
        let id = Self.nameFeature
        ask(endpoint, slot: slot, feature: 0, function: 0, [UInt8(id >> 8), UInt8(id & 0xFF)]) { [self] answer in
            guard case .data(let data) = answer, data[0] != 0 else { return then(nil) }
            let feature = data[0]
            ask(endpoint, slot: slot, feature: feature, function: 0) { [self] answer in
                guard case .data(let data) = answer, data[0] != 0 else { return then(nil) }
                readName(endpoint, slot: slot, feature: feature, length: min(Int(data[0]), 64), collected: [], then: then)
            }
        }
    }

    private func readName(_ endpoint: Endpoint, slot: UInt8, feature: UInt8, length: Int,
                          collected: [UInt8], then: @escaping (String?) -> Void) {
        ask(endpoint, slot: slot, feature: feature, function: 1, [UInt8(collected.count)]) { [self] answer in
            guard case .data(let data) = answer else { return then(nil) }
            let all = collected + data.prefix(length - collected.count)
            if all.count >= length {
                then(String(bytes: all, encoding: .utf8))
            } else {
                readName(endpoint, slot: slot, feature: feature, length: length, collected: all, then: then)
            }
        }
    }

    /// Reads whether haptics are switched on at the mouse, and how strong.
    private func readConfiguration(_ endpoint: Endpoint, slot: UInt8) {
        guard let feature = endpoint.mice[slot]?.feature else { return }
        ask(endpoint, slot: slot, feature: feature, function: 1) { answer in
            guard case .data(let data) = answer, var mouse = endpoint.mice[slot] else { return }
            mouse.flags = data[0]
            mouse.level = data[1]
            mouse.configurationAt = Self.now
            endpoint.mice[slot] = mouse
        }
    }

    // MARK: - Playing

    /// Sends the next waiting play once it is due, nothing is in flight,
    /// and the last send is far enough behind.
    private func pump(_ endpoint: Endpoint, slot: UInt8) {
        guard var mouse = endpoint.mice[slot], mouse.reachable, !mouse.inFlight else { return }
        let now = Self.now
        while let first = mouse.waiting.first, now > first.due &+ Self.staleAfter {
            mouse.waiting.removeFirst()
        }
        guard let next = mouse.waiting.first else {
            endpoint.mice[slot] = mouse
            return
        }
        let ready = max(next.due, mouse.sentAt &+ Self.minimumGap)
        if now < ready {
            if !mouse.pumpScheduled {
                mouse.pumpScheduled = true
                queue.asyncAfter(deadline: .now() + .nanoseconds(Int(ready - now))) { [self] in
                    endpoint.mice[slot]?.pumpScheduled = false
                    pump(endpoint, slot: slot)
                }
            }
            endpoint.mice[slot] = mouse
            return
        }
        mouse.waiting.removeFirst()

        // Haptics switched off at the mouse take plays and do nothing with
        // them, so they are switched on first. The level stays as it is set.
        if let flags = mouse.flags, flags & 1 == 0 {
            mouse.flags = flags | 1
            write(endpoint, slot: slot, feature: mouse.feature, function: 2, [flags | 1, mouse.level])
        }
        mouse.inFlight = true
        mouse.sentAt = now
        mouse.serial += 1
        let serial = mouse.serial
        endpoint.mice[slot] = mouse
        let waveform = Self.playable(next.waveform, of: mouse.waveforms)
        guard write(endpoint, slot: slot, feature: mouse.feature, function: 4, [waveform]) else {
            lost(endpoint, slot: slot)
            return
        }
        queue.asyncAfter(deadline: .now() + Self.patience) { [self] in
            guard let mouse = endpoint.mice[slot], mouse.inFlight, mouse.serial == serial else { return }
            lost(endpoint, slot: slot)
        }
    }

    /// The play was taken: the next one may go.
    private func played(_ endpoint: Endpoint, slot: UInt8) {
        guard var mouse = endpoint.mice[slot], mouse.inFlight else { return }
        mouse.inFlight = false
        let now = Self.now
        let took = now &- mouse.sentAt
        if took > Self.napAfter {
            // The play woke the radio and landed only now. The steps
            // behind it, waiting or still to come, keep their distance.
            let nap = took - Self.usualAnswer
            mouse.lag &+= nap
            for index in mouse.waiting.indices where mouse.waiting[index].isStep {
                mouse.waiting[index].due &+= nap
            }
        }
        endpoint.mice[slot] = mouse
        if now &- mouse.configurationAt > Self.configurationLife {
            readConfiguration(endpoint, slot: slot)
        }
        pump(endpoint, slot: slot)
    }

    /// The mouse stopped answering. Ticks go elsewhere until a nudge finds
    /// it again.
    private func lost(_ endpoint: Endpoint, slot: UInt8) {
        guard var mouse = endpoint.mice[slot], mouse.reachable else { return }
        mouse.reachable = false
        mouse.inFlight = false
        mouse.waiting.removeAll()
        endpoint.mice[slot] = mouse
        log.debug("mouse lost slot=\(slot, privacy: .public)")
        publish()
    }

    /// The waveform to send for a wanted one: itself where the motor has
    /// it, else the nearest tick the motor does have.
    private static func playable(_ waveform: UInt8, of waveforms: UInt32) -> UInt8 {
        func has(_ id: UInt8) -> Bool { id < 32 && waveforms & (1 << UInt32(id)) != 0 }
        if waveforms == 0 || has(waveform) { return waveform }
        return [3, 2, 4, 0, 1].first(where: has) ?? UInt8(waveforms.trailingZeroBitCount)
    }

    // MARK: - Wire

    @discardableResult
    private func write(_ endpoint: Endpoint, slot: UInt8, feature: UInt8, function: UInt8,
                       _ parameters: [UInt8] = []) -> Bool {
        var report = [UInt8](repeating: 0, count: 20)
        report[0] = 0x11
        report[1] = slot
        report[2] = feature
        report[3] = function << 4 | Self.softwareID
        for (index, value) in parameters.prefix(16).enumerated() { report[4 + index] = value }
        return IOHIDDeviceSetReport(endpoint.device, kIOHIDReportTypeOutput, 0x11, report, report.count) == kIOReturnSuccess
    }

    private static func key(slot: UInt8, feature: UInt8, function: UInt8) -> UInt32 {
        UInt32(slot) << 16 | UInt32(feature) << 8 | UInt32(function)
    }

    /// Sends a request and hands its answer to `then`, exactly once.
    private func ask(_ endpoint: Endpoint, slot: UInt8, feature: UInt8, function: UInt8,
                     _ parameters: [UInt8] = [], then: @escaping (Answer) -> Void) {
        let key = Self.key(slot: slot, feature: feature, function: function)
        tokens += 1
        let token = tokens
        if let replaced = endpoint.pending.updateValue((token, then), forKey: key) {
            replaced.handler(.silence)
        }
        guard write(endpoint, slot: slot, feature: feature, function: function, parameters) else {
            endpoint.pending[key] = nil
            then(.silence)
            return
        }
        queue.asyncAfter(deadline: .now() + Self.patience) {
            guard let waiting = endpoint.pending[key], waiting.token == token else { return }
            endpoint.pending[key] = nil
            waiting.handler(.silence)
        }
    }

    private func receive(_ device: IOHIDDevice, id: UInt8, _ report: UnsafeBufferPointer<UInt8>) {
        guard id == 0x10 || id == 0x11, let endpoint = endpoint(for: device) else { return }
        // The report arrives with or without its ID byte in front.
        var bytes = Array(report)
        if bytes.first != id { bytes.insert(id, at: 0) }
        guard bytes.count >= 7 else { return }

        if endpoint.isReceiver, bytes[1] == 0xFF {
            // The receiver speaking for itself: a paired slot's record,
            // whose second byte is the kind of device paired there.
            if bytes[2] == 0x83, bytes[3] == 0xB5, bytes[4] & 0xF0 == 0x50 {
                let slot = bytes[4] & 0x0F
                guard (1...6).contains(slot), Self.pointerKinds.contains(bytes[5] & 0x0F),
                      endpoint.mice[slot] == nil, !endpoint.ruledOut.contains(slot)
                else { return }
                endpoint.candidates.insert(slot)
                probe(endpoint, slot: slot)
            }
            return
        }

        // A mouse connected directly may answer under another index.
        let slot = endpoint.isReceiver ? bytes[1] : Self.directSlot
        let feature: UInt8
        let stamp: UInt8
        let answer: Answer
        switch bytes[2] {
        case 0xFF:
            (feature, stamp, answer) = (bytes[3], bytes[4], .refused(code: bytes[5], byReceiver: false))
        case 0x8F:
            (feature, stamp, answer) = (bytes[3], bytes[4], .refused(code: bytes[5], byReceiver: true))
        default:
            var data = Array(bytes[4...])
            if data.count < 16 { data += [UInt8](repeating: 0, count: 16 - data.count) }
            (feature, stamp, answer) = (bytes[2], bytes[3], .data(data))
        }
        // Someone else's conversation, or the mouse's own events.
        guard stamp & 0x0F == Self.softwareID else { return }
        let function = stamp >> 4

        if function == 4, let mouse = endpoint.mice[slot], mouse.feature == feature {
            if case .refused(_, byReceiver: true) = answer {
                lost(endpoint, slot: slot)
            } else {
                played(endpoint, slot: slot)
            }
            return
        }
        let key = Self.key(slot: slot, feature: feature, function: function)
        guard let waiting = endpoint.pending.removeValue(forKey: key) else { return }
        waiting.handler(answer)
    }

    // MARK: - Status

    private func publish() {
        var status = Status()
        let mice = endpoints.flatMap { $0.mice.values }
        if let mouse = mice.first(where: \.reachable) ?? mice.first {
            status = Status(connected: true, name: mouse.name, reachable: mouse.reachable)
        }
        guard status != published else { return }
        published = status
        onChange?(status)
    }
}
