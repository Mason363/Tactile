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
                        .fixedSize(horizontal: false, vertical: true)
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
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)

                Button(localization.localizer.string("onboarding.done")) {
                    OnboardingWindow.close()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Text(verbatim: localization.localizer.string("onboarding.introduction"))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        Text(verbatim: localization.localizer.string("onboarding.permission-explanation"))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "accessibility")
                    }
                    Label {
                        Text(verbatim: localization.localizer.string("onboarding.privacy-explanation"))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                    Label {
                        Text(verbatim: localization.localizer.string("onboarding.revoke-explanation"))
                            .fixedSize(horizontal: false, vertical: true)
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
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: localization.localizer.string("onboarding.step-2"))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: localization.localizer.string("onboarding.step-3"))
                        .fixedSize(horizontal: false, vertical: true)
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
            // Own the window size instead of feeding SwiftUI's automatic
            // min/max measurements back into the AppKit constraint pass.
            hosting.sizingOptions = []
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = controller.localization.localizer.string("window.onboarding.title")
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            resize(newWindow, toFit: hosting)
            newWindow.center()
            window = newWindow
            titleObservation = controller.localization.$resolvedPack
                .combineLatest(controller.permission.$isTrusted)
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak newWindow, weak controller, weak hosting] pack, _ in
                    guard let controller, let newWindow, let hosting else { return }
                    newWindow.title = Localizer(
                        pack: pack, fallback: controller.localization.registry.englishPack
                    ).string("window.onboarding.title")
                    resize(newWindow, toFit: hosting)
                }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
    }

    private static func resize<Content: View>(
        _ window: NSWindow, toFit hosting: NSHostingController<Content>
    ) {
        let measured = hosting.sizeThatFits(in: CGSize(width: 440, height: 10_000))
        guard measured.height.isFinite, measured.height > 0 else { return }
        window.setContentSize(NSSize(width: 440, height: ceil(measured.height)))
    }
}
