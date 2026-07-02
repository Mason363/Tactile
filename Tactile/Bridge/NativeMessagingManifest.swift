//
//  NativeMessagingManifest.swift
//  Tactile
//
//  Installs (and removes) the native-messaging host manifest Chrome reads to
//  learn how to launch Tactile as a bridge. The host executable is Tactile's
//  own binary — the same file branches into relay mode when Chrome spawns it
//  with a chrome-extension argv (see NativeMessagingHost).
//

import Foundation

enum NativeMessagingManifest {
    /// The absolute path Chrome will exec. Tactile's own binary.
    static var hostExecutablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
    }

    /// True when the manifest exists and points at the current binary — so the
    /// UI can prompt a re-install after the app is moved.
    static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: BridgeConstants.manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["path"] as? String
        else { return false }
        return path == hostExecutablePath
    }

    @discardableResult
    static func install() -> Bool {
        let manifest: [String: Any] = [
            "name": BridgeConstants.hostName,
            "description": "Tactile browser bridge",
            "path": hostExecutablePath,
            "type": "stdio",
            "allowed_origins": [BridgeConstants.extensionOrigin],
        ]
        do {
            try FileManager.default.createDirectory(
                at: BridgeConstants.chromeNativeHostsDir,
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
            try data.write(to: BridgeConstants.manifestURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func uninstall() {
        try? FileManager.default.removeItem(at: BridgeConstants.manifestURL)
    }
}
