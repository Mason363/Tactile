//
//  TactileApp.swift
//  Tactile
//

import SwiftUI

@main
struct TactileApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var controller = AppController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(controller)
                .environmentObject(controller.settings)
                .environmentObject(controller.permission)
        } label: {
            Image(systemName: controller.menuBarSymbol)
                .accessibilityLabel("Tactile")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(controller)
                .environmentObject(controller.settings)
                .environmentObject(controller.permission)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AppController.shared
        controller.bootstrap()
        if !controller.permission.isTrusted {
            OnboardingWindow.show(controller: controller)
        }
    }
}
