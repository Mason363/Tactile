//
//  SettingsView.swift
//  Tactile
//
//  A System Settings–style window: a sidebar of focused panes instead of a
//  crowded tab strip. Each pane owns one idea, explains itself in one line,
//  and previews what it changes wherever a preview is possible.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - Panes

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case haptics
    case vibration
    case keyboard
    case music
    case alerts
    case studio
    case context
    case visual
    case sound
    case performance
    case apps
    case profiles
    case playground
    case about

    var id: String { rawValue }

    var titleKey: String { "settings.pane.\(rawValue).title" }
    var subtitleKey: String { "settings.pane.\(rawValue).subtitle" }

    func localizedTitle(using localizer: Localizer) -> String {
        localizer.string(titleKey)
    }

    func localizedSubtitle(using localizer: Localizer) -> String {
        localizer.string(subtitleKey)
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .haptics: return "cursorarrow.rays"
        case .vibration: return "waveform.path"
        case .keyboard: return "keyboard.fill"
        case .music: return "music.note"
        case .alerts: return "bell.badge.fill"
        case .studio: return "slider.vertical.3"
        case .context: return "exclamationmark.triangle.fill"
        case .visual: return "eye.fill"
        case .sound: return "speaker.wave.2.fill"
        case .performance: return "gauge.with.needle.fill"
        case .apps: return "macwindow.on.rectangle"
        case .profiles: return "person.crop.rectangle.stack.fill"
        case .playground: return "hand.point.up.left.fill"
        case .about: return "info.circle.fill"
        }
    }

    var chipColor: Color {
        switch self {
        case .general: return .gray
        case .haptics: return .blue
        case .vibration: return .purple
        case .keyboard: return .mint
        case .music: return Color(red: 0.93, green: 0.22, blue: 0.45)
        case .alerts: return Color(red: 0.96, green: 0.42, blue: 0.14)
        case .studio: return .red
        case .context: return .orange
        case .visual: return .green
        case .sound: return .pink
        case .performance: return .teal
        case .apps: return .indigo
        case .profiles: return .brown
        case .playground: return .cyan
        case .about: return Color(nsColor: .systemGray)
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @EnvironmentObject private var localization: LocalizationController
    @State private var pane: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section(localization.localizer.string("settings.sidebar.feedback")) {
                    sidebarRow(.general)
                    sidebarRow(.haptics)
                    sidebarRow(.vibration)
                    sidebarRow(.keyboard)
                    sidebarRow(.music)
                    sidebarRow(.alerts)
                    sidebarRow(.studio)
                    sidebarRow(.context)
                    sidebarRow(.visual)
                    sidebarRow(.sound)
                }
                Section(localization.localizer.string("settings.sidebar.system")) {
                    sidebarRow(.performance)
                    sidebarRow(.apps)
                    sidebarRow(.profiles)
                }
                Section(localization.localizer.string("settings.sidebar.try-it")) {
                    sidebarRow(.playground)
                }
                Section {
                    sidebarRow(.about)
                }
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            VStack(spacing: 0) {
                PaneHeader(pane: pane)
                detailView
            }
            .navigationTitle(pane.localizedTitle(using: localization.localizer))
        }
        .frame(width: 780, height: 560)
    }

    private func sidebarRow(_ pane: SettingsPane) -> some View {
        Label {
            Text(verbatim: pane.localizedTitle(using: localization.localizer))
        } icon: {
            Image(systemName: pane.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(pane.chipColor.gradient, in: RoundedRectangle(cornerRadius: 6))
        }
        .tag(pane)
    }

    @ViewBuilder
    private var detailView: some View {
        switch pane {
        case .general: GeneralSettingsView()
        case .haptics: HapticsSettingsView()
        case .vibration: VibrationSettingsView()
        case .keyboard: KeyboardSettingsView()
        case .music: MusicSettingsView()
        case .alerts: AlertsSettingsView()
        case .studio: HapticStudioView()
        case .context: ContextSettingsView()
        case .visual: VisualAidsView()
        case .sound: SoundSettingsView()
        case .performance: PerformanceSettingsView()
        case .apps: AppExclusionView()
        case .profiles: ProfilesView()
        case .playground: PlaygroundView()
        case .about: AboutView()
        }
    }
}

/// Title + one-line description at the top of every pane, so each page
/// explains itself once instead of every control carrying a paragraph.
private struct PaneHeader: View {
    @EnvironmentObject private var localization: LocalizationController
    let pane: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: pane.localizedTitle(using: localization.localizer))
                .font(.title2.bold())
            Text(verbatim: pane.localizedSubtitle(using: localization.localizer))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Window

