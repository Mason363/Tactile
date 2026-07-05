//
//  MenuBarView.swift
//  Tactile
//

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var permission: PermissionManager
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        if !ActuatorHapticEngine.hasHapticTrackpad {
            Label("No haptic trackpad detected", systemImage: "exclamationmark.triangle.fill")
            Text("Tactile needs a Force Touch trackpad to produce feedback.")
            Divider()
        }

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

        if !settings.profiles.isEmpty {
            Menu("Profiles") {
                ForEach(settings.profiles) { profile in
                    Toggle(profile.name, isOn: Binding(
                        get: { settings.activeProfileID == profile.id },
                        set: { _ in settings.applyProfile(profile) }
                    ))
                }
            }
        }

        Button("Settings…") {
            SettingsWindow.show(controller: controller)
        }
        .keyboardShortcut(",")

        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)

        Divider()

        Button("Quit Tactile") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
