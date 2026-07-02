//
//  MenuBarView.swift
//  Tactile
//

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var permission: PermissionManager

    var body: some View {
        if !permission.isTrusted {
            Button("Grant Accessibility Access…") {
                OnboardingWindow.show(controller: controller)
            }
            Divider()
        }

        Toggle("Haptic Feedback", isOn: $settings.isEnabled)
            .disabled(!permission.isTrusted)

        if let until = controller.pausedUntil {
            Button("Resume (paused until \(until.formatted(date: .omitted, time: .shortened)))") {
                controller.resume()
            }
        } else {
            Button("Pause for 15 Minutes") {
                controller.pause(for: 15 * 60)
            }
            .disabled(!settings.isEnabled || !permission.isTrusted)
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Tactile") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
