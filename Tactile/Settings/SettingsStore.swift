//
//  SettingsStore.swift
//  Tactile
//

import AppKit
import Combine
import Foundation

/// The kinds of UI elements Tactile can respond to. Each is individually
/// toggleable and can be assigned its own haptic waveform.
enum FeedbackCategory: String, CaseIterable, Identifiable {
    case button
    case link
    case toggle
    case menuItem
    case menuBarItem
    case dockItem
    case tab
    case slider
    case textField
    case genericPressable

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .button: return "Buttons"
        case .link: return "Links"
        case .toggle: return "Checkboxes & Switches"
        case .menuItem: return "Menus & Pop-ups"
        case .menuBarItem: return "Menu Bar"
        case .dockItem: return "Dock"
        case .tab: return "Tabs"
        case .slider: return "Sliders"
        case .textField: return "Text Fields"
        case .genericPressable: return "Other Clickable Elements"
        }
    }

    /// Singular, for the element caption visual aid ("Save - Button").
    var captionName: String {
        switch self {
        case .button: return "Button"
        case .link: return "Link"
        case .toggle: return "Toggle"
        case .menuItem: return "Menu"
        case .menuBarItem: return "Menu bar"
        case .dockItem: return "Dock"
        case .tab: return "Tab"
        case .slider: return "Slider"
        case .textField: return "Text field"
        case .genericPressable: return "Clickable"
        }
    }

    var explanation: String {
        switch self {
        case .button: return "Push buttons, toolbar buttons, and window controls."
        case .link: return "Hyperlinks in web pages and apps."
        case .toggle: return "Checkboxes, radio buttons, switches, and disclosure triangles."
        case .menuItem: return "Items inside open menus, plus pop-up and combo buttons."
        case .menuBarItem: return "The menu bar: Apple menu, app menus, and status icons."
        case .dockItem: return "Dock icons: apps, minimized windows, folders, and the Trash."
        case .tab: return "Tab controls in windows and web pages."
        case .slider: return "Sliders and steppers."
        case .textField: return "Editable text fields and search fields."
        case .genericPressable: return "Custom pressable controls, common in web and Electron apps."
        }
    }

    var defaultEnabled: Bool {
        switch self {
        case .slider, .textField: return false
        default: return true
        }
    }

    var defaultPattern: FeedbackPattern {
        self == .link ? .alignment : .generic
    }
}

/// Pulse strengths. With enhanced haptics these are physically different
/// actuation intensities; with the public engine they map to the three
/// system feedback patterns.
enum FeedbackPattern: String, CaseIterable, Identifiable, Codable {
    case generic
    case alignment
    case levelChange

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .generic: return "Standard"
        case .alignment: return "Light"
        case .levelChange: return "Firm"
        }
    }
}

/// Temporal shape of the hover vibration.
enum VibrationMode: String, CaseIterable, Identifiable {
    case steady
    case pulses
    case heartbeat

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .steady: return "Steady"
        case .pulses: return "Pulses"
        case .heartbeat: return "Heartbeat"
        }
    }

    /// Gaps between consecutive buzz ticks, cycled in order.
    func gaps(base: TimeInterval) -> [TimeInterval] {
        switch self {
        case .steady: return [base]
        case .pulses: return [base, base, base, base * 4]
        case .heartbeat: return [0.1, max(base * 5, 0.45)]
        }
    }
}

/// Which connected trackpad feels the haptics. Only meaningful when more
/// than one haptic trackpad is present (a MacBook with a Magic Trackpad
/// paired); routing to one device goes through the actuator engine, since
/// the public haptics API reaches every device at once.
enum HapticDeviceTarget: String, CaseIterable, Identifiable {
    case all
    case builtIn
    case external

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All trackpads"
        case .builtIn: return "Built-in trackpad"
        case .external: return "Magic Trackpad"
        }
    }
}

/// An immutable snapshot of every setting the feedback pipeline needs.
/// Rebuilt on the main thread whenever settings change and handed to the
/// background pipeline, so the pipeline never touches UserDefaults.
struct FeedbackConfig {
    var enabledCategories: Set<FeedbackCategory>
    var waveforms: [FeedbackCategory: HapticWaveform]
    var excludedBundleIDs: Set<String>
    var focusedWindowButtonsOnly: Bool
    var simpleMode: Bool
    var rateLimitInterval: TimeInterval
    var dwellDelay: TimeInterval
    var hapticOnExit: Bool
    var exitWaveform: HapticWaveform
    var dangerEnabled: Bool
    var dangerWaveform: HapticWaveform
    var stateAware: Bool
    var feelDisabled: Bool
    var screenEdgesEnabled: Bool
    var edgeWaveform: HapticWaveform
    var windowBoundsEnabled: Bool
    var boundaryWaveform: HapticWaveform
    var vibrateOnHover: Bool
    var vibrateInterval: TimeInterval
    var vibrationMode: VibrationMode
    var vibratePattern: FeedbackPattern
    var useEnhancedHaptics: Bool
    var hapticDevice: HapticDeviceTarget
    var audioEnabled: Bool
    var audioVolume: Double
    var audioSoundName: String
    var audioPitch: Double
    var audioToneVariation: Bool
    /// Per-category sound assignment: "default" follows the Sound pane,
    /// "none" is silent, anything else is a sound identifier.
    var categorySounds: [FeedbackCategory: String]
    var keyboardWaveform: HapticWaveform
    var keyboardSound: String
    var scrollEnabled: Bool
    var scrollLines: Double
    var scrollWaveform: HapticWaveform
}

