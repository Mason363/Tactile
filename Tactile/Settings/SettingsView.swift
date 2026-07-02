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

// MARK: - Panes

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case haptics
    case vibration
    case context
    case visual
    case sound
    case performance
    case apps
    case profiles
    case playground

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .haptics: return "Haptics"
        case .vibration: return "Vibration"
        case .context: return "Context"
        case .visual: return "Visual Aids"
        case .sound: return "Sound"
        case .performance: return "Performance"
        case .apps: return "Apps & Browser"
        case .profiles: return "Profiles"
        case .playground: return "Playground"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Power, startup, and permission."
        case .haptics: return "Which elements you feel, and how each one feels."
        case .vibration: return "A continuous buzz while resting on an element."
        case .context: return "Danger, state, hover-out, and spatial feel."
        case .visual: return "See what you feel: a cursor circle and element highlight."
        case .sound: return "An audible click alongside the haptics."
        case .performance: return "Responsiveness and resource trade-offs."
        case .apps: return "Where Tactile stays quiet, and the Chrome integration."
        case .profiles: return "Save, switch, and share complete setups."
        case .playground: return "Real controls to try your setup on."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .haptics: return "cursorarrow.rays"
        case .vibration: return "waveform.path"
        case .context: return "exclamationmark.triangle.fill"
        case .visual: return "eye.fill"
        case .sound: return "speaker.wave.2.fill"
        case .performance: return "gauge.with.needle.fill"
        case .apps: return "macwindow.on.rectangle"
        case .profiles: return "person.crop.rectangle.stack.fill"
        case .playground: return "hand.point.up.left.fill"
        }
    }

    var chipColor: Color {
        switch self {
        case .general: return .gray
        case .haptics: return .blue
        case .vibration: return .purple
        case .context: return .orange
        case .visual: return .green
        case .sound: return .pink
        case .performance: return .teal
        case .apps: return .indigo
        case .profiles: return .brown
        case .playground: return .cyan
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @State private var pane: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section("Feedback") {
                    sidebarRow(.general)
                    sidebarRow(.haptics)
                    sidebarRow(.vibration)
                    sidebarRow(.context)
                    sidebarRow(.visual)
                    sidebarRow(.sound)
                }
                Section("System") {
                    sidebarRow(.performance)
                    sidebarRow(.apps)
                    sidebarRow(.profiles)
                }
                Section("Try It") {
                    sidebarRow(.playground)
                }
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            VStack(spacing: 0) {
                PaneHeader(pane: pane)
                detailView
            }
            .navigationTitle(pane.title)
        }
        .frame(width: 780, height: 560)
    }

    private func sidebarRow(_ pane: SettingsPane) -> some View {
        Label {
            Text(pane.title)
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
        case .context: ContextSettingsView()
        case .visual: VisualAidsView()
        case .sound: SoundSettingsView()
        case .performance: PerformanceSettingsView()
        case .apps: AppExclusionView()
        case .profiles: ProfilesView()
        case .playground: PlaygroundView()
        }
    }
}

/// Title + one-line description at the top of every pane, so each page
/// explains itself once instead of every control carrying a paragraph.
private struct PaneHeader: View {
    let pane: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(pane.title)
                .font(.title2.bold())
            Text(pane.subtitle)
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

