//
//  ProfilesView.swift
//  Tactile
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Named settings profiles plus JSON import/export of the full configuration.
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
                        settings.profiles.append(SettingsProfile(name: name, snapshot: settings.makeSnapshot()))
                        newProfileName = ""
                    }
                    .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if settings.profiles.isEmpty {
                    Text("No profiles yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.profiles) { profile in
                        HStack {
                            Text(profile.name)
                            Spacer()
                            Button("Apply") {
                                settings.apply(profile.snapshot)
                            }
                            Button("Delete") {
                                settings.profiles.removeAll { $0.id == profile.id }
                            }
                            .accessibilityLabel("Delete profile \(profile.name)")
                        }
                    }
                }
            } header: {
                Text("Saved Profiles")
            } footer: {
                Text("A profile is a snapshot of every setting. Switch from here or straight from the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Import & Export") {
                HStack {
                    Button("Export Settings…") { exportSettings() }
                    Button("Import Settings…") { importSettings() }
                }
                Text("Settings travel as a JSON file — share your haptic setup or move it to another Mac.")
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
            ioMessage = "Import failed — not a valid Tactile settings file."
        }
    }
}