/// Everything user-configurable, as one Codable value - the unit of
/// import/export and of saved profiles.
struct SettingsSnapshot: Codable {
    var version = 1
    var isEnabled = true
    var categoryEnabled: [String: Bool] = [:]
    var categoryWaveforms: [String: HapticWaveform] = [:]
    var excludedBundleIDs: [String] = []
    var focusedWindowButtonsOnly = false
    // Fields added after profiles first shipped are Optional so snapshots
    // saved by older versions still decode; absent means the default.
    var simpleMode: Bool? = false
    var browserIntegrationEnabled: Bool? = true
    var hoverCircleEnabled: Bool? = false
    var hoverCircleDiameter: Double? = 44
    var hoverCircleFilled: Bool? = false
    var hoverCircleStrokeWidth: Double? = 8
    var elementHighlightEnabled: Bool? = false
    var elementHighlightWidth: Double? = 6.5
    var crosshairEnabled: Bool? = false
    var crosshairWidth: Double? = 2
    var hoverCaptionEnabled: Bool? = false
    var fireFlashEnabled: Bool? = false
    var clickableColorHex: String? = "#34C759"
    var dangerColorHex: String? = "#FF3B30"
    var rateLimitMs: Double = 50
    var dwellMs: Double = 0
    var pollingHz: Double = 60
    var noLagMode = false
    var hapticOnExit = false
    var exitWaveform = WaveformPreset.lightTap.waveform
    var dangerEnabled = true
    var dangerWaveform = WaveformPreset.shake.waveform
    var stateAware = false
    var feelDisabled = false
    var screenEdgesEnabled = false
    var edgeWaveform = WaveformPreset.firmTap.waveform
    var windowBoundsEnabled = false
    var boundaryWaveform = WaveformPreset.lightTap.waveform
    var vibrateOnHover = false
    var vibrateRateMs: Double = 50
    var vibrationMode = VibrationMode.steady.rawValue
    var vibratePattern = FeedbackPattern.alignment.rawValue
    var useEnhancedHaptics = false
    var audioEnabled = false
    var audioVolume = 0.5
    var audioSoundName = "Pop"
    // Keyboard haptics (added post-v1, so Optional to keep old snapshots decodable).
    var keyboardHapticsEnabled: Bool? = false
    var keyboardShortcuts: Bool? = true
    var keyboardAllKeys: Bool? = false
    var keyboardModifierKeys: Bool? = false
    var keyboardWaveform: HapticWaveform? = WaveformPreset.tap.waveform
    var keyCombos: [KeyCombo]? = []
    var keyboardSound: String? = "none"
    // Sound styling and per-category sounds.
    var audioPitch: Double? = 1.0
    var audioToneVariation: Bool? = false
    var categorySounds: [String: String]? = [:]
    // Scroll haptics.
    var scrollHapticsEnabled: Bool? = false
    var scrollLines: Double? = 3
    var scrollWaveform: HapticWaveform? = WaveformPreset.lightTap.waveform
    // Haptic output device.
    var hapticDevice: String? = HapticDeviceTarget.all.rawValue
}

