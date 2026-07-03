//
//  BrowserBridgeServer.swift
//  Tactile
//
//  Hosts the local Unix socket the native-messaging relay connects to, decodes
//  the extension's newline-delimited JSON into BridgeMessage values, and
//  delivers them on the main thread. One relay connects at a time; when Chrome
//  respawns it (reload, restart) the old connection hits EOF and the accept
//  loop simply takes the new one.
//

import Darwin
import Foundation
import os

final class BrowserBridgeServer {
    /// Delivered on the main actor for each decoded message.
    var onEvent: (@MainActor (BridgeMessage) -> Void)?
    /// Delivered on the main actor when the relay connects (true) or drops
    /// (false), so arbitration can stop trusting a stale bridge.
    var onConnectionChange: (@MainActor (Bool) -> Void)?

    private var listenFD: Int32 = -1
    private var running = false
    private var thread: Thread?

    private let log = Logger(subsystem: "com.masonchen.Tactile", category: "bridge")

    var isRunning: Bool { running }

    func start() {
        guard !running else { return }
        guard bindAndListen() else { return }
        running = true
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "com.masonchen.Tactile.bridge"
        thread.stackSize = 1 << 19
        thread.start()
        self.thread = thread
        log.debug("bridge server listening at \(BridgeConstants.socketURL.path, privacy: .public)")
    }

    func stop() {
        guard running else { return }
        running = false
        if listenFD >= 0 {
            // Closing the listen fd unblocks the accept() in the loop thread.
            close(listenFD)
            listenFD = -1
        }
        thread = nil
        try? FileManager.default.removeItem(at: BridgeConstants.socketURL)
    }

    // MARK: - Socket setup

    private func bindAndListen() -> Bool {
        let url = BridgeConstants.socketURL
        try? FileManager.default.removeItem(at: url) // stale socket from a crash

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = url.path
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return false }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { src in
                strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), src)
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { p -> Bool in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                bind(fd, sp, len) == 0
            }
        }
        guard bound, listen(fd, 1) == 0 else {
            close(fd)
            return false
        }
        // Only this user's browser should reach it.
        chmod(path, 0o600)
        listenFD = fd
        return true
    }

    // MARK: - Accept / read

    private func acceptLoop() {
        while running {
            let client = accept(listenFD, nil, nil)
            if client < 0 { break } // listen fd closed by stop()
            deliverConnection(true)
            readLoop(client)
            deliverConnection(false)
            close(client)
        }
    }

    private func readLoop(_ fd: Int32) {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let decoder = JSONDecoder()
        while running {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return } // EOF or error: relay went away
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineBytes = buffer[0..<nl]
                buffer.removeSubrange(0...nl)
                guard !lineBytes.isEmpty,
                      let message = try? decoder.decode(BridgeMessage.self, from: Data(lineBytes))
                else { continue }
                deliver(message)
            }
            // A runaway producer shouldn't grow the buffer without bound.
            if buffer.count > 64 * 1024 { buffer.removeAll(keepingCapacity: true) }
        }
    }

    // Delivery uses DispatchQueue.main (strict FIFO), NOT unstructured Tasks:
    // Task { @MainActor } gives no ordering guarantee between separate tasks,
    // and a hover processed after the leave that followed it (or vice versa)
    // corrupts the enter/leave state machine downstream.
    private func deliver(_ message: BridgeMessage) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onEvent?(message) }
        }
    }

    private func deliverConnection(_ connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onConnectionChange?(connected) }
        }
    }
}
