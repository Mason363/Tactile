import Foundation

struct LanguagePack: Identifiable, Equatable {
    let identifier: String
    let locale: Locale
    let nativeDisplayName: String
    let bundle: Bundle
    fileprivate let isSyntheticFallback: Bool

    init(
        identifier: String,
        locale: Locale,
        nativeDisplayName: String,
        bundle: Bundle,
        isSyntheticFallback: Bool = false
    ) {
        self.identifier = identifier
        self.locale = locale
        self.nativeDisplayName = nativeDisplayName
        self.bundle = bundle
        self.isSyntheticFallback = isSyntheticFallback
    }

    var id: String { identifier }

    static func == (lhs: LanguagePack, rhs: LanguagePack) -> Bool {
        lhs.identifier == rhs.identifier
    }
}

enum LanguageSelection: Hashable {
    case system
    case pack(identifier: String)

    init(storageValue: String) {
        guard storageValue.hasPrefix("pack:") else {
            self = .system
            return
        }
        let rawIdentifier = String(storageValue.dropFirst("pack:".count))
        guard !rawIdentifier.isEmpty else {
            self = .system
            return
        }
        self = .pack(
            identifier: LanguageIdentifierMatcher.normalize(rawIdentifier)
                ?? LanguagePackRegistry.fallbackIdentifier
        )
    }

    var storageValue: String {
        switch self {
        case .system:
            return "system"
        case .pack(let identifier):
            let normalized = LanguageIdentifierMatcher.normalize(identifier)
                ?? LanguagePackRegistry.fallbackIdentifier
            return "pack:\(normalized)"
        }
    }
}

final class LanguagePackRegistry {
    static let fallbackIdentifier = "en"
    static let displayNameKey = "language.pack.display-name"

    private let appBundle: Bundle
    private(set) var packs: [LanguagePack] = []

    init(bundle: Bundle = .main) {
        appBundle = bundle
        reload()
    }

    var englishPack: LanguagePack {
        if let pack = pack(identifier: Self.fallbackIdentifier) {
            return pack
        }
        let locale = Locale(identifier: Self.fallbackIdentifier)
        let name = locale.localizedString(forIdentifier: Self.fallbackIdentifier)
            ?? Self.fallbackIdentifier
        return LanguagePack(
            identifier: Self.fallbackIdentifier,
            locale: locale,
            nativeDisplayName: name,
            bundle: appBundle,
            isSyntheticFallback: true
        )
    }

    func reload() {
        var discovered: [String: LanguagePack] = [:]
        var duplicateIdentifiers: Set<String> = []
        let identifiers = appBundle.localizations
            .filter { $0.caseInsensitiveCompare("Base") != .orderedSame }
            .sorted()

        for rawIdentifier in identifiers {
            guard let identifier = LanguageIdentifierMatcher.normalize(rawIdentifier),
                  let path = appBundle.path(forResource: rawIdentifier, ofType: "lproj"),
                  FileManager.default.fileExists(
                    atPath: URL(fileURLWithPath: path)
                        .appendingPathComponent("Localizable.strings").path
                  ),
                  let bundle = Bundle(path: path)
            else { continue }

            let displayName = bundle.localizedString(
                forKey: Self.displayNameKey,
                value: Self.displayNameKey,
                table: nil
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty, displayName != Self.displayNameKey else { continue }

            if discovered[identifier] != nil || duplicateIdentifiers.contains(identifier) {
                discovered.removeValue(forKey: identifier)
                duplicateIdentifiers.insert(identifier)
                continue
            }

            discovered[identifier] = LanguagePack(
                identifier: identifier,
                locale: Locale(identifier: identifier),
                nativeDisplayName: displayName,
                bundle: bundle
            )
        }

        packs = discovered.values.sorted {
            let comparison = $0.nativeDisplayName.compare(
                $1.nativeDisplayName,
                options: [.caseInsensitive, .diacriticInsensitive]
            )
            return comparison == .orderedSame
                ? $0.identifier < $1.identifier
                : comparison == .orderedAscending
        }
    }

    func pack(identifier: String) -> LanguagePack? {
        guard let normalized = LanguageIdentifierMatcher.normalize(identifier) else { return nil }
        return packs.first { $0.identifier == normalized }
    }

    func resolve(selection: LanguageSelection, systemIdentifier: String?) -> LanguagePack {
        switch selection {
        case .system:
            let identifier = LanguageIdentifierMatcher.match(
                preferredIdentifier: systemIdentifier,
                availableIdentifiers: packs.map(\.identifier),
                fallbackIdentifier: Self.fallbackIdentifier
            )
            return pack(identifier: identifier) ?? englishPack
        case .pack(let identifier):
            return pack(identifier: identifier) ?? englishPack
        }
    }
}

struct Localizer {
    let pack: LanguagePack
    let fallback: LanguagePack

    func string(_ key: String, defaultValue: String? = nil) -> String {
        let emergency = defaultValue ?? key
        let english = fallback.isSyntheticFallback
            ? emergency
            : lookup(key, in: fallback.bundle, fallback: emergency)
        return pack.isSyntheticFallback ? english : lookup(key, in: pack.bundle, fallback: english)
    }