struct SettingsProfile: Codable, Identifiable {
    var id = UUID()
    var name: String
    var snapshot: SettingsSnapshot
}

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: "isEnabled") }
    }

    @Published var categoryEnabled: [FeedbackCategory: Bool] {
        didSet {
            for (category, enabled) in categoryEnabled {
                defaults.set(enabled, forKey: "category.\(category.rawValue).enabled")
            }
        }
    }

    @Published var categoryWaveforms: [FeedbackCategory: HapticWaveform] {
        didSet {
            for (category, waveform) in categoryWaveforms {
                setCodable(waveform, forKey: "category.\(category.rawValue).waveform")
            }
        }
    }

    @Published var excludedBundleIDs: [String] {
        didSet { defaults.set(excludedBundleIDs, forKey: "excludedBundleIDs") }
    }

    /// Quiet mode: only fire for buttons, and only in the focused window.
    @Published var focusedWindowButtonsOnly: Bool {
        didSet { defaults.set(focusedWindowButtonsOnly, forKey: "focusedWindowButtonsOnly") }
    }

    /// Simple mode: fire only on prominent primary targets - links, well-
    /// labeled buttons - and skip incidental controls (three-dot menus,
    /// favicons, "Read more", icons). On the web the extension picks the
    /// primary targets; elsewhere it's a prominence + label heuristic.
    @Published var simpleMode: Bool {
        didSet { defaults.set(simpleMode, forKey: "simpleMode") }
    }

    /// Chrome browser integration: while Chrome is frontmost and the cursor is
    /// over web content, feedback comes from the companion extension's view of
    /// the real DOM instead of the accessibility tree. Off until set up.
    @Published var browserIntegrationEnabled: Bool {
        didSet { defaults.set(browserIntegrationEnabled, forKey: "browserIntegrationEnabled") }
    }

    /// Visual aids: a colored circle riding under the cursor (green over
    /// clickable, red over destructive) and an outline around the hovered
    /// element, for finding both the cursor and its target by sight.
    @Published var hoverCircleEnabled: Bool {
        didSet { defaults.set(hoverCircleEnabled, forKey: "hoverCircleEnabled") }
    }

    @Published var hoverCircleDiameter: Double {
        didSet { defaults.set(hoverCircleDiameter, forKey: "hoverCircleDiameter") }
    }

    @Published var hoverCircleFilled: Bool {
        didSet { defaults.set(hoverCircleFilled, forKey: "hoverCircleFilled") }
    }

    @Published var hoverCircleStrokeWidth: Double {
        didSet { defaults.set(hoverCircleStrokeWidth, forKey: "hoverCircleStrokeWidth") }
    }

    @Published var elementHighlightEnabled: Bool {
        didSet { defaults.set(elementHighlightEnabled, forKey: "elementHighlightEnabled") }
    }

    @Published var elementHighlightWidth: Double {
        didSet { defaults.set(elementHighlightWidth, forKey: "elementHighlightWidth") }
    }

    /// Full-screen hairlines through the cursor, for locating the pointer.
    @Published var crosshairEnabled: Bool {
        didSet { defaults.set(crosshairEnabled, forKey: "crosshairEnabled") }
    }

    @Published var crosshairWidth: Double {
        didSet { defaults.set(crosshairWidth, forKey: "crosshairWidth") }
    }

    /// Floating label naming the hovered element ("Save - Button").
    @Published var hoverCaptionEnabled: Bool {
        didSet { defaults.set(hoverCaptionEnabled, forKey: "hoverCaptionEnabled") }
    }

    /// A brief expanding ripple at the cursor whenever a haptic fires.
    @Published var fireFlashEnabled: Bool {
        didSet { defaults.set(fireFlashEnabled, forKey: "fireFlashEnabled") }
    }

    @Published var clickableColorHex: String {
        didSet { defaults.set(clickableColorHex, forKey: "clickableColorHex") }
    }

    @Published var dangerColorHex: String {
        didSet { defaults.set(dangerColorHex, forKey: "dangerColorHex") }
    }

    /// Minimum time between haptic events, in milliseconds. 0 disables.
    @Published var rateLimitMs: Double {
        didSet { defaults.set(rateLimitMs, forKey: "rateLimitMs") }
    }

    /// How long the cursor must rest on an element before it fires.
    @Published var dwellMs: Double {
        didSet { defaults.set(dwellMs, forKey: "dwellMs") }
    }

    /// Also play a waveform when the cursor leaves an element it fired for.
    @Published var hapticOnExit: Bool {
        didSet { defaults.set(hapticOnExit, forKey: "hapticOnExit") }
    }

    @Published var exitWaveform: HapticWaveform {
        didSet { setCodable(exitWaveform, forKey: "exitWaveform") }
    }

    /// Danger context: close buttons and destructive labels get their own feel.
    @Published var dangerEnabled: Bool {
        didSet { defaults.set(dangerEnabled, forKey: "dangerEnabled") }
    }

    @Published var dangerWaveform: HapticWaveform {
        didSet { setCodable(dangerWaveform, forKey: "dangerWaveform") }
    }

    /// Checked toggles and selected tabs get an extra confirmation pulse.
    @Published var stateAware: Bool {
        didSet { defaults.set(stateAware, forKey: "stateAware") }
    }

    /// Disabled controls give a single light pulse instead of silence.
    @Published var feelDisabled: Bool {
        didSet { defaults.set(feelDisabled, forKey: "feelDisabled") }
    }

    @Published var screenEdgesEnabled: Bool {
        didSet { defaults.set(screenEdgesEnabled, forKey: "screenEdgesEnabled") }
    }

    @Published var edgeWaveform: HapticWaveform {
        didSet { setCodable(edgeWaveform, forKey: "edgeWaveform") }
    }

    @Published var windowBoundsEnabled: Bool {
        didSet { defaults.set(windowBoundsEnabled, forKey: "windowBoundsEnabled") }
    }

    @Published var boundaryWaveform: HapticWaveform {
        didSet { setCodable(boundaryWaveform, forKey: "boundaryWaveform") }
    }

    @Published var vibrateOnHover: Bool {
        didSet { defaults.set(vibrateOnHover, forKey: "vibrateOnHover") }
    }

    @Published var vibrateRateMs: Double {
        didSet { defaults.set(vibrateRateMs, forKey: "vibrateRateMs") }
    }

    @Published var vibrationMode: VibrationMode {
        didSet { defaults.set(vibrationMode.rawValue, forKey: "vibrationMode") }
    }

    @Published var vibratePattern: FeedbackPattern {
        didSet { defaults.set(vibratePattern.rawValue, forKey: "vibratePattern") }
    }

    @Published var useEnhancedHaptics: Bool {
        didSet { defaults.set(useEnhancedHaptics, forKey: "useEnhancedHaptics") }
    }

    /// Which trackpad feels the ticks when more than one is connected.
    @Published var hapticDevice: HapticDeviceTarget {
        didSet { defaults.set(hapticDevice.rawValue, forKey: "hapticDevice") }
    }

    @Published var audioSoundName: String {
        didSet { defaults.set(audioSoundName, forKey: "audioSoundName") }
    }

    @Published var audioEnabled: Bool {
        didSet { defaults.set(audioEnabled, forKey: "audioEnabled") }
    }

    @Published var audioVolume: Double {
        didSet { defaults.set(audioVolume, forKey: "audioVolume") }
    }

    /// Keyboard haptics: tick the trackpad as you type. Off by default.
    @Published var keyboardHapticsEnabled: Bool {
        didSet { defaults.set(keyboardHapticsEnabled, forKey: "keyboardHapticsEnabled") }
    }

    /// Fire on keyboard shortcuts (a key pressed with ⌘, ⌃, or ⌥ held).
    @Published var keyboardShortcuts: Bool {
        didSet { defaults.set(keyboardShortcuts, forKey: "keyboardShortcuts") }
    }

    /// Fire on every keypress.
    @Published var keyboardAllKeys: Bool {
        didSet { defaults.set(keyboardAllKeys, forKey: "keyboardAllKeys") }
    }

    /// Also fire when a modifier key (⌘⇧⌥⌃) is pressed on its own.
    @Published var keyboardModifierKeys: Bool {
        didSet { defaults.set(keyboardModifierKeys, forKey: "keyboardModifierKeys") }
    }

    @Published var keyboardWaveform: HapticWaveform {
        didSet { setCodable(keyboardWaveform, forKey: "keyboardWaveform") }
    }

    /// User-recorded key combinations, each with its own waveform.
    @Published var keyCombos: [KeyCombo] {
        didSet { setCodable(keyCombos, forKey: "keyCombos") }
    }

    /// Sound for keyboard haptics: "none", "default", or an identifier.
    @Published var keyboardSound: String {
        didSet { defaults.set(keyboardSound, forKey: "keyboardSound") }
    }

    /// Pitch multiplier for the synthesized click styles.
    @Published var audioPitch: Double {
        didSet { defaults.set(audioPitch, forKey: "audioPitch") }
    }

    /// Vary the pitch a little on every click, for a natural feel.
    @Published var audioToneVariation: Bool {
        didSet { defaults.set(audioToneVariation, forKey: "audioToneVariation") }
    }

    /// Per-category sound assignment ("default" / "none" / identifier).
    @Published var categorySounds: [FeedbackCategory: String] {
        didSet {
            for (category, sound) in categorySounds {
                defaults.set(sound, forKey: "category.\(category.rawValue).sound")
            }
        }
    }

    /// Scroll haptics: tick every N lines of scrolling.
    @Published var scrollHapticsEnabled: Bool {
        didSet { defaults.set(scrollHapticsEnabled, forKey: "scrollHapticsEnabled") }
    }

    @Published var scrollLines: Double {
        didSet { defaults.set(scrollLines, forKey: "scrollLines") }
    }

    @Published var scrollWaveform: HapticWaveform {
        didSet { setCodable(scrollWaveform, forKey: "scrollWaveform") }
    }

    /// Haptics composed in the Studio pane, offered in every waveform picker.
    @Published var customHaptics: [CustomHaptic] {
        didSet { setCodable(customHaptics, forKey: "customHaptics") }
    }

    /// Per-app profile assignment: bundle ID to profile ID.
    @Published var appProfiles: [String: UUID] {
        didSet { setCodable(appProfiles, forKey: "appProfiles") }
    }

    /// The profile whose snapshot was applied last, for the menu bar checkmark.
    @Published var activeProfileID: UUID? {
        didSet { defaults.set(activeProfileID?.uuidString, forKey: "activeProfileID") }
    }

    @Published var pollingHz: Double {
        didSet { defaults.set(pollingHz, forKey: "pollingHz") }
    }

    @Published var noLagMode: Bool {
        didSet { defaults.set(noLagMode, forKey: "noLagMode") }
    }

    @Published var profiles: [SettingsProfile] {
        didSet { setCodable(profiles, forKey: "profiles") }
    }

    init() {
        isEnabled = defaults.object(forKey: "isEnabled") as? Bool ?? true

        var enabled: [FeedbackCategory: Bool] = [:]
        var waveforms: [FeedbackCategory: HapticWaveform] = [:]
        for category in FeedbackCategory.allCases {
            enabled[category] = defaults.object(forKey: "category.\(category.rawValue).enabled") as? Bool
                ?? category.defaultEnabled
            if let waveform: HapticWaveform = Self.codable(defaults, "category.\(category.rawValue).waveform") {
                waveforms[category] = waveform
            } else if let legacy = defaults.string(forKey: "category.\(category.rawValue).pattern")
                .flatMap(FeedbackPattern.init(rawValue:)) {
                // Migrate the pre-waveform per-category pattern.
                waveforms[category] = .single(legacy)
            } else {
                waveforms[category] = .single(category.defaultPattern)
            }
        }
        categoryEnabled = enabled
        categoryWaveforms = waveforms

        excludedBundleIDs = defaults.stringArray(forKey: "excludedBundleIDs") ?? []
        focusedWindowButtonsOnly = defaults.object(forKey: "focusedWindowButtonsOnly") as? Bool ?? false
        simpleMode = defaults.object(forKey: "simpleMode") as? Bool ?? false
        browserIntegrationEnabled = defaults.object(forKey: "browserIntegrationEnabled") as? Bool ?? true
        hoverCircleEnabled = defaults.object(forKey: "hoverCircleEnabled") as? Bool ?? false
        hoverCircleDiameter = defaults.object(forKey: "hoverCircleDiameter") as? Double ?? 44
        hoverCircleFilled = defaults.object(forKey: "hoverCircleFilled") as? Bool ?? false
        hoverCircleStrokeWidth = defaults.object(forKey: "hoverCircleStrokeWidth") as? Double ?? 8
        elementHighlightEnabled = defaults.object(forKey: "elementHighlightEnabled") as? Bool ?? false
        elementHighlightWidth = defaults.object(forKey: "elementHighlightWidth") as? Double ?? 6.5
        crosshairEnabled = defaults.object(forKey: "crosshairEnabled") as? Bool ?? false
        crosshairWidth = defaults.object(forKey: "crosshairWidth") as? Double ?? 2
        hoverCaptionEnabled = defaults.object(forKey: "hoverCaptionEnabled") as? Bool ?? false
        fireFlashEnabled = defaults.object(forKey: "fireFlashEnabled") as? Bool ?? false
        clickableColorHex = defaults.string(forKey: "clickableColorHex") ?? "#34C759"
        dangerColorHex = defaults.string(forKey: "dangerColorHex") ?? "#FF3B30"
        rateLimitMs = defaults.object(forKey: "rateLimitMs") as? Double ?? 50
        dwellMs = defaults.object(forKey: "dwellMs") as? Double ?? 0
        hapticOnExit = defaults.object(forKey: "hapticOnExit") as? Bool ?? false
        exitWaveform = Self.codable(defaults, "exitWaveform") ?? WaveformPreset.lightTap.waveform
        dangerEnabled = defaults.object(forKey: "dangerEnabled") as? Bool ?? true
        dangerWaveform = Self.codable(defaults, "dangerWaveform") ?? WaveformPreset.shake.waveform
        stateAware = defaults.object(forKey: "stateAware") as? Bool ?? false
        feelDisabled = defaults.object(forKey: "feelDisabled") as? Bool ?? false
        screenEdgesEnabled = defaults.object(forKey: "screenEdgesEnabled") as? Bool ?? false
        edgeWaveform = Self.codable(defaults, "edgeWaveform") ?? WaveformPreset.firmTap.waveform
        windowBoundsEnabled = defaults.object(forKey: "windowBoundsEnabled") as? Bool ?? false
        boundaryWaveform = Self.codable(defaults, "boundaryWaveform") ?? WaveformPreset.lightTap.waveform
        vibrateOnHover = defaults.object(forKey: "vibrateOnHover") as? Bool ?? false
        vibrateRateMs = defaults.object(forKey: "vibrateRateMs") as? Double ?? 50
        vibrationMode = defaults.string(forKey: "vibrationMode").flatMap(VibrationMode.init(rawValue:)) ?? .steady
        vibratePattern = defaults.string(forKey: "vibratePattern").flatMap(FeedbackPattern.init(rawValue:)) ?? .alignment
        // Enhanced haptics defaults ON where the hardware supports it and OFF
        // otherwise, so a fresh install feels the richer intensities on Macs
        // that can and quietly falls back on Macs that cannot.
        useEnhancedHaptics = defaults.object(forKey: "useEnhancedHaptics") as? Bool ?? ActuatorHapticEngine.hasHapticTrackpad
        hapticDevice = defaults.string(forKey: "hapticDevice").flatMap(HapticDeviceTarget.init(rawValue:)) ?? .all
        audioSoundName = defaults.string(forKey: "audioSoundName") ?? "Pop"
        audioEnabled = defaults.object(forKey: "audioEnabled") as? Bool ?? false
        audioVolume = defaults.object(forKey: "audioVolume") as? Double ?? 0.5
        keyboardHapticsEnabled = defaults.object(forKey: "keyboardHapticsEnabled") as? Bool ?? false
        keyboardShortcuts = defaults.object(forKey: "keyboardShortcuts") as? Bool ?? true
        keyboardAllKeys = defaults.object(forKey: "keyboardAllKeys") as? Bool ?? false
        keyboardModifierKeys = defaults.object(forKey: "keyboardModifierKeys") as? Bool ?? false
        keyboardWaveform = Self.codable(defaults, "keyboardWaveform") ?? WaveformPreset.tap.waveform
        keyCombos = Self.codable(defaults, "keyCombos") ?? []
        keyboardSound = defaults.string(forKey: "keyboardSound") ?? "none"
        audioPitch = defaults.object(forKey: "audioPitch") as? Double ?? 1.0
        audioToneVariation = defaults.object(forKey: "audioToneVariation") as? Bool ?? false
        var sounds: [FeedbackCategory: String] = [:]
        for category in FeedbackCategory.allCases {
            sounds[category] = defaults.string(forKey: "category.\(category.rawValue).sound") ?? "default"
        }
        categorySounds = sounds
        scrollHapticsEnabled = defaults.object(forKey: "scrollHapticsEnabled") as? Bool ?? false
        scrollLines = defaults.object(forKey: "scrollLines") as? Double ?? 3
        scrollWaveform = Self.codable(defaults, "scrollWaveform") ?? WaveformPreset.lightTap.waveform
        customHaptics = Self.codable(defaults, "customHaptics") ?? []
        appProfiles = Self.codable(defaults, "appProfiles") ?? [:]
        activeProfileID = defaults.string(forKey: "activeProfileID").flatMap(UUID.init(uuidString:))
        pollingHz = defaults.object(forKey: "pollingHz") as? Double ?? 60
        noLagMode = defaults.object(forKey: "noLagMode") as? Bool ?? false
        profiles = Self.codable(defaults, "profiles") ?? []
    }

    func makeConfig() -> FeedbackConfig {
        FeedbackConfig(
            enabledCategories: Set(categoryEnabled.filter(\.value).keys),
            waveforms: categoryWaveforms,
            excludedBundleIDs: Set(excludedBundleIDs),
            focusedWindowButtonsOnly: focusedWindowButtonsOnly,
            simpleMode: simpleMode,
            rateLimitInterval: rateLimitMs / 1000,
            dwellDelay: dwellMs / 1000,
            hapticOnExit: hapticOnExit,
            exitWaveform: exitWaveform,
            dangerEnabled: dangerEnabled,
            dangerWaveform: dangerWaveform,
            stateAware: stateAware,
            feelDisabled: feelDisabled,
            screenEdgesEnabled: screenEdgesEnabled,
            edgeWaveform: edgeWaveform,
            windowBoundsEnabled: windowBoundsEnabled,
            boundaryWaveform: boundaryWaveform,
            vibrateOnHover: vibrateOnHover,
            vibrateInterval: vibrateRateMs / 1000,
            vibrationMode: vibrationMode,
            vibratePattern: vibratePattern,
            useEnhancedHaptics: useEnhancedHaptics,
            hapticDevice: hapticDevice,
            audioEnabled: audioEnabled,
            audioVolume: audioVolume,
            audioSoundName: audioSoundName,
            audioPitch: audioPitch,
            audioToneVariation: audioToneVariation,
            categorySounds: categorySounds,
            keyboardWaveform: keyboardWaveform,
            keyboardSound: keyboardSound,
            scrollEnabled: scrollHapticsEnabled,
            scrollLines: scrollLines,
            scrollWaveform: scrollWaveform
        )
    }

    // MARK: - Snapshots (profiles, import/export)

    func makeSnapshot() -> SettingsSnapshot {
        var snapshot = SettingsSnapshot()
        snapshot.isEnabled = isEnabled
        snapshot.categoryEnabled = Dictionary(uniqueKeysWithValues: categoryEnabled.map { ($0.key.rawValue, $0.value) })
        snapshot.categoryWaveforms = Dictionary(uniqueKeysWithValues: categoryWaveforms.map { ($0.key.rawValue, $0.value) })
        snapshot.excludedBundleIDs = excludedBundleIDs
        snapshot.focusedWindowButtonsOnly = focusedWindowButtonsOnly
        snapshot.simpleMode = simpleMode
        snapshot.browserIntegrationEnabled = browserIntegrationEnabled
        snapshot.hoverCircleEnabled = hoverCircleEnabled
        snapshot.hoverCircleDiameter = hoverCircleDiameter
        snapshot.hoverCircleFilled = hoverCircleFilled
        snapshot.hoverCircleStrokeWidth = hoverCircleStrokeWidth
        snapshot.elementHighlightEnabled = elementHighlightEnabled
        snapshot.elementHighlightWidth = elementHighlightWidth
        snapshot.crosshairEnabled = crosshairEnabled
        snapshot.crosshairWidth = crosshairWidth
        snapshot.hoverCaptionEnabled = hoverCaptionEnabled
        snapshot.fireFlashEnabled = fireFlashEnabled
        snapshot.clickableColorHex = clickableColorHex
        snapshot.dangerColorHex = dangerColorHex
        snapshot.rateLimitMs = rateLimitMs
        snapshot.dwellMs = dwellMs
        snapshot.pollingHz = pollingHz
        snapshot.noLagMode = noLagMode
        snapshot.hapticOnExit = hapticOnExit
        snapshot.exitWaveform = exitWaveform
        snapshot.dangerEnabled = dangerEnabled
        snapshot.dangerWaveform = dangerWaveform
        snapshot.stateAware = stateAware
        snapshot.feelDisabled = feelDisabled
        snapshot.screenEdgesEnabled = screenEdgesEnabled
        snapshot.edgeWaveform = edgeWaveform
        snapshot.windowBoundsEnabled = windowBoundsEnabled
        snapshot.boundaryWaveform = boundaryWaveform
        snapshot.vibrateOnHover = vibrateOnHover
        snapshot.vibrateRateMs = vibrateRateMs
        snapshot.vibrationMode = vibrationMode.rawValue
        snapshot.vibratePattern = vibratePattern.rawValue
        snapshot.useEnhancedHaptics = useEnhancedHaptics
        snapshot.audioEnabled = audioEnabled
        snapshot.audioVolume = audioVolume
        snapshot.audioSoundName = audioSoundName
        snapshot.keyboardHapticsEnabled = keyboardHapticsEnabled
        snapshot.keyboardShortcuts = keyboardShortcuts
        snapshot.keyboardAllKeys = keyboardAllKeys
        snapshot.keyboardModifierKeys = keyboardModifierKeys
        snapshot.keyboardWaveform = keyboardWaveform
        snapshot.keyCombos = keyCombos
        snapshot.keyboardSound = keyboardSound
        snapshot.audioPitch = audioPitch
        snapshot.audioToneVariation = audioToneVariation
        snapshot.categorySounds = Dictionary(uniqueKeysWithValues: categorySounds.map { ($0.key.rawValue, $0.value) })
        snapshot.scrollHapticsEnabled = scrollHapticsEnabled
        snapshot.scrollLines = scrollLines
        snapshot.scrollWaveform = scrollWaveform
        snapshot.hapticDevice = hapticDevice.rawValue
        return snapshot
    }

    func apply(_ snapshot: SettingsSnapshot) {
        isEnabled = snapshot.isEnabled
        var enabled: [FeedbackCategory: Bool] = [:]
        var waveforms: [FeedbackCategory: HapticWaveform] = [:]
        for category in FeedbackCategory.allCases {
            enabled[category] = snapshot.categoryEnabled[category.rawValue] ?? category.defaultEnabled
            waveforms[category] = snapshot.categoryWaveforms[category.rawValue] ?? .single(category.defaultPattern)
        }
        categoryEnabled = enabled
        categoryWaveforms = waveforms
        excludedBundleIDs = snapshot.excludedBundleIDs
        focusedWindowButtonsOnly = snapshot.focusedWindowButtonsOnly
        simpleMode = snapshot.simpleMode ?? false
        browserIntegrationEnabled = snapshot.browserIntegrationEnabled ?? true
        hoverCircleEnabled = snapshot.hoverCircleEnabled ?? false
        hoverCircleDiameter = snapshot.hoverCircleDiameter ?? 44
        hoverCircleFilled = snapshot.hoverCircleFilled ?? false
        hoverCircleStrokeWidth = snapshot.hoverCircleStrokeWidth ?? 8
        elementHighlightEnabled = snapshot.elementHighlightEnabled ?? false
        elementHighlightWidth = snapshot.elementHighlightWidth ?? 6.5
        crosshairEnabled = snapshot.crosshairEnabled ?? false
        crosshairWidth = snapshot.crosshairWidth ?? 2
        hoverCaptionEnabled = snapshot.hoverCaptionEnabled ?? false
        fireFlashEnabled = snapshot.fireFlashEnabled ?? false
        clickableColorHex = snapshot.clickableColorHex ?? "#34C759"
        dangerColorHex = snapshot.dangerColorHex ?? "#FF3B30"
        rateLimitMs = snapshot.rateLimitMs
        dwellMs = snapshot.dwellMs
        pollingHz = snapshot.pollingHz
        noLagMode = snapshot.noLagMode
        hapticOnExit = snapshot.hapticOnExit
        exitWaveform = snapshot.exitWaveform
        dangerEnabled = snapshot.dangerEnabled
        dangerWaveform = snapshot.dangerWaveform
        stateAware = snapshot.stateAware
        feelDisabled = snapshot.feelDisabled
        screenEdgesEnabled = snapshot.screenEdgesEnabled
        edgeWaveform = snapshot.edgeWaveform
        windowBoundsEnabled = snapshot.windowBoundsEnabled
        boundaryWaveform = snapshot.boundaryWaveform
        vibrateOnHover = snapshot.vibrateOnHover
        vibrateRateMs = snapshot.vibrateRateMs
        vibrationMode = VibrationMode(rawValue: snapshot.vibrationMode) ?? .steady
        vibratePattern = FeedbackPattern(rawValue: snapshot.vibratePattern) ?? .alignment
        useEnhancedHaptics = snapshot.useEnhancedHaptics
        audioEnabled = snapshot.audioEnabled
        audioVolume = snapshot.audioVolume
        audioSoundName = snapshot.audioSoundName
        keyboardHapticsEnabled = snapshot.keyboardHapticsEnabled ?? false
        keyboardShortcuts = snapshot.keyboardShortcuts ?? true
        keyboardAllKeys = snapshot.keyboardAllKeys ?? false
        keyboardModifierKeys = snapshot.keyboardModifierKeys ?? false
        keyboardWaveform = snapshot.keyboardWaveform ?? WaveformPreset.tap.waveform
        keyCombos = snapshot.keyCombos ?? []
        keyboardSound = snapshot.keyboardSound ?? "none"
        audioPitch = snapshot.audioPitch ?? 1.0
        audioToneVariation = snapshot.audioToneVariation ?? false
        var sounds: [FeedbackCategory: String] = [:]
        for category in FeedbackCategory.allCases {
            sounds[category] = snapshot.categorySounds?[category.rawValue] ?? "default"
        }
        categorySounds = sounds
        scrollHapticsEnabled = snapshot.scrollHapticsEnabled ?? false
        scrollLines = snapshot.scrollLines ?? 3
        scrollWaveform = snapshot.scrollWaveform ?? WaveformPreset.lightTap.waveform
        hapticDevice = snapshot.hapticDevice.flatMap(HapticDeviceTarget.init(rawValue:)) ?? .all
    }

    // MARK: - Profiles

    /// A user-chosen profile switch: applies the snapshot, remembers the
    /// choice for the menu bar checkmark, and ends any per-app override
    /// (an explicit pick wins over the automatic switching).
    func applyProfile(_ profile: SettingsProfile) {
        perAppBaselineData = nil
        apply(profile.snapshot)
        activeProfileID = profile.id
    }

    // MARK: - Per-app profile override

    /// The settings as they were before a per-app profile took over,
    /// persisted so a quit or crash mid-override can't strand the override
    /// as the user's real settings.
    private struct PerAppBaseline: Codable {
        var snapshot: SettingsSnapshot
        var activeProfileID: UUID?
    }

    private var perAppBaselineData: Data? {
        get { defaults.data(forKey: "perAppBaseline") }
        set {
            if let newValue { defaults.set(newValue, forKey: "perAppBaseline") }
            else { defaults.removeObject(forKey: "perAppBaseline") }
        }
    }

    /// Called when the frontmost app has an assigned profile. Saves the
    /// current settings once, then applies the app's profile.
    func beginPerAppOverride(applying profile: SettingsProfile) {
        if perAppBaselineData == nil {
            let baseline = PerAppBaseline(snapshot: makeSnapshot(), activeProfileID: activeProfileID)
            perAppBaselineData = try? JSONEncoder().encode(baseline)
        }
        guard activeProfileID != profile.id else { return }
        apply(profile.snapshot)
        activeProfileID = profile.id
    }

    /// Called when the frontmost app has no assigned profile: puts the
    /// pre-override settings back.
    func endPerAppOverride() {
        guard let data = perAppBaselineData,
              let baseline = try? JSONDecoder().decode(PerAppBaseline.self, from: data)
        else { return }
        perAppBaselineData = nil
        apply(baseline.snapshot)
        activeProfileID = baseline.activeProfileID
    }

    /// Restores a stranded override on launch (the app quit while a per-app
    /// profile was active). Call once after init.
    func restoreStrandedOverride() {
        endPerAppOverride()
    }

    // MARK: - Codable persistence helpers

    private func setCodable<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func codable<T: Decodable>(_ defaults: UserDefaults, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
