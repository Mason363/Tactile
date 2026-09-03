//
//  ProfilesView.swift
//  Tactile
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Named settings profiles: save, rename in place, switch (here or from the
/// menu bar), assign per app, and move as JSON.
struct ProfilesView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController
    @State private var newProfileName = ""
    @State private var ioMessage: IOMessage?

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("settings.profiles.new-profile-name", text: $newProfileName)
                    Button("settings.profiles.save-current") {
                        let name = newProfileName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        settings.profiles.removeAll { $0.name == name }
                        let profile = SettingsProfile(name: name, snapshot: settings.makeSnapshot())
                        settings.profiles.append(profile)
                        settings.activeProfileID = profile.id
                        newProfileName = ""
                    }
                    .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if settings.profiles.isEmpty {
                    Text("settings.profiles.no-profiles")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($settings.profiles) { $profile in
                        HStack {
                            Image(systemName: settings.activeProfileID == profile.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(settings.activeProfileID == profile.id ? Color.accentColor : Color.secondary)
                                .accessibilityLabel(Text(verbatim: localization.localizer.string(
                                    settings.activeProfileID == profile.id
                                        ? "settings.profiles.active-profile"
                                        : "settings.profiles.inactive-profile"
                                )))
                            TextField("settings.profiles.profile-name", text: $profile.name)
                                .textFieldStyle(.plain)
                            Spacer()
                            Button("settings.profiles.apply") {
                                settings.applyProfile(profile)
                            }
                            Menu {
                                Button("settings.profiles.update-with-current") {
                                    profile.snapshot = settings.makeSnapshot()
                                    settings.activeProfileID = profile.id
                                }
                                Button("settings.profiles.duplicate") {
                                    var copy = profile
                                    copy.id = UUID()
                                    copy.name = localization.localizer.format(
                                        "format.profile-copy-name",
                                        profile.name
                                    )
                                    settings.profiles.append(copy)
                                }
                                Divider()
                                Button("settings.profiles.delete", role: .destructive) {
                                    settings.appProfiles = settings.appProfiles.filter { $0.value != profile.id }
                                    settings.profiles.removeAll { $0.id == profile.id }
                                    if settings.activeProfileID == profile.id { settings.activeProfileID = nil }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .accessibilityLabel(Text(verbatim: localization.localizer.format(
                                "format.profile-more-actions",
                                profile.name
                            )))
                        }
                    }
                }
            } header: {
                Text("settings.profiles.saved-profiles")
            } footer: {
                Text("settings.profiles.saved-profiles-help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if settings.appProfiles.isEmpty {
                    Text("settings.profiles.no-app-assignments")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedAssignments, id: \.self) { bundleID in
                        AppProfileRow(bundleID: bundleID)
                    }
                }

                Menu("settings.profiles.assign-app") {
                    Button("settings.profiles.choose-applications") { chooseFromApplications() }
                    if !runningApps.isEmpty {
                        Divider()
                        ForEach(runningApps, id: \.bundleID) { app in
                            Button {
                                assign(app.bundleID)
                            } label: {
                                Text(verbatim: app.name)
                            }
                        }
                    }
                }
                .fixedSize()
                .disabled(settings.profiles.isEmpty)
            } header: {
                Text("settings.profiles.per-app-profiles")
            } footer: {
                Text(verbatim: localization.localizer.string(
                    settings.profiles.isEmpty
                        ? "settings.profiles.per-app-empty-help"
                        : "settings.profiles.per-app-help"
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.profiles.import-export") {
                HStack {
                    Button("settings.profiles.export-settings") { exportSettings() }
                    Button("settings.profiles.import-settings") { importSettings() }
                }
                Text("settings.profiles.import-export-help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let ioMessage {
                    Text(verbatim: ioMessage.localized(using: localization.localizer))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var sortedAssignments: [String] {
        settings.appProfiles.keys.sorted {
            appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending
        }
    }

    private var runningApps: [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier,
                      bundleID != Bundle.main.bundleIdentifier,
                      settings.appProfiles[bundleID] == nil
                else { return nil }
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
        panel.title = localization.localizer.string("dialog.profiles.choose-apps.title")
        panel.message = localization.localizer.string("dialog.profiles.choose-apps.message")
        panel.prompt = localization.localizer.string("dialog.profiles.choose-apps.prompt")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier {
                assign(bundleID)
            }
        }
    }

    private func assign(_ bundleID: String) {
        guard settings.appProfiles[bundleID] == nil, let first = settings.profiles.first else { return }
        settings.appProfiles[bundleID] = first.id
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "TactileSettings.json"
        panel.title = localization.localizer.string("dialog.profiles.export.title")
        panel.prompt = localization.localizer.string("dialog.profiles.export.prompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings.makeSnapshot()).write(to: url)
            ioMessage = .exported(fileName: url.lastPathComponent)
        } catch {
            ioMessage = .exportFailed(description: error.localizedDescription)
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = localization.localizer.string("dialog.profiles.import.title")
        panel.message = localization.localizer.string("dialog.profiles.import.message")
        panel.prompt = localization.localizer.string("dialog.profiles.import.prompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: data)
            settings.apply(snapshot)
            ioMessage = .imported(fileName: url.lastPathComponent)
        } catch {
            ioMessage = .importFailed
        }
    }
}

private enum IOMessage {
    case exported(fileName: String)
    case exportFailed(description: String)
    case imported(fileName: String)
    case importFailed

    func localized(using localizer: Localizer) -> String {
        switch self {
        case .exported(let fileName):
            return localizer.format(
                "format.profiles-exported",
                fileName
            )
        case .exportFailed(let description):
            return localizer.format(
                "format.profiles-export-failed",
                description
            )
        case .imported(let fileName):
            return localizer.format(
                "format.profiles-imported",
                fileName
            )
        case .importFailed:
            return localizer.string("error.profiles.invalid-settings-file")
        }
    }
}

/// Human name for a bundle identifier, best effort.
private func appName(_ bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
    return FileManager.default.displayName(atPath: url.path)
        .replacingOccurrences(of: ".app", with: "")
}

/// One app assignment: icon, name, profile picker, remove.
private struct AppProfileRow: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController
    let bundleID: String

    private var assigned: Binding<UUID?> {
        Binding(
            get: { settings.appProfiles[bundleID] },
            set: { newValue in
                if let newValue { settings.appProfiles[bundleID] = newValue }
            }
        )
    }

    var body: some View {
        HStack {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
            Text(verbatim: appName(bundleID))
            Spacer()
            Picker(selection: assigned) {
                ForEach(settings.profiles) { profile in
                    Text(verbatim: profile.name).tag(UUID?.some(profile.id))
                }
            } label: {
                Text(verbatim: localization.localizer.format(
                    "format.profile-for-app",
                    appName(bundleID)
                ))
            }
            .labelsHidden()
            .fixedSize()
            Button {
                settings.appProfiles.removeValue(forKey: bundleID)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: localization.localizer.format(
                "format.profile-remove-assignment",
                appName(bundleID)
            )))
        }
    }
}
