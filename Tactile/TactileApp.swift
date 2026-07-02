//
//  TactileApp.swift
//  Tactile
//

import SwiftUI

// Entry point lives in main.swift so the process can branch into the
// native-messaging relay before AppKit initializes. See NativeMessagingHost.
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
            // The braille-T mark, as a template image so the system tints it
            // for menu bar appearance. The slash glyph stays as the at-a-glance
            // signal that accessibility permission is missing.
            if controller.permission.isTrusted {
                Image("MenuBarIcon")
                    .accessibilityLabel("Tactile")
            } else {
                Image(systemName: "cursorarrow.slash")
                    .accessibilityLabel("Tactile — accessibility access needed")
            }
        }
        .menuBarExtraStyle(.menu)
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