    static func show(controller: AppController) {
        if window == nil {
            let view = SettingsView()
                .environmentObject(controller)
                .environmentObject(controller.settings)
                .environmentObject(controller.permission)
            let hosting = NSHostingController(rootView: view)
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "Tactile Settings"
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            newWindow.titlebarAppearsTransparent = true
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
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

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Enable haptic feedback", isOn: $settings.isEnabled)
                Toggle("Launch Tactile at login", isOn: $launchAtLogin)
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
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Permission") {
                if permission.isTrusted {
                    Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Accessibility access is required", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Open Accessibility Settings") {
                        permission.openSystemSettings()
                    }
                }
                Text("Tactile reads the element under your cursor through macOS accessibility. It never sees keystrokes or screen contents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - Haptics

struct HapticsSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Enhanced haptics", isOn: $settings.useEnhancedHaptics)
                if ActuatorHapticEngine.shared == nil {
                    Label("Not available on this Mac — standard haptics are used.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Drives the trackpad directly so Light, Standard, and Firm become physically different strengths — and unlocks true continuous vibration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(FeedbackCategory.allCases) { category in
                    CategoryRow(category: category)
                }
            } header: {
                Text("Elements")
            } footer: {
                Text("Each element type has its own waveform — use Try to feel it, Edit to compose your own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Quiet Mode") {
                Toggle("Only buttons in the focused window", isOn: $settings.focusedWindowButtonsOnly)
                Text("Ignore everything except buttons in the window you're actively using. Overrides the choices above while on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CategoryRow: View {
    @EnvironmentObject private var settings: SettingsStore
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: category.symbol)
                .foregroundStyle(isEnabled.wrappedValue ? Color.accentColor : Color.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            Toggle(isOn: isEnabled) {
                Text(category.displayName)
            }
            .help(category.explanation)

            Spacer()

            WaveformControl(waveform: waveform, accessibilityName: category.displayName)
                .disabled(!isEnabled.wrappedValue)
        }
        .padding(.vertical, 1)
    }
}

private extension FeedbackCategory {
    var symbol: String {
        switch self {
        case .button: return "button.horizontal"
        case .link: return "link"
        case .toggle: return "switch.2"
        case .menuItem: return "filemenu.and.selection"
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

    var body: some View {
        Form {
            Section {
                Toggle("Vibrate while hovering", isOn: $settings.vibrateOnHover)
                Text("Buzzes for as long as the cursor rests on a clickable element. Uses a little CPU and battery while buzzing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Rhythm", selection: $settings.vibrationMode) {
                    ForEach(VibrationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Strength", selection: $settings.vibratePattern) {
                    ForEach(FeedbackPattern.allCases) { pattern in
                        Text(pattern.displayName).tag(pattern)
                    }
                }

                LabeledSlider(
                    title: "Speed",
                    value: $settings.vibrateRateMs,
                    range: settings.useEnhancedHaptics ? 4...150 : 30...150,
                    step: 2,
                    format: { "\(Int((1000 / $0).rounded())) pulses/sec" },
                    caption: settings.useEnhancedHaptics
                        ? "Past roughly 100 pulses per second the taps blur into one continuous vibration."
                        : "Turn on enhanced haptics (Haptics pane) to unlock speeds fast enough to feel like a true vibration."
                )
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

/// Press and hold to run the actual vibration with the current settings —
/// the preview IS the real thing.
private struct HoldToFeelButton: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var buzzing = false
    @State private var timer: Timer?
    @State private var step = 0

    var body: some View {
        Text(buzzing ? "Feeling it…" : "Hold to Feel")
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
            .accessibilityLabel("Hold to feel the vibration")
            .onDisappear { stop() }
    }

    private func start() {
        buzzing = true
        if settings.useEnhancedHaptics, let actuator = ActuatorHapticEngine.shared {
            let base = max(settings.vibrateRateMs / 1000, 0.004)
            let mode = settings.vibrationMode
            actuator.startBuzz(settings.vibratePattern, gaps: mode.gaps(base: base))
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
                SystemHapticEngine().tick(settings.vibratePattern)
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
        ActuatorHapticEngine.shared?.stopBuzz()
    }
}

// MARK: - Visual Aids

struct VisualAidsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                VisualAidPreview()
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                Toggle("Colored circle under the cursor", isOn: $settings.hoverCircleEnabled)
                LabeledSlider(
                    title: "Circle size",
                    value: $settings.hoverCircleDiameter,
                    range: 12...44,
                    step: 2,
                    format: { "\(Int($0)) pt" },
                    caption: nil
                )
                .disabled(!settings.hoverCircleEnabled)

                Toggle("Highlight the hovered element", isOn: $settings.elementHighlightEnabled)
            } footer: {
                Text("The circle follows the cursor and takes the color of what's underneath; the highlight outlines the element's whole clickable area.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Colors") {
                ColorPicker("Clickable", selection: colorBinding(\.clickableColorHex, fallback: .systemGreen))
                ColorPicker("Dangerous", selection: colorBinding(\.dangerColorHex, fallback: .systemRed))
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
                    sample("Button", frame: safeFrame, highlighted: overSafe, color: clickableColor)
                    sample("Delete", frame: dangerFrame, highlighted: overDanger, color: dangerColor)

                    if settings.hoverCircleEnabled {
                        Circle()
                            .fill(color.opacity(0.55))
                            .overlay(Circle().stroke(color, lineWidth: 1.5))
                            .frame(width: settings.hoverCircleDiameter, height: settings.hoverCircleDiameter)
                            .position(x: x, y: y)
                    }
                    // The arrow rides just ahead of the circle, like the real cursor.
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 13))
                        .position(x: x + 1, y: y - 1)

                    if !settings.hoverCircleEnabled && !settings.elementHighlightEnabled {
                        Text("Turn on an aid below to preview it")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .position(x: w / 2, y: geo.size.height - 12)
                    }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Live preview of the cursor circle and element highlight")
    }

    private func sample(_ title: String, frame: CGRect, highlighted: Bool, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color(nsColor: .controlColor))
            .overlay(Text(title).font(.callout))
            .overlay {
                if settings.elementHighlightEnabled && highlighted {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(color, lineWidth: 3)
                        .padding(-3)
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
    @State private var customSounds = AudioFeedbackEngine.customSounds()
    @State private var importError: String?
    @State private var previewEngine = AudioFeedbackEngine()

    var body: some View {
        Form {
            Section {
                Toggle("Play a click sound", isOn: $settings.audioEnabled)
                Text("Useful with an external mouse, where trackpad haptics can't be felt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Sound", selection: $settings.audioSoundName) {
                    ForEach(AudioFeedbackEngine.availableSounds, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    if !customSounds.isEmpty {
                        Divider()
                        ForEach(customSounds, id: \.self) { identifier in
                            Text(AudioFeedbackEngine.displayName(for: identifier)).tag(identifier)
                        }
                    }
                }
                .onChange(of: settings.audioSoundName) { _, _ in
                    playPreview()
                }

                LabeledSlider(
                    title: "Volume",
                    value: $settings.audioVolume,
                    range: 0.1...1.0,
                    step: 0.1,
                    format: { "\(Int($0 * 100))%" },
                    caption: nil
                )
                .onChange(of: settings.audioVolume) { _, _ in
                    playPreview()
                }

                HStack {
                    Button("Import Sound…") { importSound() }
                    if AudioFeedbackEngine.customFilename(from: settings.audioSoundName) != nil {
                        Button("Remove This Sound") {
                            AudioFeedbackEngine.removeSound(settings.audioSoundName)
                            settings.audioSoundName = AudioFeedbackEngine.availableSounds[0]
                            customSounds = AudioFeedbackEngine.customSounds()
                        }
                    }
                    Spacer()
                    Button("Test") { playPreview() }
                }
            } footer: {
                if let importError {
                    Text(importError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Picking a sound plays it. Short sounds work best — any audio format macOS can play.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!settings.audioEnabled)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func playPreview() {
        previewEngine.volume = settings.audioVolume
        previewEngine.soundName = settings.audioSoundName
        previewEngine.tick(.generic)
    }

    private func importSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.message = "Choose short audio files to use as hover clicks"
        guard panel.runModal() == .OK else { return }
        var lastImported: String?
        var failed: [String] = []
        for url in panel.urls {
            if let identifier = AudioFeedbackEngine.importSound(from: url) {
                lastImported = identifier
            } else {
                failed.append(url.lastPathComponent)
            }
        }
        customSounds = AudioFeedbackEngine.customSounds()
        if let lastImported {
            settings.audioSoundName = lastImported
        }
        importError = failed.isEmpty ? nil : "Couldn't play \(failed.joined(separator: ", ")) — not imported."
    }
}

// MARK: - Performance

struct PerformanceSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                LabeledSlider(
                    title: "Polling rate",
                    value: $settings.pollingHz,
                    range: 30...120,
                    step: 10,
                    format: { "\(Int($0)) Hz" },
                    caption: "How often the cursor is checked while moving. Higher feels more immediate; lower uses slightly less CPU. Idle cost is always zero."
                )
                .disabled(settings.noLagMode)

                Toggle("No Lag mode", isOn: $settings.noLagMode)
                Text("Checks on every mouse event for the most instant feel. Uses more CPU while the mouse is moving.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledSlider(
                    title: "Minimum time between taps",
                    value: $settings.rateLimitMs,
                    range: 0...500,
                    step: 25,
                    format: { $0 == 0 ? "Off" : "\(Int($0)) ms" },
                    caption: "Raise this if sweeping across toolbars feels too busy."
                )

                LabeledSlider(
                    title: "Dwell delay",
                    value: $settings.dwellMs,
                    range: 0...1000,
                    step: 50,
                    format: { $0 == 0 ? "Off" : "\(Int($0)) ms" },
                    caption: "The cursor must rest on an element this long before it taps. Reduces noise and helps steady targeting."
                )
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
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
                Text(title)
                Spacer()
                Text(format(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step) {
                Text(title)
            }
            .labelsHidden()
            .accessibilityValue(format(value))
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
