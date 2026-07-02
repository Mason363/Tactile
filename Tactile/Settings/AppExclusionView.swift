//
//  AppExclusionView.swift
//  Tactile
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Manages the list of apps Tactile stays silent in.
struct AppExclusionView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var selection: String?

    var body: some View {
        Form {
            Section {
                Text("Tactile won't give feedback while the cursor is over these apps. Useful for games, drawing canvases, or anything that gets noisy.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                if settings.excludedBundleIDs.isEmpty {
                    Text("No excluded apps")
                        .foregroundStyle(.secondary)
                } else {
                    List(selection: $selection) {
                        ForEach(settings.excludedBundleIDs, id: \.self) { bundleID in
                            ExcludedAppRow(bundleID: bundleID)
                                .tag(bundleID)
                        }
                    }
                    .frame(minHeight: 160)
                }

                HStack {
                    Menu("Add App…") {
                        Button("Choose from Applications…") {
                            chooseFromApplications()
                        }
                        Divider()
                        ForEach(runningApps, id: \.bundleID) { app in
                            Button(app.name) {
                                add(app.bundleID)
                            }
                        }
                    }
                    .fixedSize()

                    Button("Remove") {
                        if let selection {
                            settings.excludedBundleIDs.removeAll { $0 == selection }
                            self.selection = nil
                        }
                    }
                    .disabled(selection == nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var runningApps: [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier,
                      bundleID != Bundle.main.bundleIdentifier,
                      !settings.excludedBundleIDs.contains(bundleID)
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
        panel.message = "Choose apps to exclude from haptic feedback"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier {
                add(bundleID)
            }
        }
    }

    private func add(_ bundleID: String) {
        guard !settings.excludedBundleIDs.contains(bundleID) else { return }
        settings.excludedBundleIDs.append(bundleID)
    }
}

private struct ExcludedAppRow: View {
    let bundleID: String

    var body: some View {
        HStack {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(Bundle(url: url)?.localizedName ?? bundleID)
            } else {
                Image(systemName: "app.dashed")
                    .accessibilityHidden(true)
                Text(bundleID)
            }
        }
    }
}

private extension Bundle {
    var localizedName: String? {
        object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? object(forInfoDictionaryKey: "CFBundleName") as? String
    }
}
