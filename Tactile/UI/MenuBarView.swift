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
            Label(localization.localizer.string("menu.no-haptic-trackpad"), systemImage: "exclamationmark.triangle.fill")
            Text(verbatim: localization.localizer.string("menu.trackpad-requirement"))
            Divider()
        }

        if !permission.isTrusted {
            Button(localization.localizer.string("menu.grant-accessibility")) {
                OnboardingWindow.show(controller: controller)
            }
            Divider()
        }

        Toggle(localization.localizer.string("menu.haptic-feedback"), isOn: $settings.isEnabled)
            .disabled(!permission.isTrusted)

        if let until = controller.pausedUntil {
            Button {
                controller.resume()
            } label: {
                Text(verbatim: localization.localizer.format(
                    "menu.resume-paused-until",
                    // The user's own clock (region and 24-hour setting), not
                    // the language pack's region-less locale.
                    until.formatted(date: .omitted, time: .shortened)
                ))
            }
        } else {
            Button(localization.localizer.string("menu.pause-15-minutes")) {
                controller.pause(for: 15 * 60)
            }
            .disabled(!settings.isEnabled || !permission.isTrusted)
        }

        Toggle(localization.localizer.string("menu.feel-music"), isOn: $settings.musicHapticsEnabled)
            .disabled(!settings.isEnabled || !permission.isTrusted)

        Divider()

        if !settings.profiles.isEmpty {
            Menu(localization.localizer.string("menu.profiles")) {
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

        Button(localization.localizer.string("menu.settings")) {
            SettingsWindow.show(controller: controller)
        }
        .keyboardShortcut(",")

        Button(localization.localizer.string("menu.check-for-updates")) {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)

        Divider()

        Button(localization.localizer.string("menu.quit-tactile")) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
