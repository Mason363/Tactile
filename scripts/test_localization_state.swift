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
        controller.setSelection(.system)
        try await settle()
        expect(settings.languageSelection == .system, "System choice remains system")
        expect(controller.resolvedPack.identifier == registry.resolve(selection: .system,
                systemIdentifier: Locale.preferredLanguages.first).identifier, "Only first system preference resolves")

        // A disabled control publishes a caption but cannot play feedback.
        // Refreshing that retained context must not fire a waveform either.
        var config = settings.makeConfig(languageIdentifier: "en")
        config.feelDisabled = false
        let feedback = FeedbackController(config: config, languagePacks: registry)
        var caption: String?
        var fireCount = 0
        feedback.onHoverState = { _, _, value in caption = value }
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
        feedback.reset()
        print("PASS: \(checks) production state/profile/shortcut/hover checks")
    }
}
