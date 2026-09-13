//
//  AudioCapturePermission.swift
//  Tactile
//

import AppKit

/// The "System Audio Recording Only" permission music haptics needs
/// (Privacy & Security > Screen & System Audio Recording). macOS has no
/// public call to read or request it ahead of use, so this resolves the
/// system's privacy functions at runtime, the same way the actuator engine
/// loads MultitouchSupport. If they're missing, the status reads as
/// undetermined and macOS asks on its own the first time the tap starts.
enum AudioCapturePermission {
    enum Status {
        case authorized
        case denied
        case undetermined
    }

    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @escaping @Sendable @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let preflight: PreflightFunc? = framework
        .flatMap { dlsym($0, "TCCAccessPreflight") }
        .map { unsafeBitCast($0, to: PreflightFunc.self) }
    private static let requestAccess: RequestFunc? = framework
        .flatMap { dlsym($0, "TCCAccessRequest") }
        .map { unsafeBitCast($0, to: RequestFunc.self) }

    static var status: Status {
        guard let preflight else { return .undetermined }
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .undetermined
        }
    }

    /// Whether the privacy functions are there, so `status` is the
    /// system's answer rather than a guess.
    static var canCheck: Bool { preflight != nil }

    /// Shows the system's permission prompt. Without the privacy functions
    /// it reports `nil`: the tap itself will prompt when it starts.
    static func request(_ completion: @escaping @MainActor (Bool?) -> Void) {
        guard let requestAccess else {
            completion(nil)
            return
        }
        requestAccess(service, nil) { granted in
            Task { @MainActor in completion(granted) }
        }
    }

    static func openSystemSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
    }
}
