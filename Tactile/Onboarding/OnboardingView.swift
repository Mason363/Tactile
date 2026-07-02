//
//  OnboardingView.swift
//  Tactile
//

import SwiftUI

/// First-launch window that explains what Tactile does and walks the user
/// through granting the Accessibility permission.
struct OnboardingView: View {
    @EnvironmentObject private var permission: PermissionManager

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: permission.isTrusted ? "checkmark.circle.fill" : "cursorarrow.rays")
                .font(.system(size: 48))
                .foregroundStyle(permission.isTrusted ? .green : .accentColor)
                .accessibilityHidden(true)

            Text(permission.isTrusted ? "You're All Set" : "Welcome to Tactile")
                .font(.title.bold())

            if permission.isTrusted {
                Text("Tactile is now running in your menu bar. Move the cursor over buttons, links, and other controls to feel them under your finger.")
                    .multilineTextAlignment(.center)

                Button("Done") {
                    OnboardingWindow.close()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Text("Tactile taps the trackpad's haptic motor whenever your cursor passes over something clickable — so you can feel the interface, not just see it.")
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 10) {
                    Label("Tactile needs the Accessibility permission to know what is under your cursor.", systemImage: "accessibility")
                    Label("Everything happens on your Mac. Tactile only looks at the type of element under the cursor — never at your content.", systemImage: "lock.shield")
                    Label("You can revoke the permission at any time in System Settings.", systemImage: "gearshape")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Click the button below to open System Settings.")
                    Text("2. Find Tactile in the list and turn it on.")
                    Text("3. Come back here — Tactile starts automatically.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Open Accessibility Settings") {
                    permission.openSystemSettings()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
        }
        .padding(28)
        .frame(width: 440)
        .onAppear { permission.beginPolling() }
        .onDisappear { permission.endPolling() }
    }
}

/// Hosts the onboarding view in a standalone window that can be shown from
/// anywhere (app launch, menu bar) without a WindowGroup scene.
@MainActor
enum OnboardingWindow {
    private static var window: NSWindow?

    static func show(controller: AppController) {
        if window == nil {
            let view = OnboardingView()
                .environmentObject(controller)
                .environmentObject(controller.permission)
            let hosting = NSHostingController(rootView: view)
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "Welcome to Tactile"
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
    }
}
