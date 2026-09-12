import AppKit
import Combine
import Foundation
@testable import Tactile

// Link against an unsigned Debug app's testable module. This test never
// bootstraps AppController or touches the user's standard preferences.
@main
struct LocalizationStateTests {
    @MainActor
    static func main() async throws {
        let appPath = CommandLine.arguments[1]
        let registry = LanguagePackRegistry(bundle: Bundle(path: appPath)!)
        let suite = "test.tactile.localization.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let controller = LocalizationController(settings: settings, registry: registry)
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
            checks += 1
            guard condition() else { fatalError("FAIL: \(description)") }
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(40)) }
        expect(controller.selection == .system, "Initial selection follows system")
        controller.setSelection(.pack(identifier: "en"))
        try await settle()
        expect(controller.resolvedPack.identifier == "en", "English selection publishes")
        expect(defaults.string(forKey: "languageSelection") == "pack:en", "Stable persisted selection")
        NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        try await settle()
        expect(controller.resolvedPack.identifier == "en", "System locale cannot override explicit selection")
        controller.setSelection(.pack(identifier: "zh-Hans"))
        try await settle()
        expect(controller.localizer.string("window.settings.title") == "Tactile 设置", "Live Chinese localizer")
        controller.setSelection(.pack(identifier: "fr"))
        try await settle()
        expect(settings.languageSelection == .pack(identifier: "en"), "Missing explicit package normalizes")
        expect(defaults.string(forKey: "languageSelection") == "pack:en", "Missing package normalization persists")
        let snapshot = settings.makeSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        expect(json["languageSelection"] == nil && json["languageIdentifier"] == nil, "Profile JSON excludes language")
        controller.setSelection(.pack(identifier: "zh-Hans"))
        try await settle()
        settings.apply(try JSONDecoder().decode(SettingsSnapshot.self, from: data))
        try await settle()
        expect(settings.languageSelection == .pack(identifier: "zh-Hans"), "Profile apply preserves UI language")
        expect(settings.makeConfig(languageIdentifier: "en").languageIdentifier == "en", "Feedback config carries resolved identifier")

        let legacy = KeyCombo(keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue,
                              display: "⌘Space", waveform: WaveformPreset.tap.waveform)
        let combo = try JSONDecoder().decode(KeyCombo.self, from: JSONEncoder().encode(legacy))
        expect(combo.display == "⌘Space", "Legacy shortcut display round-trips unchanged")
        expect(combo.matches(keyCode: 49, modifiers: .command), "Shortcut matching unchanged")
        expect(!combo.matches(keyCode: 49, modifiers: [.command, .shift]), "Shortcut modifiers remain exact")
        expect(combo.localizedDisplay(using: controller.localizer) == "⌘空格", "Shortcut display uses current language")
        expect(KeyCombo.displayString(keyCode: 49, modifiers: .command) == "⌘Space",
               "Stored shortcut text stays readable by earlier versions")

        controller.setSelection(.system)
        try await settle()
        expect(settings.languageSelection == .system, "System choice remains system")
        expect(controller.resolvedPack.identifier == registry.resolve(selection: .system,
                preferredLanguages: Locale.preferredLanguages).identifier, "System follows the whole preference list")
        // The answer AppKit gives the app bundle, so Tactile's own strings
        // never disagree with system panels, menus, or Sparkle.
        let systemCases: [([String], String)] = [
            (["fr-FR", "zh-Hans-CN", "en-US"], "zh-Hans"),
            (["zh-Hant-TW", "zh-Hans-CN"], "zh-Hans"),
            (["zh-Hant-TW", "en-US"], "en"),
            (["ja-JP"], "en"),
            (["en-GB", "zh-Hans-CN"], "en"),
            (["zh-Hans-SG"], "zh-Hans"),
        ]
        for (preferences, expected) in systemCases {
            expect(registry.resolve(selection: .system, preferredLanguages: preferences).identifier == expected,
                   "System choice for \(preferences) is \(expected)")
        }

        // Every key an enum builds must exist in every pack, or the UI shows
        // the raw key. The validator cannot see interpolated keys.
        var derivedKeys: [String] = []
        for category in FeedbackCategory.allCases {
            derivedKeys += [category.nameLocalizationKey, category.captionLocalizationKey,
                            category.explanationLocalizationKey]
        }
        derivedKeys += FeedbackPattern.allCases.map(\.nameLocalizationKey)
        derivedKeys += VibrationMode.allCases.map(\.nameLocalizationKey)
        derivedKeys += HapticDeviceTarget.allCases.map(\.nameLocalizationKey)
        derivedKeys += WaveformPreset.allCases.map(\.nameLocalizationKey)
        derivedKeys += SynthClickEngine.Style.allCases.map(\.nameLocalizationKey)
        for pane in SettingsPane.allCases { derivedKeys += [pane.titleKey, pane.subtitleKey] }
        expect(Set(registry.packs.map(\.identifier)) == ["en", "zh-Hans"], "Both bundled packs discovered")
        for pack in registry.packs {
            for key in derivedKeys {
                let missing = "\u{FFFF}missing"
                expect(pack.bundle.localizedString(forKey: key, value: missing, table: nil) != missing,
                       "\(pack.identifier) has enum-derived key \(key)")
            }
        }

        let chinese = Localizer(pack: registry.pack(identifier: "zh-Hans")!, fallback: registry.englishPack)
        expect(ContextDetector.isDanger(title: chinese.string("settings.playground.buttons.delete"),
                                        subrole: nil, category: .button),
               "Chinese Playground Delete still plays the danger waveform")

        // A disabled control publishes a caption but cannot play feedback.
        // Refreshing that retained context must not fire a waveform either.
        var config = settings.makeConfig(languageIdentifier: "en")
        config.feelDisabled = false
        config.hoverCaptionEnabled = true
        let feedback = FeedbackController(config: config, languagePacks: registry)
        var caption: String?
        var lastKind: HoverKind?
        var hoverEvents = 0
        var fireCount = 0
        feedback.onHoverState = { kind, _, value in
            lastKind = kind
            caption = value
            hoverEvents += 1
        }
        feedback.onFire = { fireCount += 1 }
        let hover = try JSONDecoder().decode(BridgeMessage.self, from:
            Data(#"{"type":"hover","el":"button","enabled":false,"label":"Save"}"#.utf8))
        feedback.handleBridge(hover)
        expect(caption == "Save · Button", "English hover caption")
        config.languageIdentifier = "zh-Hans"
        feedback.config = config
        feedback.refreshLocalizedPresentation()
        expect(caption == "Save · 按钮", "Stationary hover caption immediately translates")
        expect(fireCount == 0, "Language change does not trigger haptics")
        var unlabeledHover = hover
        unlabeledHover.label = nil
        feedback.handleBridge(unlabeledHover)
        expect(caption == "按钮", "Unlabeled hover uses category alone")

        // reset() also runs while the pipeline is stopped (app switches, a
        // dropped bridge). It must leave the indicator alone, and a later
        // language change must have nothing to redraw.
        let eventsBeforeReset = hoverEvents
        feedback.reset()
        feedback.refreshLocalizedPresentation()
        expect(hoverEvents == eventsBeforeReset, "reset() leaves the hover indicator alone")

        // With the caption aid off, the hover state still flows but no
        // caption is built.
        config.hoverCaptionEnabled = false
        feedback.config = config
        feedback.handleBridge(hover)
        expect(hoverEvents > eventsBeforeReset && lastKind == .disabled && caption == nil,
               "No caption is built while the caption aid is off")
        let eventsWithoutCaptions = hoverEvents
        feedback.refreshLocalizedPresentation()
        expect(hoverEvents == eventsWithoutCaptions, "Nothing to refresh while the caption aid is off")
        feedback.reset()
        print("PASS: \(checks) production state/profile/shortcut/hover checks")
    }
}
