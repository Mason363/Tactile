//
//  BridgeProtocol.swift
//  Tactile
//
//  Shared contract between the browser extension, the native-messaging host
//  relay, and the in-app socket server. Kept dependency-light (Foundation
//  only) because it is used from the host relay, which runs before — and
//  entirely without — AppKit.
//

import Foundation

/// One message from the extension. Sent as newline-delimited JSON over the
/// local Unix socket; the extension emits one only when the hovered clickable's
/// identity changes.
struct BridgeMessage: Codable {
    /// "hover" — the cursor is over a clickable; "leave" — it isn't.
    var type: String
    /// FeedbackCategory raw value, present on "hover".
    var el: String?
    var enabled: Bool?
    var on: Bool?
    var danger: Bool?
    /// Whether this is a "primary" target (a result-title link, a prominent
    /// labeled control) versus an incidental one (three-dot menu, favicon,
    /// "Read more"). Used by Simple mode to fire only on the primary targets.
    var primary: Bool?
    /// Whether the cursor is inside the page. false means it moved to browser
    /// chrome or another window, so the accessibility path should take over.
    var inViewport: Bool?
}

/// Well-known identifiers and file locations the three parts must agree on.
enum BridgeConstants {
    static let hostName = "com.masonchen.tactile.bridge"

    /// The extension's pinned ID (from its manifest `key`).
    static let extensionID = "fnbpgacidfliigibfomikmdgbblccmie"

    static var extensionOrigin: String { "chrome-extension://\(extensionID)/" }

    /// Chrome's per-profile native-messaging host directory (default profile).
    static var chromeNativeHostsDir: URL {
        homeLibrary
            .appendingPathComponent("Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
    }

    static var manifestURL: URL {
        chromeNativeHostsDir.appendingPathComponent("\(hostName).json")
    }

    /// The Unix domain socket the app hosts and the relay connects to. Kept
    /// short and stable so it stays under the ~104-char sockaddr_un limit.
    static var socketURL: URL {
        appSupportDir.appendingPathComponent("bridge.sock")
    }

    /// `~/Library/Application Support/Tactile`, created on demand.
    static var appSupportDir: URL {
        let dir = homeLibrary.appendingPathComponent("Application Support/Tactile", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `~/Library`. Resolved from the real home directory rather than a
    /// sandbox container — Tactile is unsandboxed and the relay runs as a bare
    /// child of Chrome.
    private static var homeLibrary: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
    }
}
