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
    case about

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
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Power, startup, and permission."
        case .haptics: return "Which elements you feel, and how each one feels."
        case .vibration: return "A continuous buzz while resting on an element."
        case .context: return "Danger, state, hover-out, and spatial feel."
        case .visual: return "See what you feel: cursor ring, element highlight, crosshair, name tag, and fire ripple."
        case .sound: return "An audible click alongside the haptics."
        case .performance: return "Responsiveness and resource trade-offs."
        case .apps: return "Where Tactile stays quiet, and the Chrome integration."
        case .profiles: return "Save, switch, and share complete setups."
        case .playground: return "Real controls to try your setup on."
        case .about: return "Version, updates, feedback, and credits."
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
        case .about: return "info.circle.fill"
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
        case .about: return Color(nsColor: .systemGray)
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
        case .about: AboutView()
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

            Section("Quiet Modes") {
                Toggle("Simple mode", isOn: $settings.simpleMode)
                Text("Only the primary targets tick — result links and prominent labeled buttons — while incidental controls (three-dot menus, favicons, “Read more”, icons) stay silent. On web pages the browser extension makes the sharpest call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

            Section("Cursor ring") {
                Toggle("Ring around the cursor", isOn: $settings.hoverCircleEnabled)
                LabeledSlider(
                    title: "Ring size",
                    value: $settings.hoverCircleDiameter,
                    range: 12...44,
                    step: 2,
                    format: { "\(Int($0)) pt" },
                    caption: nil
                )
                .disabled(!settings.hoverCircleEnabled)
                LabeledSlider(
                    title: "Outline thickness",
                    value: $settings.hoverCircleStrokeWidth,
                    range: 1...8,
                    step: 0.5,
                    format: { String(format: "%.1f pt", $0) },
                    caption: nil
                )
                .disabled(!settings.hoverCircleEnabled || settings.hoverCircleFilled)
                Toggle("Fill the ring", isOn: $settings.hoverCircleFilled)
                    .disabled(!settings.hoverCircleEnabled)
            }

            Section("Element highlight") {
                Toggle("Highlight the hovered element", isOn: $settings.elementHighlightEnabled)
                LabeledSlider(
                    title: "Highlight thickness",
                    value: $settings.elementHighlightWidth,
                    range: 1...8,
                    step: 0.5,
                    format: { String(format: "%.1f pt", $0) },
                    caption: nil
                )
                .disabled(!settings.elementHighlightEnabled)
            }

            Section {
                Toggle("Crosshair guides", isOn: $settings.crosshairEnabled)
                LabeledSlider(
                    title: "Guide thickness",
                    value: $settings.crosshairWidth,
                    range: 1...6,
                    step: 0.5,
                    format: { String(format: "%.1f pt", $0) },
                    caption: nil
                )
                .disabled(!settings.crosshairEnabled)
                Toggle("Name the hovered element", isOn: $settings.hoverCaptionEnabled)
                Toggle("Flash a ripple when haptics fire", isOn: $settings.fireFlashEnabled)
            } header: {
                Text("More aids")
            } footer: {
                Text("Crosshair guides run full-screen hairlines through the cursor for locating the pointer at a glance. The name tag shows what's under the cursor (\u{201C}Save — Button\u{201D}). The ripple makes each haptic visible — useful with an external mouse or for anyone who can't feel the trackpad.")
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
                    if settings.crosshairEnabled {
                        Rectangle().fill(color.opacity(0.5))
                            .frame(width: w, height: settings.crosshairWidth)
                            .position(x: w / 2, y: y)
                        Rectangle().fill(color.opacity(0.5))
                            .frame(width: settings.crosshairWidth, height: geo.size.height)
                            .position(x: x, y: geo.size.height / 2)
                    }

                    sample("Button", frame: safeFrame, highlighted: overSafe, color: clickableColor)
                    sample("Delete", frame: dangerFrame, highlighted: overDanger, color: dangerColor)

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
                        Text(overDanger ? "Delete — Button" : "Button — Button")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.78)))
                            .position(x: x + 14, y: y + 24)
                    }

                    if !settings.hoverCircleEnabled && !settings.elementHighlightEnabled
                        && !settings.crosshairEnabled && !settings.hoverCaptionEnabled && !settings.fireFlashEnabled {
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

// MARK: - About

struct AboutView: View {
    @ObservedObject private var updater = Updater.shared

    private static let feedbackURL = "https://github.com/Mason363/Tactile/issues/new/choose"
    private static let repoURL = "https://github.com/Mason363/Tactile"
    private static let coffeeURL = "https://buymeacoffee.com/masonchen"
    private static let siteURL = "https://www.masn.studio"

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                    Text("Tactile")
                        .font(.system(size: 22, weight: .semibold))
                    Text(versionText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .listRowInsets(EdgeInsets())
            }

            Section {
                aboutLink("Send Feedback or Report an Issue", systemImage: "exclamationmark.bubble.fill", url: Self.feedbackURL)
                aboutLink("View Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right", url: Self.repoURL)
                aboutLink("Buy Me a Coffee", systemImage: "cup.and.saucer.fill", url: Self.coffeeURL)
            }

            Section {
                Link(destination: URL(string: Self.siteURL)!) {
                    Text("www.masn.studio")
                }
                Text("Made with \(Text("❤️").accessibilityLabel("love")) by Mason Chen")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
    }

    private func aboutLink(_ title: String, systemImage: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            Label(title, systemImage: systemImage)
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
