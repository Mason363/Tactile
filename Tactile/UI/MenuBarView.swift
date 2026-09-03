//
//  MenuBarView.swift
//  Tactile
//

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var permission: PermissionManager
    @EnvironmentObject private var localization: LocalizationController
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        if !ActuatorHapticEngine.hasHapticTrackpad {
            Label("menu.no-haptic-trackpad", systemImage: "exclamationmark.triangle.fill")
            Text("menu.trackpad-requirement")
            Divider()
        }

        if !permission.isTrusted {
            Button("menu.grant-accessibility") {
                OnboardingWindow.show(controller: controller)
            }
            Divider()
        }

        Toggle("menu.haptic-feedback", isOn: $settings.isEnabled)
            .disabled(!permission.isTrusted)

        if let until = controller.pausedUntil {
            Button {
                controller.resume()
            } label: {
                Text(verbatim: localization.localizer.format(
                    "menu.resume-paused-until",
                    until.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(localization.locale))
                ))
            }
        } else {
            Button("menu.pause-15-minutes") {
                controller.pause(for: 15 * 60)
            }
            .disabled(!settings.isEnabled || !permission.isTrusted)
        }

        Divider()

        if !settings.profiles.isEmpty {
            Menu("menu.profiles") {
                ForEach(settings.profiles) { profile in
                    Toggle(isOn: Binding(
                        get: { settings.activeProfileID == profile.id },
                        set: { _ in settings.applyProfile(profile) }
                    )) {
                        Text(verbatim: profile.name)
                    }
                }
            }
        }

        Button("menu.settings") {
            SettingsWindow.show(controller: controller)
        }
        .keyboardShortcut(",")

        Button("menu.check-for-updates") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)

        Divider()

        Button("menu.quit-tactile") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
