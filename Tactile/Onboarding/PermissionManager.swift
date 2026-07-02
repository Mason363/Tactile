//
//  PermissionManager.swift
//  Tactile
//

import AppKit
import ApplicationServices
import Combine

/// Tracks the Accessibility permission Tactile needs to inspect UI elements
/// under the cursor. Polls for the grant only while the user is actively
/// being onboarded, never in steady state.
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var isTrusted: Bool = AXIsProcessTrusted()

    private var pollTimer: Timer?

    func refresh() {
        isTrusted = AXIsProcessTrusted()
    }

    /// Shows the system dialog directing the user to the Accessibility pane.
    func promptForPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        beginPolling()
    }

    func openSystemSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
        beginPolling()
    }

    /// Watches for the grant while the onboarding flow is on screen.
    func beginPolling() {
        guard pollTimer == nil, !isTrusted else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                if self.isTrusted { self.endPolling() }
            }
        }
    }

    func endPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
