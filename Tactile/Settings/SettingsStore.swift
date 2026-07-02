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
        case .tab: return "Tabs"
        case .slider: return "Sliders"
        case .textField: return "Text Fields"
        case .genericPressable: return "Other Clickable Elements"
        }
    }

    var explanation: String {
        switch self {
        case .button: return "Push buttons, toolbar buttons, and window controls."
        case .link: return "Hyperlinks in web pages and apps."
        case .toggle: return "Checkboxes, radio buttons, switches, and disclosure triangles."
        case .menuItem: return "Menu items, menu bar items, and pop-up buttons."
        case .tab: return "Tab controls in windows and web pages."
        case .slider: return "Sliders and steppers."
        case .textField: return "Editable text fields and search fields."
        case .genericPressable: return "Custom controls that report themselves as pressable, common in web and Electron apps."
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

/// An immutable snapshot of every setting the feedback pipeline needs.
/// Rebuilt on the main thread whenever settings change and handed to the
/// background pipeline, so the pipeline never touches UserDefaults.
struct FeedbackConfig {
    var enabledCategories: Set<FeedbackCategory>
    var waveforms: [FeedbackCategory: HapticWaveform]
    var excludedBundleIDs: Set<String>
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
    var audioEnabled: Bool
    var audioVolume: Double
    var audioSoundName: String
}

/// Everything user-configurable, as one Codable value — the unit of
/// import/export and of saved profiles.
struct SettingsSnapshot: Codable {
    var version = 1
    var isEnabled = true
    var categoryEnabled: [String: Bool] = [:]
    var categoryWaveforms: [String: HapticWaveform] = [:]
    var excludedBundleIDs: [String] = []
    var rateLimitMs: Double = 50
    var dwellMs: Double = 0
    var pollingHz: Double = 60
    var noLagMode = false
    var hapticOnExit = false
    var exitWaveform = WaveformPreset.lightTap.waveform
    var dangerEnabled = true
    var dangerWaveform = WaveformPreset.shake.waveform
    var stateAware = true
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

    @Published var audioSoundName: String {
        didSet { defaults.set(audioSoundName, forKey: "audioSoundName") }
    }

    @Published var audioEnabled: Bool {
        didSet { defaults.set(audioEnabled, forKey: "audioEnabled") }
    }

    @Published var audioVolume: Double {
        didSet { defaults.set(audioVolume, forKey: "audioVolume") }
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
        rateLimitMs = defaults.object(forKey: "rateLimitMs") as? Double ?? 50
        dwellMs = defaults.object(forKey: "dwellMs") as? Double ?? 0
        hapticOnExit = defaults.object(forKey: "hapticOnExit") as? Bool ?? false
        exitWaveform = Self.codable(defaults, "exitWaveform") ?? WaveformPreset.lightTap.waveform
        dangerEnabled = defaults.object(forKey: "dangerEnabled") as? Bool ?? true
        dangerWaveform = Self.codable(defaults, "dangerWaveform") ?? WaveformPreset.shake.waveform
        stateAware = defaults.object(forKey: "stateAware") as? Bool ?? true
        feelDisabled = defaults.object(forKey: "feelDisabled") as? Bool ?? false
        screenEdgesEnabled = defaults.object(forKey: "screenEdgesEnabled") as? Bool ?? false
        edgeWaveform = Self.codable(defaults, "edgeWaveform") ?? WaveformPreset.firmTap.waveform
        windowBoundsEnabled = defaults.object(forKey: "windowBoundsEnabled") as? Bool ?? false
        boundaryWaveform = Self.codable(defaults, "boundaryWaveform") ?? WaveformPreset.lightTap.waveform
        vibrateOnHover = defaults.object(forKey: "vibrateOnHover") as? Bool ?? false
        vibrateRateMs = defaults.object(forKey: "vibrateRateMs") as? Double ?? 50
        vibrationMode = defaults.string(forKey: "vibrationMode").flatMap(VibrationMode.init(rawValue:)) ?? .steady
        vibratePattern = defaults.string(forKey: "vibratePattern").flatMap(FeedbackPattern.init(rawValue:)) ?? .alignment
        useEnhancedHaptics = defaults.object(forKey: "useEnhancedHaptics") as? Bool ?? false
        audioSoundName = defaults.string(forKey: "audioSoundName") ?? "Pop"
        audioEnabled = defaults.object(forKey: "audioEnabled") as? Bool ?? false
        audioVolume = defaults.object(forKey: "audioVolume") as? Double ?? 0.5
        pollingHz = defaults.object(forKey: "pollingHz") as? Double ?? 60
        noLagMode = defaults.object(forKey: "noLagMode") as? Bool ?? false
        profiles = Self.codable(defaults, "profiles") ?? []
    }

    func makeConfig() -> FeedbackConfig {
        FeedbackConfig(
            enabledCategories: Set(categoryEnabled.filter(\.value).keys),
            waveforms: categoryWaveforms,
            excludedBundleIDs: Set(excludedBundleIDs),
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
            audioEnabled: audioEnabled,
            audioVolume: audioVolume,
            audioSoundName: audioSoundName
        )
    }

    // MARK: - Snapshots (profiles, import/export)

    func makeSnapshot() -> SettingsSnapshot {
        var snapshot = SettingsSnapshot()
        snapshot.isEnabled = isEnabled
        snapshot.categoryEnabled = Dictionary(uniqueKeysWithValues: categoryEnabled.map { ($0.key.rawValue, $0.value) })
        snapshot.categoryWaveforms = Dictionary(uniqueKeysWithValues: categoryWaveforms.map { ($0.key.rawValue, $0.value) })
        snapshot.excludedBundleIDs = excludedBundleIDs
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
