//
//  SettingsView.swift
//  Tactile
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            TriggerSettingsView()
                .tabItem { Label("Triggers", systemImage: "cursorarrow.rays") }
            AppExclusionView()
                .tabItem { Label("Apps", systemImage: "app.badge.checkmark") }
            SoundSettingsView()
                .tabItem { Label("Sound", systemImage: "speaker.wave.2") }
        }
        .frame(width: 480)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var permission: PermissionManager

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Enable haptic feedback", isOn: $settings.isEnabled)

                Toggle("Launch Tactile at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            try LoginItem.set(newValue)
                            loginItemError = nil
                        } catch {
                            launchAtLogin = LoginItem.isEnabled
                            loginItemError = error.localizedDescription
                        }
                    }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                LabeledSlider(
                    title: "Minimum time between taps",
                    value: $settings.rateLimitMs,
                    range: 50...500,
                    step: 25,
                    format: { "\(Int($0)) ms" },
                    caption: "Raise this if sweeping across toolbars feels too busy."
                )

                LabeledSlider(
                    title: "Dwell delay",
                    value: $settings.dwellMs,
                    range: 0...1000,
                    step: 50,
                    format: { $0 == 0 ? "Off" : "\(Int($0)) ms" },
                    caption: "When set, the cursor must rest on an element before it taps. Reduces noise and helps steady targeting."
                )
            }

            Section {
                if permission.isTrusted {
                    Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Accessibility access is required", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Open Accessibility Settings") {
                        permission.openSystemSettings()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Triggers

struct TriggerSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Text("Choose which elements tap the trackpad when the cursor passes over them, and how each one feels.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(FeedbackCategory.allCases) { category in
                    CategoryRow(category: category)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CategoryRow: View {
    @EnvironmentObject private var settings: SettingsStore
    let category: FeedbackCategory

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { settings.categoryEnabled[category] ?? category.defaultEnabled },
            set: { settings.categoryEnabled[category] = $0 }
        )
    }

    private var pattern: Binding<FeedbackPattern> {
        Binding(
            get: { settings.categoryPattern[category] ?? category.defaultPattern },
            set: { settings.categoryPattern[category] = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(category.displayName, isOn: isEnabled)

                Spacer()

                Picker("Pattern for \(category.displayName)", selection: pattern) {
                    ForEach(FeedbackPattern.allCases) { pattern in
                        Text(pattern.displayName).tag(pattern)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!isEnabled.wrappedValue)

                Button("Try") {
                    SystemHapticEngine().tick(pattern.wrappedValue)
                }
                .disabled(!isEnabled.wrappedValue)
                .accessibilityLabel("Try the pattern for \(category.displayName)")
            }
            Text(category.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Sound

struct SoundSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Play a click sound", isOn: $settings.audioEnabled)
                Text("Adds a quiet click alongside the haptic tap. Useful with an external mouse, where trackpad haptics can't be felt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledSlider(
                    title: "Click volume",
                    value: $settings.audioVolume,
                    range: 0.1...1.0,
                    step: 0.1,
                    format: { "\(Int($0 * 100))%" },
                    caption: nil
                )
                .disabled(!settings.audioEnabled)

                Button("Test Sound") {
                    let engine = AudioFeedbackEngine()
                    engine.volume = settings.audioVolume
                    engine.tick(.generic)
                }
                .disabled(!settings.audioEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shared controls

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step) {
                Text(title)
            }
            .labelsHidden()
            .accessibilityValue(format(value))
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
