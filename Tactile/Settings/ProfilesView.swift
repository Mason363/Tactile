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
    @State private var newProfileName = ""
    @State private var ioMessage: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("New profile name", text: $newProfileName)
                    Button("Save Current") {
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
                    Text("No profiles yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($settings.profiles) { $profile in
                        HStack {
                            Image(systemName: settings.activeProfileID == profile.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(settings.activeProfileID == profile.id ? Color.accentColor : Color.secondary)
                                .accessibilityLabel(settings.activeProfileID == profile.id ? "Active profile" : "Inactive profile")
                            TextField("Profile name", text: $profile.name)
                                .textFieldStyle(.plain)
                            Spacer()
                            Button("Apply") {
                                settings.applyProfile(profile)
                            }
                            Menu {
                                Button("Update with Current Settings") {
                                    profile.snapshot = settings.makeSnapshot()
                                    settings.activeProfileID = profile.id
                                }
                                Button("Duplicate") {
                                    var copy = profile
                                    copy.id = UUID()
                                    copy.name = profile.name + " Copy"
                                    settings.profiles.append(copy)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    settings.appProfiles = settings.appProfiles.filter { $0.value != profile.id }
                                    settings.profiles.removeAll { $0.id == profile.id }
                                    if settings.activeProfileID == profile.id { settings.activeProfileID = nil }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .accessibilityLabel("More actions for \(profile.name)")
                        }
                    }
                }
            } header: {
                Text("Saved Profiles")
            } footer: {
                Text("A profile is a snapshot of every setting. Click a name to rename it. Switch here or from the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if settings.appProfiles.isEmpty {
                    Text("No app assignments")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedAssignments, id: \.self) { bundleID in
                        AppProfileRow(bundleID: bundleID)
                    }
                }

                Menu("Assign App…") {
                    Button("Choose from Applications…") { chooseFromApplications() }
                    if !runningApps.isEmpty {
                        Divider()
                        ForEach(runningApps, id: \.bundleID) { app in
                            Button(app.name) { assign(app.bundleID) }
                        }
                    }
                }
                .fixedSize()
                .disabled(settings.profiles.isEmpty)
            } header: {
                Text("Per-App Profiles")
            } footer: {
                Text(settings.profiles.isEmpty
                     ? "Save a profile first, then assign it to apps."
                     : "Entering an assigned app switches to its profile; leaving switches back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Import & Export") {
                HStack {
                    Button("Export Settings…") { exportSettings() }
                    Button("Import Settings…") { importSettings() }
                }
                Text("Settings travel as a JSON file. Share your setup or move it to another Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let ioMessage {
                    Text(ioMessage)
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
        panel.message = "Choose apps to give their own profile"
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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings.makeSnapshot()).write(to: url)
            ioMessage = "Exported to \(url.lastPathComponent)."
        } catch {
            ioMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: data)
            settings.apply(snapshot)
            ioMessage = "Imported \(url.lastPathComponent)."
        } catch {
            ioMessage = "Import failed: not a valid Tactile settings file."
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
            Text(appName(bundleID))
            Spacer()
            Picker("Profile for \(appName(bundleID))", selection: assigned) {
                ForEach(settings.profiles) { profile in
                    Text(profile.name).tag(UUID?.some(profile.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            Button {
                settings.appProfiles.removeValue(forKey: bundleID)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove assignment for \(appName(bundleID))")
        }
    }
}
