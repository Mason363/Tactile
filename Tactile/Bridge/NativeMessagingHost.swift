//
//  NativeMessagingHost.swift
//  Tactile
//
//  When Chrome launches Tactile's binary as a native-messaging host, this
//  relay runs *instead of* the app. It is a dumb pipe: Chrome native-messaging
//  framing on stdin/stdout <-> newline-delimited JSON on the app's local Unix
//  socket. All intelligence lives in the long-running agent; keeping the
//  Chrome-spawned child dumb means it needs no AppKit and no accessibility.
//
//  Chrome invokes a host with the calling extension's origin as an argument,
//  so `isHostLaunch` keys off a `chrome-extension://` argv. Branching here, at
//  the very top of main, is what lets one binary be both the app and the host
//  without a second Xcode target.
//

import Darwin
import Foundation

enum NativeMessagingHost {
    /// True when this process was spawned by a browser as a native-messaging
    /// host rather than launched as the app.
    static func isHostLaunch(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains { $0.hasPrefix("chrome-extension://") }
    }

    /// Runs the relay to completion (Chrome closed stdin, or the socket
    /// dropped), then returns so `main` can exit. Never starts AppKit.
    static func run() {
        guard let sock = connectToApp() else {
            // The app isn't running / integration is off. Nothing to relay to;
            // exit cleanly and let Chrome respawn us on the next page event.
            return
        }
        defer { close(sock) }

        // socket -> stdout (app to extension). Optional today; kept so the app
        // can push config back later. Runs on its own thread.
        let pump = Thread { socketToStdout(sock) }
        pump.stackSize = 1 << 18
        pump.start()

        // stdin -> socket (extension to app), on this thread until EOF.
        stdinToSocket(sock)
    }

    // MARK: - Connection

    private static func connectToApp() -> Int32? {
        let path = BridgeConstants.socketURL.path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { src in
                strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), src)
            }
        }

        // A couple of quick retries smooth over the app still binding the
        // socket right after launch.
        for attempt in 0..<3 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            if fd < 0 { return nil }
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let ok = withUnsafePointer(to: &addr) { p -> Bool in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    connect(fd, sp, len) == 0
                }
            }
            if ok { return fd }
            close(fd)
            if attempt < 2 { usleep(100_000) }
        }
        return nil
    }

    // MARK: - stdin (Chrome framing) -> socket (newline JSON)

    private static func stdinToSocket(_ sock: Int32) {
        while let payload = readChromeMessage() {
            var line = payload
            line.append(0x0A) // '\n'
            if !writeAll(sock, line) { return }
        }
    }

    /// Reads one Chrome native message: a little-endian UInt32 length followed
    /// by that many bytes of JSON. Returns nil on EOF or malformed length.
    private static func readChromeMessage() -> [UInt8]? {
        guard let header = readExactly(0, count: 4) else { return nil }
        let length = UInt32(header[0]) | (UInt32(header[1]) << 8)
            | (UInt32(header[2]) << 16) | (UInt32(header[3]) << 24)
        if length == 0 || length > 64 * 1024 { return nil }
        return readExactly(0, count: Int(length))
    }

    // MARK: - socket (newline JSON) -> stdout (Chrome framing)

    private static func socketToStdout(_ sock: Int32) {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(sock, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let payload = Array(buffer[0..<nl])
                buffer.removeSubrange(0...nl)
                if !payload.isEmpty { writeChromeMessage(payload) }
            }
        }
    }

    private static func writeChromeMessage(_ payload: [UInt8]) {
        let len = UInt32(payload.count)
        let header: [UInt8] = [
            UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF),
            UInt8((len >> 16) & 0xFF), UInt8((len >> 24) & 0xFF),
        ]
        _ = writeAll(1, header)
        _ = writeAll(1, payload)
    }

    // MARK: - Low-level fd helpers

    private static func readExactly(_ fd: Int32, count: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = out.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress!.advanced(by: got), count - got)
            }
            if n <= 0 { return nil }
            got += n
        }
        return out
    }

    @discardableResult
    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}
