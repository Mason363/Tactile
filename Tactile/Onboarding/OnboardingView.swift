//
//  OnboardingView.swift
//  Tactile
//

import SwiftUI
import Combine

/// First-launch window that explains what Tactile does and walks the user
/// through granting the Accessibility permission.
struct OnboardingView: View {
    @EnvironmentObject private var permission: PermissionManager
    @EnvironmentObject private var localization: LocalizationController

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: permission.isTrusted ? "checkmark.circle.fill" : "cursorarrow.rays")
                .font(.system(size: 48))
                .foregroundStyle(permission.isTrusted ? .green : .accentColor)
                .accessibilityHidden(true)

            Text(verbatim: localization.localizer.string(
                permission.isTrusted ? "onboarding.ready-title" : "onboarding.welcome-title"
            ))
                .font(.title.bold())

            if !ActuatorHapticEngine.hasHapticTrackpad {
                Label {
                    Text(verbatim: localization.localizer.string("onboarding.no-haptic-trackpad"))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }

            if permission.isTrusted {
                Text(verbatim: localization.localizer.string("onboarding.trusted-description"))
                    .multilineTextAlignment(.center)

                Button(localization.localizer.string("onboarding.done")) {
                    OnboardingWindow.close()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Text(verbatim: localization.localizer.string("onboarding.introduction"))
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        Text(verbatim: localization.localizer.string("onboarding.permission-explanation"))
                    } icon: {
                        Image(systemName: "accessibility")
                    }
                    Label {
                        Text(verbatim: localization.localizer.string("onboarding.privacy-explanation"))
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                    Label {
                        Text(verbatim: localization.localizer.string("onboarding.revoke-explanation"))
                    } icon: {
                        Image(systemName: "gearshape")
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: localization.localizer.string("onboarding.step-1"))
                    Text(verbatim: localization.localizer.string("onboarding.step-2"))
                    Text(verbatim: localization.localizer.string("onboarding.step-3"))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(localization.localizer.string("onboarding.open-accessibility-settings")) {
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
    private static var titleObservation: AnyCancellable?

    static func show(controller: AppController) {
        if window == nil {
            let content = OnboardingView()
                .environmentObject(controller)
                .environmentObject(controller.permission)
            let view = LocalizedRoot(localization: controller.localization, content: content)
            let hosting = NSHostingController(rootView: view)
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = controller.localization.localizer.string("window.onboarding.title")
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
            titleObservation = controller.localization.$resolvedPack
                .sink { [weak newWindow, weak controller] pack in
                    guard let controller else { return }
                    newWindow?.title = Localizer(
                        pack: pack, fallback: controller.localization.registry.englishPack
                    ).string("window.onboarding.title")
                }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
    }
}
