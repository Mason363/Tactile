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
            // for menu bar appearance. Built as an NSImage with isTemplate set
            // explicitly — MenuBarExtra doesn't reliably honor the asset
            // catalog's template intent. The slash glyph stays as the
            // at-a-glance signal that accessibility permission is missing.
            if controller.permission.isTrusted {
                Image(nsImage: Self.menuBarIcon)
                    .accessibilityLabel("Tactile")
            } else {
                Image(systemName: "cursorarrow.slash")
                    .accessibilityLabel("Tactile — accessibility access needed")
            }
        }
        .menuBarExtraStyle(.menu)
    }

    private static let menuBarIcon: NSImage = {
        let image = NSImage(named: "MenuBarIcon") ?? NSImage()
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two instances means two event taps and doubled haptics on every
        // element. The newest launch wins; older instances are shut down.
        // (Chrome's native-messaging relay runs the same binary but never
        // registers as an app, so it's unaffected.)
        if let bundleID = Bundle.main.bundleIdentifier {
            let mine = ProcessInfo.processInfo.processIdentifier
            for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            where other.processIdentifier != mine {
                other.forceTerminate()
            }
        }

        let controller = AppController.shared
        controller.bootstrap()
        // Start Sparkle so background update checks are scheduled.
        _ = Updater.shared
        if !controller.permission.isTrusted {
            OnboardingWindow.show(controller: controller)
        }
    }
}
