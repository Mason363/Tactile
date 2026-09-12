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
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var localization: LocalizationController
    @State private var selection: String?

    var body: some View {
        Form {
            BrowserIntegrationSection()

            Section {
                if settings.excludedBundleIDs.isEmpty {
                    Text(verbatim: localization.localizer.string("settings.apps.excluded.empty"))
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
                    Menu(localization.localizer.string("settings.apps.excluded.add")) {
                        Button(localization.localizer.string("settings.apps.excluded.choose-applications")) {
                            chooseFromApplications()
                        }
                        Divider()
                        ForEach(runningApps, id: \.bundleID) { app in
                            Button {
                                add(app.bundleID)
                            } label: {
                                Text(verbatim: app.name)
                            }
                        }
                    }
                    .fixedSize()

                    Button(localization.localizer.string("settings.apps.excluded.remove")) {
                        if let selection {
                            settings.excludedBundleIDs.removeAll { $0 == selection }
                            self.selection = nil
                        }
                    }
                    .disabled(selection == nil)
                }
            } header: {
                Text(verbatim: localization.localizer.string("settings.apps.excluded.title"))
            } footer: {
                Text(verbatim: localization.localizer.string("settings.apps.excluded.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        let localizer = localization.localizer
        panel.title = localizer.string("dialog.apps.choose-excluded.title")
        panel.message = localizer.string("dialog.apps.choose-excluded.message")
        panel.prompt = localizer.string("dialog.apps.choose-excluded.prompt")
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

/// Chrome browser-integration controls: the toggle, the native-messaging host
/// install status, and the Chrome Web Store link for the companion extension.
private struct BrowserIntegrationSection: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var localization: LocalizationController
    @State private var statusTick = 0

    var body: some View {
        Section(localization.localizer.string("settings.apps.browser.title")) {
            Toggle(localization.localizer.string("settings.apps.browser.toggle"), isOn: $settings.browserIntegrationEnabled)
            Text(verbatim: localization.localizer.string("settings.apps.browser.description"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.browserIntegrationEnabled {
                LabeledContent(localization.localizer.string("settings.apps.browser.messaging-host")) {
                    if installed {
                        Label(localization.localizer.string("settings.apps.browser.installed"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label(localization.localizer.string("settings.apps.browser.not-set-up"), systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }

                Button(localization.localizer.string("settings.apps.browser.setup-host")) {
                    controller.reinstallBrowserBridge()
                    statusTick += 1
                }

                Text(verbatim: localization.localizer.string("settings.apps.browser.extension-description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Link(localization.localizer.string("settings.apps.browser.get-extension"),
                     destination: URL(string: "https://chromewebstore.google.com/detail/bkpkcddffbjipobgjlagggbbldefpldo?utm_source=item-share-cb")!)
                    .font(.caption)
            }
        }
    }

    /// Re-read whenever the setup button bumps the tick or the toggle flips.
    private var installed: Bool {
        _ = statusTick
        return controller.browserBridgeInstalled
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
                Text(verbatim: Bundle(url: url)?.localizedName ?? bundleID)
            } else {
                Image(systemName: "app.dashed")
                    .accessibilityHidden(true)
                Text(verbatim: bundleID)
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
