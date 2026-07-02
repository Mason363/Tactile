//
//  SettingsStore.swift
//  Tactile
//

import AppKit
import Combine
import Foundation

/// The kinds of UI elements Tactile can respond to. Each is individually
/// toggleable and can be assigned its own haptic pattern.
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

/// Haptic patterns offered by the system Force Touch actuator.
enum FeedbackPattern: String, CaseIterable, Identifiable {
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

/// An immutable snapshot of every setting the feedback pipeline needs.
/// Rebuilt on the main thread whenever settings change and handed to the
/// background pipeline, so the pipeline never touches UserDefaults.
struct FeedbackConfig {
    var enabledCategories: Set<FeedbackCategory>
    var patterns: [FeedbackCategory: FeedbackPattern]
    var excludedBundleIDs: Set<String>
    var rateLimitInterval: TimeInterval
    var dwellDelay: TimeInterval
    var audioEnabled: Bool
    var audioVolume: Double
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

    @Published var categoryPattern: [FeedbackCategory: FeedbackPattern] {
        didSet {
            for (category, pattern) in categoryPattern {
                defaults.set(pattern.rawValue, forKey: "category.\(category.rawValue).pattern")
            }
        }
    }

    @Published var excludedBundleIDs: [String] {
        didSet { defaults.set(excludedBundleIDs, forKey: "excludedBundleIDs") }
    }

    /// Minimum time between haptic ticks, in milliseconds.
    @Published var rateLimitMs: Double {
        didSet { defaults.set(rateLimitMs, forKey: "rateLimitMs") }
    }

    /// How long the cursor must rest on an element before it ticks.
    /// 0 disables dwell and ticks immediately on entering an element.
    @Published var dwellMs: Double {
        didSet { defaults.set(dwellMs, forKey: "dwellMs") }
    }

    @Published var audioEnabled: Bool {
        didSet { defaults.set(audioEnabled, forKey: "audioEnabled") }
    }

    @Published var audioVolume: Double {
        didSet { defaults.set(audioVolume, forKey: "audioVolume") }
    }

    init() {
        isEnabled = defaults.object(forKey: "isEnabled") as? Bool ?? true

        var enabled: [FeedbackCategory: Bool] = [:]
        var patterns: [FeedbackCategory: FeedbackPattern] = [:]
        for category in FeedbackCategory.allCases {
            enabled[category] = defaults.object(forKey: "category.\(category.rawValue).enabled") as? Bool
                ?? category.defaultEnabled
            patterns[category] = (defaults.string(forKey: "category.\(category.rawValue).pattern")
                .flatMap(FeedbackPattern.init(rawValue:)))
                ?? category.defaultPattern
        }
        categoryEnabled = enabled
        categoryPattern = patterns

        excludedBundleIDs = defaults.stringArray(forKey: "excludedBundleIDs") ?? []
        rateLimitMs = defaults.object(forKey: "rateLimitMs") as? Double ?? 100
        dwellMs = defaults.object(forKey: "dwellMs") as? Double ?? 0
        audioEnabled = defaults.object(forKey: "audioEnabled") as? Bool ?? false
        audioVolume = defaults.object(forKey: "audioVolume") as? Double ?? 0.5
    }

    func makeConfig() -> FeedbackConfig {
        FeedbackConfig(
            enabledCategories: Set(categoryEnabled.filter(\.value).keys),
            patterns: categoryPattern,
            excludedBundleIDs: Set(excludedBundleIDs),
            rateLimitInterval: rateLimitMs / 1000,
            dwellDelay: dwellMs / 1000,
            audioEnabled: audioEnabled,
            audioVolume: audioVolume
        )
    }
}