/// Hosts the settings in a window Tactile manages itself. SwiftUI's
/// `Settings` scene is unreliable from a MenuBarExtra in an LSUIElement app,
/// so this guarantees the window actually opens and comes to the front.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static var titleObservation: AnyCancellable?

    static func show(controller: AppController) {
        if window == nil {
            let content = SettingsView()
                .environmentObject(controller)
                .environmentObject(controller.settings)
                .environmentObject(controller.permission)
            let view = LocalizedRoot(localization: controller.localization, content: content)
            let hosting = NSHostingController(rootView: view)
            // The root view's fixed frame sizes the window, titlebar safe
            // area included. Forcing a content size would clip every pane.
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = controller.localization.localizer.string("window.settings.title")
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            newWindow.titlebarAppearsTransparent = true
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
            titleObservation = controller.localization.$resolvedPack
                .dropFirst()
                .sink { [weak newWindow, weak controller] pack in
                    guard let controller else { return }
                    newWindow?.title = Localizer(
                        pack: pack, fallback: controller.localization.registry.englishPack
                    ).string("window.settings.title")
                }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var permission: PermissionManager
    @EnvironmentObject private var localization: LocalizationController

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?
    /// Device choices to offer, empty unless several trackpads are
    /// connected or a Coast iPhone is reachable.
    @State private var deviceTargets: [HapticDeviceTarget] = []
    /// Coast bridge: publishes the reachable phone's name.
    @ObservedObject private var phone = PhoneHapticEngine.shared

    var body: some View {
        Form {
            Section(localization.localizer.string("settings.general.language.section")) {
                Picker(localization.localizer.string("settings.general.language.picker"), selection: $settings.languageSelection) {
                    Text(verbatim: localization.localizer.string("language.system"))
                        .tag(LanguageSelection.system)
                    ForEach(localization.registry.packs) { pack in
                        Text(verbatim: pack.nativeDisplayName)
                            .tag(LanguageSelection.pack(identifier: pack.identifier))
                    }
                }
            }

            Section {
                Toggle(localization.localizer.string("settings.general.enable-feedback"), isOn: $settings.isEnabled)
                Toggle(localization.localizer.string("settings.general.launch-at-login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            try LoginItem.set(newValue)
                            loginItemError = nil
                        } catch {
                            launchAtLogin = LoginItem.isEnabled
                            loginItemError = error.localizedDescription
                        }
                    }
                if let loginItemError {
                    Text(verbatim: loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if deviceTargets.count > 1 {
                Section(localization.localizer.string("settings.general.devices.section")) {
                    Picker(localization.localizer.string("settings.general.devices.picker"), selection: $settings.hapticDevice) {
                        ForEach(deviceTargets) { target in
                            Text(verbatim: label(for: target)).tag(target)
                        }
                    }
                    .onChange(of: settings.hapticDevice) { _, newValue in
                        // Tap the new destination so the choice is felt there.
                        if newValue == .iphone {
                            phone.tick(.generic)
                            return
                        }
                        guard let engine = ActuatorHapticEngine.shared else { return }
                        engine.target = newValue
                        engine.tick(.generic)
                    }
                    Text(verbatim: localization.localizer.string(
                        phone.isAvailable
                            ? "settings.general.devices.coast-help"
                            : "settings.general.devices.trackpads-help"
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(localization.localizer.string("settings.general.permission.section")) {
                if permission.isTrusted {
                    Label(localization.localizer.string("settings.general.permission.granted"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label(localization.localizer.string("settings.general.permission.required"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button(localization.localizer.string("settings.general.permission.open-settings")) {
                        permission.openSystemSettings()
                    }
                }
                Text(verbatim: localization.localizer.string("settings.general.permission.explanation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onAppear(perform: refreshDeviceTargets)
        .onChange(of: phone.phoneName) { _, _ in refreshDeviceTargets() }
    }

    /// The iPhone entry carries the phone's real name; everything else is
    /// its fixed label.
    private func label(for target: HapticDeviceTarget) -> String {
        if target == .iphone, let name = phone.phoneName {
            return localization.localizer.format(
                "format.settings.general.device.coast",
                arguments: [name]
            )
        }
        return target.localizedName(using: localization.localizer)
    }

    /// Re-scans the connected devices; the picker exists only while there
    /// is a real choice: several trackpads, or a Coast iPhone next to them.
    private func refreshDeviceTargets() {
        var targets: [HapticDeviceTarget] = []
        if let engine = ActuatorHapticEngine.shared {
            engine.refreshDevices()
            if engine.hasMultipleDevices {
                targets = [.all]
                if engine.hasBuiltInDevice { targets.append(.builtIn) }
                if engine.hasExternalDevice { targets.append(.external) }
            }
        }
        if phone.isAvailable {
            // The phone stands beside the trackpads: "All trackpads" keeps
            // meaning exactly that, the phone is an explicit pick.
            if targets.isEmpty { targets = [.all] }
            targets.append(.iphone)
        }
        deviceTargets = targets
        if !targets.isEmpty, !targets.contains(settings.hapticDevice) {
            settings.hapticDevice = .all
        }
    }
}

// MARK: - Haptics

struct HapticsSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController

    var body: some View {
        Form {
            Section {
                Toggle(localization.localizer.string("settings.haptics.enhanced"), isOn: $settings.useEnhancedHaptics)
                if ActuatorHapticEngine.shared == nil {
                    Label(localization.localizer.string("settings.haptics.enhanced.unavailable"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text(verbatim: localization.localizer.string("settings.haptics.enhanced.explanation"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(FeedbackCategory.allCases) { category in
                    CategoryRow(category: category)
                }
            } header: {
                Text(verbatim: localization.localizer.string("settings.haptics.elements.section"))
            } footer: {
                Text(verbatim: localization.localizer.string("settings.haptics.elements.explanation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(localization.localizer.string("settings.haptics.quiet-modes.section")) {
                Toggle(localization.localizer.string("settings.haptics.simple-mode"), isOn: $settings.simpleMode)
                Text(verbatim: localization.localizer.string("settings.haptics.simple-mode.explanation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(localization.localizer.string("settings.haptics.focused-window-only"), isOn: $settings.focusedWindowButtonsOnly)
                Text(verbatim: localization.localizer.string("settings.haptics.focused-window-only.explanation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CategoryRow: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController
    let category: FeedbackCategory

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { settings.categoryEnabled[category] ?? category.defaultEnabled },
            set: { settings.categoryEnabled[category] = $0 }
        )
    }

    private var waveform: Binding<HapticWaveform> {
        Binding(
            get: { settings.categoryWaveforms[category] ?? .single(category.defaultPattern) },
            set: { settings.categoryWaveforms[category] = $0 }
        )
    }

    private var sound: Binding<String> {
        Binding(
            get: { settings.categorySounds[category] ?? "default" },
            set: { settings.categorySounds[category] = $0 }
        )
    }

    var body: some View {
        let displayName = category.localizedName(using: localization.localizer)
        HStack(spacing: 10) {
            Image(systemName: category.symbol)
                .foregroundStyle(isEnabled.wrappedValue ? Color.accentColor : Color.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            Text(verbatim: displayName)
                .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)

            Toggle("", isOn: isEnabled)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(Text(verbatim: displayName))
                .help(category.localizedExplanation(using: localization.localizer))

            WaveformControl(waveform: waveform, accessibilityName: displayName)
                .disabled(!isEnabled.wrappedValue)

            SoundPicker(selection: sound, accessibilityName: displayName)
                .disabled(!isEnabled.wrappedValue)
        }
        .padding(.vertical, 1)
    }
}

/// Sound assignment menu used beside every waveform picker. "Default"
/// follows the Sound pane; "None" is silent; a specific sound always plays.
struct SoundPicker: View {
    @EnvironmentObject private var localization: LocalizationController
    @Binding var selection: String
    var accessibilityName: String

    var body: some View {
        Picker(selection: $selection) {
            Text(verbatim: localization.localizer.string("settings.sound.assignment.default")).tag("default")
            Text(verbatim: localization.localizer.string("settings.sound.assignment.none")).tag("none")
            Divider()
            ForEach(AudioFeedbackEngine.synthSounds, id: \.self) { identifier in
                Text(verbatim: localizedSoundName(identifier)).tag(identifier)
            }
            Divider()
            ForEach(AudioFeedbackEngine.availableSounds, id: \.self) { name in
                Text(verbatim: name).tag(name)
            }
            let custom = AudioFeedbackEngine.customSounds()
            if !custom.isEmpty {
                Divider()
                ForEach(custom, id: \.self) { identifier in
                    Text(verbatim: AudioFeedbackEngine.displayName(for: identifier)).tag(identifier)
                }
            }
        } label: {
            Text(verbatim: localization.localizer.format(
                "format.settings.sound.for-element",
                arguments: [accessibilityName]
            ))
        }
        .labelsHidden()
        .fixedSize()
    }

    private func localizedSoundName(_ identifier: String) -> String {
        AudioFeedbackEngine.localizedDisplayName(for: identifier, using: localization.localizer)
    }
}

private extension FeedbackCategory {
    var symbol: String {
        switch self {
        case .button: return "button.horizontal"
        case .link: return "link"
        case .toggle: return "switch.2"
        case .menuItem: return "filemenu.and.selection"
        case .menuBarItem: return "menubar.rectangle"
        case .dockItem: return "dock.rectangle"
        case .tab: return "rectangle.topthird.inset.filled"
        case .slider: return "slider.horizontal.3"
        case .textField: return "character.cursor.ibeam"
        case .genericPressable: return "cursorarrow.square"
        }
    }
}

// MARK: - Vibration

struct VibrationSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController

    var body: some View {
        Form {
            Section {
                Toggle(localization.localizer.string("settings.vibration.enable"), isOn: $settings.vibrateOnHover)
                Text(verbatim: localization.localizer.string("settings.vibration.explanation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(localization.localizer.string("settings.vibration.rhythm"), selection: $settings.vibrationMode) {
                    ForEach(VibrationMode.allCases) { mode in
                        Text(verbatim: mode.localizedName(using: localization.localizer)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker(localization.localizer.string("settings.vibration.strength"), selection: $settings.vibratePattern) {
                    ForEach(FeedbackPattern.allCases) { pattern in
                        Text(verbatim: pattern.localizedName(using: localization.localizer)).tag(pattern)
                    }
                }

                if settings.useEnhancedHaptics {
                    LabeledSlider(
                        title: localization.localizer.string("settings.vibration.pitch"),
                        value: $settings.vibrateHz,
                        range: 90...500,
                        step: 5,
                        format: {
                            localization.localizer.format(
                                "format.settings.vibration.hz",
                                arguments: [Int($0.rounded())]
                            )
                        },
                        caption: localization.localizer.string("settings.vibration.pitch.help")
                    )
                } else {
                    LabeledSlider(
                        title: localization.localizer.string("settings.vibration.speed"),
                        value: $settings.vibrateRateMs,
                        range: 30...150,
                        step: 2,
                        format: {
                            localization.localizer.format(
                                "format.settings.vibration.pulses-per-second",
                                arguments: [Int((1000 / $0).rounded())]
                            )
                        },
                        caption: localization.localizer.string("settings.vibration.speed.standard-help")
                    )
                }
            }
            .disabled(!settings.vibrateOnHover)

            Section {
                HoldToFeelButton()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

/// Press and hold to run the actual vibration with the current settings -
/// the preview IS the real thing.
private struct HoldToFeelButton: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController
    @State private var buzzing = false
    @State private var timer: Timer?
    @State private var step = 0

    var body: some View {
        Text(verbatim: localization.localizer.string(
            buzzing ? "settings.vibration.preview.active" : "settings.vibration.preview.hold"
        ))
            .font(.body.weight(.medium))
            .padding(.horizontal, 28)
            .padding(.vertical, 9)
            .background(buzzing ? Color.accentColor.opacity(0.85) : Color.accentColor, in: Capsule())
            .foregroundStyle(.white)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !buzzing { start() } }
                    .onEnded { _ in stop() }
            )
            .accessibilityLabel(Text(verbatim: localization.localizer.string("a11y.settings.vibration.hold-to-feel")))
            .onDisappear { stop() }
    }

    private func start() {
        buzzing = true
        // The phone target buzzes over the timer path, like the pipeline:
        // the actuator's dedicated thread only reaches trackpads.
        if settings.hapticDevice == .iphone, PhoneHapticEngine.shared.isAvailable {
            scheduleTick()
            return
        }
        if settings.useEnhancedHaptics, let actuator = ActuatorHapticEngine.shared {
            let base = max(settings.vibrateRateMs / 1000, 0.004)
            let mode = settings.vibrationMode
            let loudness = settings.vibratePattern.toneLevel
            actuator.startTone(
                hz: settings.vibrateHz,
                level: { elapsed in mode.level(at: elapsed, base: base) * loudness },
                fallback: settings.vibratePattern,
                fallbackGaps: mode.gaps(base: base)
            )
            return
        }
        scheduleTick()
    }

    private func scheduleTick() {
        let gaps = settings.vibrationMode.gaps(base: max(settings.vibrateRateMs / 1000, 0.03))
        let gap = gaps[step % gaps.count]
        step += 1
        let next = Timer(timeInterval: gap, repeats: false) { _ in
            Task { @MainActor in
                guard buzzing else { return }
                // Route each pulse where the live pipeline would: the Coast
                // phone when targeted and reachable, a specific trackpad
                // through the actuator, else the system engine.
                if settings.hapticDevice == .iphone, PhoneHapticEngine.shared.isAvailable {
                    PhoneHapticEngine.shared.tick(settings.vibratePattern)
                } else if settings.hapticDevice.isTrackpadSpecific,
                          let actuator = ActuatorHapticEngine.shared {
                    actuator.tick(settings.vibratePattern)
                } else {
                    SystemHapticEngine().tick(settings.vibratePattern)
                }
                scheduleTick()
            }
        }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func stop() {
        buzzing = false
        timer?.invalidate()
        timer = nil
        step = 0
        ActuatorHapticEngine.shared?.stopTone()
    }
}

// MARK: - Keyboard

struct KeyboardSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController

    var body: some View {
        Form {
            Section {
                Toggle(localization.localizer.string("settings.keyboard.enable"), isOn: $settings.keyboardHapticsEnabled)
                Text(verbatim: localization.localizer.string("settings.keyboard.explanation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(localization.localizer.string("settings.keyboard.fire-on.section")) {
                Toggle(localization.localizer.string("settings.keyboard.shortcuts"), isOn: $settings.keyboardShortcuts)
                Toggle(localization.localizer.string("settings.keyboard.every-key"), isOn: $settings.keyboardAllKeys)
                Toggle(localization.localizer.string("settings.keyboard.modifier-keys"), isOn: $settings.keyboardModifierKeys)
                HStack {
                    Text(verbatim: localization.localizer.string("settings.keyboard.waveform"))
                    Spacer()
                    WaveformControl(
                        waveform: $settings.keyboardWaveform,
                        accessibilityName: localization.localizer.string("settings.keyboard.accessibility-name")
                    )
                }
                HStack {
                    Text(verbatim: localization.localizer.string("settings.keyboard.sound"))
                    Spacer()
                    SoundPicker(
                        selection: $settings.keyboardSound,
                        accessibilityName: localization.localizer.string("settings.keyboard.accessibility-name")
                    )
                }
            }
            .disabled(!settings.keyboardHapticsEnabled)
            .opacity(settings.keyboardHapticsEnabled ? 1 : 0.45)

            Section {
                ForEach(settings.keyCombos) { combo in
                    let display = combo.localizedDisplay(using: localization.localizer)
                    HStack {
                        Text(verbatim: display)
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                        Spacer()
                        WaveformControl(
                            waveform: waveformBinding(combo),
                            accessibilityName: localization.localizer.format(
                                "format.settings.keyboard.shortcut",
                                arguments: [display]
                            )
                        )
                        Button {
                            settings.keyCombos.removeAll { $0.id == combo.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text(verbatim: localization.localizer.format(
                            "format.settings.keyboard.remove-shortcut",
                            arguments: [display]
                        )))
                    }
                }
                ShortcutRecorder()
            } header: {
                Text(verbatim: localization.localizer.string("settings.keyboard.custom-shortcuts.section"))
            } footer: {
                Text(verbatim: localization.localizer.string("settings.keyboard.custom-shortcuts.explanation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.keyboardHapticsEnabled)
            .opacity(settings.keyboardHapticsEnabled ? 1 : 0.45)

            Section {
                Label(localization.localizer.string("settings.keyboard.privacy"), systemImage: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func waveformBinding(_ combo: KeyCombo) -> Binding<HapticWaveform> {
        Binding(
            get: {
                settings.keyCombos.first(where: { $0.id == combo.id })?.waveform ?? combo.waveform
            },
            set: { newValue in
                if let index = settings.keyCombos.firstIndex(where: { $0.id == combo.id }) {
                    settings.keyCombos[index].waveform = newValue
                }
            }
        )
    }
}

/// Records one key combination: press Record, hold any modifiers, press a
/// key, and the combo is set the moment you release it. Esc cancels.
private struct ShortcutRecorder: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var localization: LocalizationController

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var pendingKeyCode: UInt16?
    @State private var pendingModifiers: NSEvent.ModifierFlags = []

    var body: some View {
        HStack {
            Button {
                isRecording ? stop() : begin()
            } label: {
                Label(
                    localization.localizer.string(
                        isRecording ? "settings.keyboard.recording" : "settings.keyboard.record"
                    ),
                    systemImage: isRecording ? "record.circle.fill" : "plus"
                )
            }
            if isRecording {
                Text(verbatim: localization.localizer.string("settings.keyboard.escape-cancels"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { stop() }
    }

    private func begin() {
        isRecording = true
        controller.setKeyboardCaptureSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            let modifiers = event.modifierFlags.intersection(KeyboardMonitor.significantModifiers)
            if event.type == .keyDown {
                if event.keyCode == 53, modifiers.isEmpty {
                    stop()
                    return nil
                }
                pendingKeyCode = event.keyCode
                pendingModifiers = modifiers
                return nil
            }
            // Released the recorded key: the combo is set.
            if let keyCode = pendingKeyCode, event.keyCode == keyCode {
                commit(keyCode: keyCode, modifiers: pendingModifiers)
                stop()
            }
            return nil
        }
    }

    private func commit(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        settings.keyCombos.removeAll { $0.keyCode == keyCode && $0.modifiers == modifiers.rawValue }
        settings.keyCombos.append(KeyCombo(
            keyCode: keyCode,
            modifiers: modifiers.rawValue,
            display: KeyCombo.displayString(keyCode: keyCode, modifiers: modifiers),
            waveform: settings.keyboardWaveform
        ))
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pendingKeyCode = nil
        pendingModifiers = []
        isRecording = false
        controller.setKeyboardCaptureSuspended(false)
    }
}

// MARK: - Visual Aids

struct VisualAidsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController

    var body: some View {
        Form {
            Section {
                VisualAidPreview()
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
            }

            Section(localization.localizer.string("settings.visual.cursor-ring.section")) {
                Toggle(localization.localizer.string("settings.visual.cursor-ring.enable"), isOn: $settings.hoverCircleEnabled)
                LabeledSlider(
                    title: localization.localizer.string("settings.visual.cursor-ring.size"),
                    value: $settings.hoverCircleDiameter,
                    range: 12...44,
                    step: 2,
                    format: {
                        localization.localizer.format(
                            "format.unit.points.integer",
                            arguments: [Int($0)]
                        )
                    },
                    caption: nil
                )
                .disabled(!settings.hoverCircleEnabled)
                LabeledSlider(
                    title: localization.localizer.string("settings.visual.cursor-ring.outline-thickness"),
                    value: $settings.hoverCircleStrokeWidth,
                    range: 1...8,
                    step: 0.5,
                    format: {
                        localization.localizer.format(
                            "format.unit.points.decimal",
                            arguments: [$0]
                        )
                    },
                    caption: nil
                )
                .disabled(!settings.hoverCircleEnabled || settings.hoverCircleFilled)
                Toggle(localization.localizer.string("settings.visual.cursor-ring.fill"), isOn: $settings.hoverCircleFilled)
                    .disabled(!settings.hoverCircleEnabled)
            }

            Section(localization.localizer.string("settings.visual.element-highlight.section")) {
                Toggle(localization.localizer.string("settings.visual.element-highlight.enable"), isOn: $settings.elementHighlightEnabled)
                LabeledSlider(
                    title: localization.localizer.string("settings.visual.element-highlight.thickness"),
                    value: $settings.elementHighlightWidth,
                    range: 1...8,
                    step: 0.5,
                    format: {
                        localization.localizer.format(
                            "format.unit.points.decimal",
                            arguments: [$0]
                        )
                    },
                    caption: nil
                )
                .disabled(!settings.elementHighlightEnabled)
            }

            Section {
                Toggle(localization.localizer.string("settings.visual.crosshair.enable"), isOn: $settings.crosshairEnabled)
                LabeledSlider(
                    title: localization.localizer.string("settings.visual.crosshair.thickness"),
                    value: $settings.crosshairWidth,
                    range: 1...6,
                    step: 0.5,
                    format: {
                        localization.localizer.format(
                            "format.unit.points.decimal",
                            arguments: [$0]
                        )
                    },
                    caption: nil
                )
                .disabled(!settings.crosshairEnabled)
                Toggle(localization.localizer.string("settings.visual.hover-caption.enable"), isOn: $settings.hoverCaptionEnabled)
                Toggle(localization.localizer.string("settings.visual.fire-flash.enable"), isOn: $settings.fireFlashEnabled)
            } header: {
                Text(verbatim: localization.localizer.string("settings.visual.more-aids.section"))
            } footer: {
                Text(verbatim: localization.localizer.string("settings.visual.more-aids.explanation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(localization.localizer.string("settings.visual.colors.section")) {
                ColorPicker(localization.localizer.string("settings.visual.colors.clickable"), selection: colorBinding(\.clickableColorHex, fallback: .systemGreen))
                ColorPicker(localization.localizer.string("settings.visual.colors.dangerous"), selection: colorBinding(\.dangerColorHex, fallback: .systemRed))
            }
        }
        .formStyle(.grouped)
    }

    private func colorBinding(_ keyPath: ReferenceWritableKeyPath<SettingsStore, String>, fallback: NSColor) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hexString: settings[keyPath: keyPath]) ?? fallback) },
            set: { settings[keyPath: keyPath] = NSColor($0).hexString }
        )
    }
}

/// A live miniature of the visual aids: a cursor drifts between a normal
/// button and a destructive one, drawing the circle and highlight exactly as
/// configured. Changing any control updates it instantly.
private struct VisualAidPreview: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let w = geo.size.width
                let midY = geo.size.height / 2
                // The cursor path: an easy sweep between the two buttons.
                let x = w * (0.5 + 0.34 * sin(t * 0.7))
                let y = midY + 10 * sin(t * 1.9)
                let safeFrame = CGRect(x: w * 0.5 - 170, y: midY - 16, width: 110, height: 32)
                let dangerFrame = CGRect(x: w * 0.5 + 60, y: midY - 16, width: 110, height: 32)
                let overSafe = safeFrame.insetBy(dx: -6, dy: -10).contains(CGPoint(x: x, y: y))
                let overDanger = dangerFrame.insetBy(dx: -6, dy: -10).contains(CGPoint(x: x, y: y))
                let color: Color = overDanger ? dangerColor : (overSafe ? clickableColor : .gray.opacity(0.6))

                ZStack {
                    if settings.crosshairEnabled {
                        Rectangle().fill(color.opacity(0.5))
                            .frame(width: w, height: settings.crosshairWidth)
                            .position(x: w / 2, y: y)
                        Rectangle().fill(color.opacity(0.5))
                            .frame(width: settings.crosshairWidth, height: geo.size.height)
                            .position(x: x, y: geo.size.height / 2)
                    }

                    sample(
                        localization.localizer.string("settings.visual.preview.button"),
                        frame: safeFrame,
                        highlighted: overSafe,
                        color: clickableColor
                    )
                    sample(
                        localization.localizer.string("settings.visual.preview.delete"),
                        frame: dangerFrame,
                        highlighted: overDanger,
                        color: dangerColor
                    )

                    if settings.fireFlashEnabled, overSafe || overDanger {
                        // Ripple keyed to entering a control, like the real echo.
                        let phase = (t * 0.7).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(color, lineWidth: 2.5)
                            .frame(width: settings.hoverCircleDiameter * (1 + phase),
                                   height: settings.hoverCircleDiameter * (1 + phase))
                            .opacity(0.8 * (1 - phase))
                            .position(x: x, y: y)
                    }

                    if settings.hoverCircleEnabled {
                        Circle()
                            .fill(settings.hoverCircleFilled ? color.opacity(0.55) : .clear)
                            .overlay(Circle().stroke(color, lineWidth: settings.hoverCircleFilled ? 1.5 : settings.hoverCircleStrokeWidth))
                            .frame(width: settings.hoverCircleDiameter, height: settings.hoverCircleDiameter)
                            .position(x: x, y: y)
                    }
                    // The arrow rides just ahead of the circle, like the real cursor.
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 13))
                        .position(x: x + 1, y: y - 1)

                    if settings.hoverCaptionEnabled, overSafe || overDanger {
                        Text(verbatim: localization.localizer.string(
                            overDanger
                                ? "settings.visual.preview.delete-caption"
                                : "settings.visual.preview.button-caption"
                        ))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.78)))
                            .position(x: x + 14, y: y + 24)
                    }

                    if !settings.hoverCircleEnabled && !settings.elementHighlightEnabled
                        && !settings.crosshairEnabled && !settings.hoverCaptionEnabled && !settings.fireFlashEnabled {
                        Text(verbatim: localization.localizer.string("settings.visual.preview.empty"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .position(x: w / 2, y: geo.size.height - 12)
                    }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(Text(verbatim: localization.localizer.string("a11y.settings.visual.preview")))
    }

    private func sample(_ title: String, frame: CGRect, highlighted: Bool, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color(nsColor: .controlColor))
            .overlay(Text(verbatim: title).font(.callout))
            .overlay {
                if settings.elementHighlightEnabled && highlighted {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(color.opacity(0.28), lineWidth: settings.elementHighlightWidth + 5)
                        .padding(-CGFloat(settings.elementHighlightWidth))
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(color, lineWidth: settings.elementHighlightWidth)
                        .padding(-CGFloat(settings.elementHighlightWidth))
                }
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }

    private var clickableColor: Color {
        Color(nsColor: NSColor(hexString: settings.clickableColorHex) ?? .systemGreen)
    }

    private var dangerColor: Color {
        Color(nsColor: NSColor(hexString: settings.dangerColorHex) ?? .systemRed)
    }
}

// MARK: - Sound

struct SoundSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController
    @State private var customSounds = AudioFeedbackEngine.customSounds()
    @State private var importError: String?
    @State private var previewEngine = AudioFeedbackEngine()
    @State private var importCandidate: ImportCandidate?

    private struct ImportCandidate: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        Form {
            Section {
                Toggle(localization.localizer.string("settings.sound.enable"), isOn: $settings.audioEnabled)
                Text(verbatim: localization.localizer.string("settings.sound.explanation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(localization.localizer.string("settings.sound.picker"), selection: $settings.audioSoundName) {
                    Section(localization.localizer.string("settings.sound.synthesized.section")) {
                        ForEach(AudioFeedbackEngine.synthSounds, id: \.self) { identifier in
                            if let style = SynthClickEngine.Style(identifier: identifier) {
                                Text(verbatim: style.localizedName(using: localization.localizer)).tag(identifier)
                            }
                        }
                    }
                    Section(localization.localizer.string("settings.sound.system.section")) {
                        ForEach(AudioFeedbackEngine.availableSounds, id: \.self) { name in
                            Text(verbatim: name).tag(name)
                        }
                    }
                    if !customSounds.isEmpty {
                        Section(localization.localizer.string("settings.sound.imported.section")) {
                            ForEach(customSounds, id: \.self) { identifier in
                                Text(verbatim: AudioFeedbackEngine.displayName(for: identifier)).tag(identifier)
                            }
                        }
                    }
                }
                .onChange(of: settings.audioSoundName) { _, _ in
                    playPreview()
                }

                if SynthClickEngine.Style(identifier: settings.audioSoundName) != nil {
                    LabeledSlider(
                        title: localization.localizer.string("settings.sound.pitch"),
                        value: $settings.audioPitch,
                        range: 0.5...2.0,
                        step: 0.05,
                        format: {
                            localization.localizer.format(
                                "format.settings.sound.pitch-multiplier",
                                arguments: [$0]
                            )
                        },
                        caption: nil
                    )
                    .onChange(of: settings.audioPitch) { _, _ in
                        playPreview()
                    }
                    Toggle(localization.localizer.string("settings.sound.vary-tone"), isOn: $settings.audioToneVariation)
                        .onChange(of: settings.audioToneVariation) { _, _ in
                            playPreview()
                        }
                }

                LabeledSlider(
                    title: localization.localizer.string("settings.sound.volume"),
                    value: $settings.audioVolume,
                    range: 0.1...1.0,
                    step: 0.1,
                    format: {
                        localization.localizer.format(
                            "format.percent.integer",
                            arguments: [Int($0 * 100)]
                        )
                    },
                    caption: nil
                )
                .onChange(of: settings.audioVolume) { _, _ in
                    playPreview()
                }

                HStack {
                    Button(localization.localizer.string("settings.sound.import")) { importSound() }
                    if AudioFeedbackEngine.customFilename(from: settings.audioSoundName) != nil {
                        Button(localization.localizer.string("settings.sound.remove")) {
                            AudioFeedbackEngine.removeSound(settings.audioSoundName)
                            settings.audioSoundName = AudioFeedbackEngine.availableSounds[0]
                            customSounds = AudioFeedbackEngine.customSounds()
                        }
                    }
                    Spacer()
                    Button(localization.localizer.string("settings.sound.test")) { playPreview() }
                }
            } footer: {
                if let importError {
                    Text(verbatim: importError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text(verbatim: localization.localizer.string("settings.sound.picker.explanation"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!settings.audioEnabled)
            .opacity(settings.audioEnabled ? 1 : 0.45)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .sheet(item: $importCandidate) { candidate in
            SoundImportView(url: candidate.url) { identifier in
                customSounds = AudioFeedbackEngine.customSounds()
                settings.audioSoundName = identifier
                importError = nil
            }
            .environmentObject(settings)
        }
    }

    private func playPreview() {
        previewEngine.volume = settings.audioVolume
        previewEngine.soundName = settings.audioSoundName
        previewEngine.pitch = settings.audioPitch
        previewEngine.varyTone = settings.audioToneVariation
        previewEngine.tick(.generic)
    }

    private func importSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.title = localization.localizer.string("dialog.sound.choose.title")
        panel.message = localization.localizer.string("dialog.sound.choose.message")
        panel.prompt = localization.localizer.string("dialog.sound.choose.prompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importCandidate = ImportCandidate(url: url)
    }
}

// MARK: - Performance

struct PerformanceSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController

    var body: some View {
        Form {
            Section {
                LabeledSlider(
                    title: localization.localizer.string("settings.performance.polling-rate"),
                    value: $settings.pollingHz,
                    range: 30...120,
                    step: 10,
                    format: {
                        localization.localizer.format(
                            "format.unit.hertz",
                            arguments: [Int($0)]
                        )
                    },
                    caption: localization.localizer.string("settings.performance.polling-rate.explanation")
                )
                .disabled(settings.noLagMode)

                Toggle(localization.localizer.string("settings.performance.no-lag"), isOn: $settings.noLagMode)
                Text(verbatim: localization.localizer.string("settings.performance.no-lag.explanation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledSlider(
                    title: localization.localizer.string("settings.performance.rate-limit"),
                    value: $settings.rateLimitMs,
                    range: 0...500,
                    step: 25,
                    format: { value in
                        value == 0
                            ? localization.localizer.string("settings.common.off")
                            : localization.localizer.format(
                                "format.unit.milliseconds",
                                arguments: [Int(value)]
                            )
                    },
                    caption: localization.localizer.string("settings.performance.rate-limit.explanation")
                )

                LabeledSlider(
                    title: localization.localizer.string("settings.performance.dwell-delay"),
                    value: $settings.dwellMs,
                    range: 0...1000,
                    step: 50,
                    format: { value in
                        value == 0
                            ? localization.localizer.string("settings.common.off")
                            : localization.localizer.format(
                                "format.unit.milliseconds",
                                arguments: [Int(value)]
                            )
                    },
                    caption: localization.localizer.string("settings.performance.dwell-delay.explanation")
                )
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - About

struct AboutView: View {
    @ObservedObject private var updater = Updater.shared
    @EnvironmentObject private var localization: LocalizationController

    private static let feedbackURL = "https://github.com/Mason363/Tactile/issues/new/choose"
    private static let repoURL = "https://github.com/Mason363/Tactile"
    private static let coffeeURL = "https://buymeacoffee.com/masonchen"
    private static let siteURL = "https://www.masn.studio"

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return localization.localizer.format(
            "format.settings.about.version",
            arguments: [short, build]
        )
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                    Text(verbatim: "Tactile")
                        .font(.system(size: 22, weight: .semibold))
                    Text(verbatim: versionText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button(localization.localizer.string("settings.about.check-for-updates")) { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .listRowInsets(EdgeInsets())
            }

            Section {
                aboutLink("settings.about.feedback", systemImage: "exclamationmark.bubble.fill", url: Self.feedbackURL)
                aboutLink("settings.about.source", systemImage: "chevron.left.forwardslash.chevron.right", url: Self.repoURL)
                aboutLink("settings.about.coffee", systemImage: "cup.and.saucer.fill", url: Self.coffeeURL)
            }

            Section {
                Link(destination: URL(string: Self.siteURL)!) {
                    Text(verbatim: "www.masn.studio")
                }
                Text(verbatim: localization.localizer.format(
                    "format.settings.about.made-by",
                    arguments: ["❤️", "Mason Chen"]
                ))
                    .accessibilityLabel(Text(verbatim: localization.localizer.string("a11y.settings.about.made-by")))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
    }

    private func aboutLink(_ titleKey: String, systemImage: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            Label(localization.localizer.string(titleKey), systemImage: systemImage)
        }
    }
}

// MARK: - Shared controls

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: title)
                Spacer()
                Text(verbatim: format(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step) {
                Text(verbatim: title)
            }
            .labelsHidden()
            .accessibilityValue(format(value))
            if let caption {
                Text(verbatim: caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
