//
//  PhoneHapticEngine.swift
//  Tactile
//
//  Routes ticks to an iPhone running Coast (github.com/Mason363/Coast), the
//  app that turns a phone into a Mac trackpad and mouse. Coast's Mac app
//  hosts a Unix socket in its Application Support folder and relays each
//  pulse to the phone it is connected to, where it plays as a Core Haptics
//  transient - so the hand moving the cursor feels the ticks even when it
//  isn't on a trackpad. Local socket only, the same privacy shape as the
//  browser bridge: Tactile still has no network of its own.
//
//  This engine is the socket's client. While the pipeline runs it keeps one
//  connection up (quietly retrying whenever Coast appears), learns whether a
//  phone is reachable - which is what offers the iPhone in the device
//  chooser - and turns each tick into one small JSON line:
//
//    Tactile -> Coast:  {"type":"tick","intensity":0.65,"sharpness":0.5}
//                       {"type":"claim","active":true}
//    Coast -> Tactile:  {"type":"phones","phones":[{"name":"iPhone","active":true}]}
//
//  "claim" tells Coast that Tactile owns hover feedback for the phone right
//  now, so Coast's own (much simpler) hover ticks stand down instead of
//  double-firing the same element.
//

import Combine
import Darwin
import Foundation
import os

final class PhoneHapticEngine: ObservableObject {
    static let shared = PhoneHapticEngine()

    /// The phone ticks would reach right now (Coast's active device), nil
    /// while Coast isn't running or has no phone connected. Main-thread
    /// published; the device chooser watches it.
    @Published private(set) var phoneName: String?

    var isAvailable: Bool { phoneName != nil }

    /// True while the pipeline targets the phone AND can reach it - the
    /// condition for settings previews to route here too.
    var isCurrentTarget: Bool {
        lock.lock()
        let claimed = wantsClaim
        lock.unlock()
        return claimed && isAvailable
    }

    private static let socketURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CoastMac", isDirectory: true)
        .appendingPathComponent("tactile.sock")

    private struct Incoming: Decodable {
        struct Phone: Decodable {
            let name: String
            let active: Bool?
        }
        let type: String
        let phones: [Phone]?
    }

    /// Guards `fd`, `generation`, and `wantsClaim` (connect thread vs.
    /// main-thread callers vs. the write queue).
    private let lock = NSLock()
    /// Writes leave the caller's thread: a wedged Coast must block this
    /// queue, never the feedback pipeline.
    private let writeQueue = DispatchQueue(label: "com.masonchen.Tactile.coast.write")
    private var fd: Int32 = -1
    /// Generation counting makes start/stop race-free, same shape as the
    /// actuator's buzz thread: a connect thread exits the moment it's stale.
    private var generation = 0
    private var wantsClaim = false

    private let log = Logger(subsystem: "com.masonchen.Tactile", category: "coast")

    /// Starts the connect loop. Runs while the pipeline runs; costs a
    /// file-system stat every few seconds when Coast isn't installed.
    func start() {
        lock.lock()
        generation += 1
        let mine = generation
        lock.unlock()
        let thread = Thread { [weak self] in self?.run(mine) }
        thread.name = "com.masonchen.Tactile.coast"
        thread.stackSize = 1 << 19
        thread.start()
    }

    /// Stops the loop and drops the connection; Coast sees the EOF and
    /// clears any claim on its side.
    func stop() {
        lock.lock()
        generation += 1
        if fd >= 0 {
            close(fd) // unblocks the read loop
            fd = -1
        }
        lock.unlock()
        setPhoneName(nil)
    }

    /// Whether Tactile's device choice targets the phone. Sent when it
    /// changes and again on every (re)connect, so Coast's view can never
    /// go stale across restarts on either side.
    func setClaim(_ claimed: Bool) {
        lock.lock()
        let changed = wantsClaim != claimed
        wantsClaim = claimed
        lock.unlock()
        if changed { sendClaimLine() }
    }

    // MARK: - FeedbackEngine

    /// Coast plays each pulse as a transient with these exact parameters,
    /// chosen next to its own signatures (hover 0.4/0.3, click 1.0/1.0):
    /// Light sits just above its hover tick, Firm is a click-class tap.
    private static func feel(_ pattern: FeedbackPattern) -> (intensity: Double, sharpness: Double) {
        switch pattern {
        case .alignment: return (0.42, 0.4)
        case .generic: return (0.65, 0.5)
        case .levelChange: return (1.0, 0.65)
        }
    }

    func tick(_ pattern: FeedbackPattern) {
        let feel = Self.feel(pattern)
        send(line: "{\"type\":\"tick\",\"intensity\":\(feel.intensity),\"sharpness\":\(feel.sharpness)}")
    }

    // MARK: - Connect loop

    private func isCurrent(_ mine: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == mine
    }

    private func run(_ mine: Int) {
        while isCurrent(mine) {
            if let connected = connectSocket() {
                lock.lock()
                let stillMine = generation == mine
                if stillMine { fd = connected }
                lock.unlock()
                guard stillMine else { close(connected); return }
                log.debug("coast bridge connected")
                sendClaimLine()
                readLoop(connected, mine)
                lock.lock()
                if fd == connected { fd = -1 }
                lock.unlock()
                close(connected)
                setPhoneName(nil)
            }
            // Coast not running (or it dropped): look again shortly.
            for _ in 0..<30 where isCurrent(mine) {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    private func connectSocket() -> Int32? {
        let path = Self.socketURL.path
        // No socket file means no Coast: skip the syscall dance.
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        // Coast gone mid-write must be an error return, not SIGPIPE.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
                   &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { src in
                strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), src)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { p -> Bool in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(fd, sp, len) == 0
            }
        }
        guard ok else {
            close(fd) // stale socket file (Coast crashed): retry later
            return nil
        }
        return fd
    }

    private func readLoop(_ fd: Int32, _ mine: Int) {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let decoder = JSONDecoder()
        while isCurrent(mine) {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return } // EOF or error: Coast went away
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineBytes = buffer[0..<nl]
                buffer.removeSubrange(0...nl)
                guard !lineBytes.isEmpty,
                      let message = try? decoder.decode(Incoming.self, from: Data(lineBytes)),
                      message.type == "phones"
                else { continue }
                let phones = message.phones ?? []
                // The active phone is the one being used as the mouse -
                // exactly the hand that should feel the ticks.
                let name = phones.first(where: { $0.active == true })?.name
                    ?? phones.first?.name
                setPhoneName(name)
            }
            if buffer.count > 64 * 1024 { buffer.removeAll(keepingCapacity: true) }
        }
    }

    private func setPhoneName(_ name: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.phoneName != name else { return }
            self.log.debug("coast phone \(name ?? "gone", privacy: .public)")
            self.phoneName = name
        }
    }

    // MARK: - Write

    private func sendClaimLine() {
        lock.lock()
        let claimed = wantsClaim
        lock.unlock()
        send(line: "{\"type\":\"claim\",\"active\":\(claimed)}")
    }

    private func send(line: String) {
        var data = Data(line.utf8)
        data.append(0x0A)
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let fd = self.fd
            self.lock.unlock()
            guard fd >= 0 else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, base.advanced(by: offset), raw.count - offset)
                    if n <= 0 { return }
                    offset += n
                }
            }
        }
    }
}

extension PhoneHapticEngine: FeedbackEngine {}
