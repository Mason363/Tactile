import Foundation

// Compile this harness with the production LanguagePack.swift and
// LanguageIdentifierMatcher.swift; see docs/localization.md.
@main
struct LocalizationRuntimeTests {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resourceRoot = CommandLine.arguments.dropFirst().first.map {
            URL(fileURLWithPath: $0)
        } ?? root.appendingPathComponent("Tactile/Localization")
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
            checks += 1
            guard condition() else { fatalError("FAIL: \(description)") }
        }
        func pack(_ identifier: String, at directory: URL) -> LanguagePack {
            let bundle = Bundle(url: directory.appendingPathComponent("\(identifier).lproj"))!
            return LanguagePack(identifier: identifier, locale: Locale(identifier: identifier),
                                nativeDisplayName: identifier, bundle: bundle)
        }
        let english = pack("en", at: resourceRoot)
        let chinese = pack("zh-Hans", at: resourceRoot)
        let en = Localizer(pack: english, fallback: english)
        let zh = Localizer(pack: chinese, fallback: english)
        expect(en.plural("waveform.pulse-count", count: 1) == "1 pulse", "English singular")
        expect(en.plural("waveform.pulse-count", count: 2) == "2 pulses", "English plural")
        expect(en.plural("waveform.pulse-count", count: 10) == "10 pulses", "English many")
        expect(zh.plural("waveform.pulse-count", count: 1) == "1 个脉冲", "Chinese singular")
        expect(zh.plural("waveform.pulse-count", count: 2) == "2 个脉冲", "Chinese plural")
        expect(zh.format("feedback.hover-caption.with-label", "Save", zh.string("feedback.category.button.caption"))
               == "Save · 按钮", "External label remains verbatim")

        // Fixtures are independent of the user's preferences and app bundle.
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("tactile-runtime-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        func writePlist(_ value: Any, to url: URL) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            try data.write(to: url)
        }
        try writePlist(["CFBundleIdentifier": "test.tactile.\(UUID().uuidString)",
                        "CFBundleDevelopmentRegion": "en"], to: fixture.appendingPathComponent("Info.plist"))
        func addPack(_ identifier: String, _ strings: [String: String]?) throws {
            let directory = fixture.appendingPathComponent("\(identifier).lproj")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let strings { try writePlist(strings, to: directory.appendingPathComponent("Localizable.strings")) }
        }
        try addPack("en", ["language.pack.display-name": "English", "missing": "Fallback",
                           "blank": "Not blank", "spacing": " English ", "format": "%d %@",
                           "reorder": "%d %@", "escaped": "%d%% %@", "star": "%*.*f",
                           "malformed": "%d %@"])
        try addPack("fr", ["language.pack.display-name": "Français", "blank": "  ",
                           "spacing": " Français ", "format": "%1$@ %2$d",
                           "reorder": "%2$@ %1$d", "escaped": "%1$d%% %2$@",
                           "star": "%3$*1$.*2$f", "malformed": "%Q"])
        try addPack("de", ["unrelated": "Missing display name"])
        try addPack("it", nil)
        try addPack("bad--tag", ["language.pack.display-name": "Invalid"])
        try addPack("Base", ["language.pack.display-name": "Base"])
        let registry = LanguagePackRegistry(bundle: Bundle(url: fixture)!)
        expect(Set(registry.packs.map(\.identifier)) == ["en", "fr"], "Automatic discovery and invalid-pack exclusion")
        let french = Localizer(pack: registry.pack(identifier: "fr")!, fallback: registry.englishPack)
        expect(french.string("missing") == "Fallback", "Missing translation falls back to English")
        expect(french.string("blank") == "Not blank", "Empty translation falls back to English")
        expect(french.string("spacing") == " Français ", "Intentional whitespace preserved")
        expect(french.string("absent", defaultValue: "Default") == "Default", "Caller fallback")
        expect(french.string("absent") == "absent", "Last-resort key fallback")
        expect(french.format("format", 7, "items") == "7 items", "Wrong positional types fall back safely")
        expect(french.format("reorder", 7, "items") == "items 7", "Safe argument reordering")
        expect(french.format("escaped", 7, "items") == "7% items", "Escaped percent")
        expect(french.format("malformed", 7, "items") == "7 items", "Malformed translation falls back safely")
        expect(french.format("star", 5, 2, 1.5).contains("1,50"), "Width/precision and explicit locale")
        expect(registry.resolve(selection: .system, systemIdentifier: "fr-FR").identifier == "fr", "Future generic French pack")
        expect(registry.resolve(selection: .system, systemIdentifier: "ja-JP").identifier == "en", "Unsupported system language")
        expect(registry.resolve(selection: .pack(identifier: "removed"), systemIdentifier: "fr-FR").identifier == "en", "Removed pack fallback")
        expect(LanguageSelection(storageValue: "system") == .system, "System preference decoding")
        expect(LanguageSelection(storageValue: "pack:EN_us").storageValue == "pack:en-US", "Preference normalization")
        expect(LanguageIdentifierMatcher.normalize("de-1901-1901") == nil, "Duplicate variants rejected")
        expect(LanguageIdentifierMatcher.match(preferredIdentifier: "en-US", availableIdentifiers: ["en-oxendict", "fr"], fallbackIdentifier: "en") == "en", "Variant is not a generic language pack")
        print("PASS: \(checks) production localization runtime checks; process locale: \(Locale.current.identifier)")
    }
}
