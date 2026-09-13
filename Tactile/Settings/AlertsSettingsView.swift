//
//  AlertsSettingsView.swift
//  Tactile
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Haptic stand-ins for sounds you might not hear: apps starting to play
/// (a call ringing), notifications arriving, the charger connecting.
struct AlertsSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController

    /// Call apps offered first in the Add menu, when installed. Calls ring
    /// until answered, so their alerts repeat by default.
    private static let callApps = [
        "com.apple.FaceTime", "com.apple.mobilephone", "us.zoom.xos", "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "net.whatsapp.WhatsApp", "Cisco-Systems.Spark",
    ]

    var body: some View {
        let localizer = localization.localizer
        Form {
            Section {
                Toggle(localizer.string("settings.alerts.sounds.enable"), isOn: $settings.soundAlertsEnabled)
                Text(verbatim: localizer.string("settings.alerts.sounds.explanation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if settings.soundAlertRules.isEmpty {
                    Text(verbatim: localizer.string("settings.alerts.sounds.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($settings.soundAlertRules) { $rule in
                        SoundAlertRow(rule: $rule) {
                            settings.soundAlertRules.removeAll { $0.id == rule.id }
                        }
                    }
                }
                addMenu(localizer)

                HStack {
                    Toggle(localizer.string("settings.alerts.sounds.other-apps"), isOn: $settings.soundAlertOtherApps)
                    Spacer()
                    WaveformControl(
                        waveform: $settings.soundAlertOtherAppsWaveform,
                        accessibilityName: localizer.string("settings.alerts.sounds.other-apps")
                    )
                    .disabled(!settings.soundAlertOtherApps)
                }
                Toggle(localizer.string("settings.alerts.sounds.skip-frontmost"), isOn: $settings.soundAlertSkipFrontmost)
            } header: {
                Text(verbatim: localizer.string("settings.alerts.sounds.apps.section"))
            } footer: {
                Text(verbatim: localizer.string("settings.alerts.sounds.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.soundAlertsEnabled)
            .opacity(settings.soundAlertsEnabled ? 1 : 0.45)

            Section {
                HStack {
                    Toggle(localizer.string("settings.alerts.notifications"), isOn: $settings.notificationHapticsEnabled)
                    Spacer()
                    WaveformControl(
                        waveform: $settings.notificationWaveform,
                        accessibilityName: localizer.string("settings.alerts.notifications")
                    )
                    .disabled(!settings.notificationHapticsEnabled)
                }
                if PowerSourceWatcher.hasBattery {
                    HStack {
                        Toggle(localizer.string("settings.alerts.charger"), isOn: $settings.chargerHapticsEnabled)
                        Spacer()
                        WaveformControl(
                            waveform: $settings.chargerWaveform,
                            accessibilityName: localizer.string("settings.alerts.charger")
                        )
                        .disabled(!settings.chargerHapticsEnabled)
                    }
                }
            } header: {
                Text(verbatim: localizer.string("settings.alerts.system.section"))
            } footer: {
                Text(verbatim: localizer.string("settings.alerts.system.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Label(localizer.string("settings.alerts.trackpad-note"), systemImage: "hand.point.up.left.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Adding apps

    private func addMenu(_ localizer: Localizer) -> some View {
        let added = Set(settings.soundAlertRules.map(\.bundleID))
        let calls = Self.callApps.filter { !added.contains($0) && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        let running = runningApps.filter { !added.contains($0.bundleID) && !calls.contains($0.bundleID) }
        return Menu(localizer.string("settings.alerts.sounds.add")) {
            Button(localizer.string("settings.alerts.sounds.choose-applications")) { chooseFromApplications() }
            if !calls.isEmpty {
                Divider()
                Section(localizer.string("settings.alerts.sounds.suggested")) {
                    ForEach(calls, id: \.self) { bundleID in
                        Button {
                            add(bundleID)
                        } label: {
                            Text(verbatim: AppIdentity.name(for: bundleID))
                        }
                    }
                }
            }
            if !running.isEmpty {
                Divider()
                Section(localizer.string("settings.alerts.sounds.running")) {
                    ForEach(running, id: \.bundleID) { app in
                        Button {
                            add(app.bundleID)
                        } label: {
                            Text(verbatim: app.name)
                        }
                    }
                }
            }
        }
        .fixedSize()
    }

    private var runningApps: [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier else { return nil }
                return (app.localizedName ?? bundleID, bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func chooseFromApplications() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let localizer = localization.localizer
        panel.title = localizer.string("dialog.alerts.choose-apps.title")
        panel.message = localizer.string("dialog.alerts.choose-apps.message")
        panel.prompt = localizer.string("dialog.alerts.choose-apps.prompt")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier { add(bundleID) }
        }
    }

    private func add(_ bundleID: String) {
        guard !settings.soundAlertRules.contains(where: { $0.bundleID == bundleID }) else { return }
        settings.soundAlertRules.append(SoundAlertRule(
            bundleID: bundleID,
            waveform: WaveformPreset.ring.waveform,
            repeats: Self.callApps.contains(bundleID)
        ))
    }
}

/// One app: icon, name, its waveform, whether it repeats, remove.
private struct SoundAlertRow: View {
    @Binding var rule: SoundAlertRule
    let remove: () -> Void
    @EnvironmentObject private var localization: LocalizationController

    var body: some View {
        let localizer = localization.localizer
        let name = AppIdentity.name(for: rule.bundleID)
        HStack(spacing: 8) {
            AppIdentity.icon(for: rule.bundleID)
            Text(verbatim: name)
                .lineLimit(1)
                .frame(minWidth: 70, maxWidth: .infinity, alignment: .leading)
            WaveformControl(waveform: $rule.waveform, accessibilityName: name)
            Toggle(localizer.string("settings.alerts.sounds.repeat"), isOn: $rule.repeats)
                .toggleStyle(.checkbox)
                .help(localizer.string("settings.alerts.sounds.repeat.help"))
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: localizer.format("format.settings.alerts.sounds.remove", arguments: [name])))
        }
    }
}

/// App names and icons from bundle identifiers, best effort.
private enum AppIdentity {
    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    @ViewBuilder
    static func icon(for bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed")
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        }
    }
}