    func format(_ key: String, defaultValue: String? = nil, arguments: [CVarArg]) -> String {
        let emergency = defaultValue ?? key
        let english = fallback.isSyntheticFallback
            ? emergency
            : lookup(key, in: fallback.bundle, fallback: emergency)
        let localized = pack.isSyntheticFallback ? english : lookup(key, in: pack.bundle, fallback: english)
        let format = placeholderSignature(in: localized) == placeholderSignature(in: english)
            ? localized
            : english
        return String(format: format, locale: pack.locale, arguments: arguments)
    }

    /// Resolves a plural rule with the selected pack's explicit Bundle and
    /// Locale. This is intentionally not `localizedStringWithFormat`, whose
    /// plural choice follows the process locale rather than an in-app choice.
    func plural(_ key: StaticString, count: Int, defaultValue: String? = nil) -> String {
        let keyString = key.description
        let emergency = defaultValue.map {
            String(format: $0, locale: fallback.locale, arguments: [count])
        } ?? keyString

        guard !fallback.isSyntheticFallback,
              let englishSignature = pluralEntrySignature(forKey: keyString, in: fallback.bundle)
        else { return emergency }

        let english = renderPlural(key, count: count, pack: fallback)
        guard pack.identifier != fallback.identifier || pack.bundle.bundlePath != fallback.bundle.bundlePath,
              !pack.isSyntheticFallback,
              pluralEntrySignature(forKey: keyString, in: pack.bundle) == englishSignature
        else { return english }

        return renderPlural(key, count: count, pack: pack)
    }

    func format(_ key: String, defaultValue: String? = nil, _ arguments: CVarArg...) -> String {
        format(key, defaultValue: defaultValue, arguments: arguments)
    }

    private func lookup(_ key: String, in bundle: Bundle, fallback: String) -> String {
        let value = bundle.localizedString(forKey: key, value: fallback, table: nil)
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
    }

    private func placeholderSignature(in format: String) -> [String] {
        let pattern = #"%(?!%)(?:\d+\$)?[-+#0 ']*(?:\d+|\*)?(?:\.\d+|\.\*)?(?:hh|h|ll|l|q|z|t|j|L)?[@diuoxXfFeEgGaAcCsSp]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(format.startIndex..<format.endIndex, in: format)
        return expression.matches(in: format, range: range).compactMap {
            guard let swiftRange = Range($0.range, in: format) else { return nil }
            return String(format[swiftRange])
                .replacingOccurrences(of: #"%\d+\$"#, with: "%", options: .regularExpression)
        }.sorted()
    }

    private func pluralVariableSignature(in format: String) -> [String] {
        let pattern = #"%#@([A-Za-z][A-Za-z0-9_-]*)@"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(format.startIndex..<format.endIndex, in: format)
        return expression.matches(in: format, range: range).compactMap {
            guard $0.numberOfRanges > 1,
                  let swiftRange = Range($0.range(at: 1), in: format)
            else { return nil }
            return String(format[swiftRange])
        }.sorted()
    }

    private struct PluralEntrySignature: Equatable {
        struct Variable: Equatable {
            let name: String
            let specType: String
            let valueType: String
            let branchPlaceholderSignatures: [[String]]
        }

        let variables: [String]
        let specifications: [Variable]
    }

    private func pluralEntrySignature(forKey key: String, in bundle: Bundle) -> PluralEntrySignature? {
        guard let url = bundle.url(forResource: "Localizable", withExtension: "stringsdict"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any],
              let entry = root[key] as? [String: Any],
              let localizedFormat = entry["NSStringLocalizedFormatKey"] as? String
        else { return nil }

        let variableNames = pluralVariableSignature(in: localizedFormat)
        guard !variableNames.isEmpty else { return nil }

        var specifications: [PluralEntrySignature.Variable] = []
        for name in variableNames {
            guard let variable = entry[name] as? [String: Any],
                  let specType = variable["NSStringFormatSpecTypeKey"] as? String,
                  let valueType = variable["NSStringFormatValueTypeKey"] as? String,
                  variable["other"] is String
            else { return nil }

            let metadataKeys: Set<String> = ["NSStringFormatSpecTypeKey", "NSStringFormatValueTypeKey"]
            let branchSignatures = Array(Set(variable
                .filter { !metadataKeys.contains($0.key) }
                .compactMap { $0.value as? String }
                .map(placeholderSignature)))
                .sorted { $0.lexicographicallyPrecedes($1) }
            guard !branchSignatures.isEmpty else { return nil }
            specifications.append(.init(
                name: name,
                specType: specType,
                valueType: valueType,
                branchPlaceholderSignatures: branchSignatures
            ))
        }

        return PluralEntrySignature(
            variables: variableNames,
            specifications: specifications.sorted { $0.name < $1.name }
        )
    }

    private func renderPlural(_ key: StaticString, count: Int, pack: LanguagePack) -> String {
        String(
            localized: key,
            defaultValue: "\(count)",
            table: "Localizable",
            bundle: pack.bundle,
            locale: pack.locale
        )
    }
}
