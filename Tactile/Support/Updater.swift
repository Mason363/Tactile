//
//  Updater.swift
//  Tactile
//
//  Wraps Sparkle's standard updater so the rest of the app can trigger an
//  update check without importing Sparkle everywhere. The updater reads its
//  feed URL and public key from Info.plist (SUFeedURL / SUPublicEDKey) and,
//  with SUEnableAutomaticChecks, checks quietly in the background.
//

import Combine
import Sparkle

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    /// Mirrors Sparkle's own readiness so the menu item can disable itself
    /// while a check is already in flight.
    @Published private(set) var canCheckForUpdates = false

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Shows Sparkle's standard "checking / up to date / update available" UI.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
