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
        let englishSignature = placeholderSignature(in: english)
        let format = englishSignature != nil
            && placeholderSignature(in: localized) == englishSignature ? localized : english
        // Never pass a malformed fallback format to Foundation's varargs API.
        guard englishSignature != nil else { return emergency }
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

    private func placeholderSignature(in format: String) -> [String]? {
        let pattern = #"%(?:([1-9][0-9]*)\$)?[-+#0 ']*(\*(?:[1-9][0-9]*\$)?|[0-9]+)?(?:\.(\*(?:[1-9][0-9]*\$)?|[0-9]+))?(hh|h|ll|l|q|z|t|j|L)?([@diuoxXfFeEgGaAcCsSp])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let source = format as NSString
        var cursor = 0
        var nextArgument = 1
        var usedPositional = false
        var usedSequential = false
        var signature: [String] = []

        func record(_ position: Int?, type: String) {
            let index: Int
            if let position {
                index = position
                usedPositional = true
            } else {
                index = nextArgument
                nextArgument += 1
                usedSequential = true
            }
            signature.append("\(index):\(type)")
        }

        while cursor < source.length {
            guard source.character(at: cursor) == 37 else { cursor += 1; continue }
            if cursor + 1 < source.length, source.character(at: cursor + 1) == 37 {
                cursor += 2
                continue
            }
            guard let match = expression.firstMatch(
                in: format, options: .anchored,
                range: NSRange(location: cursor, length: source.length - cursor)
            ) else { return nil }
            func group(_ index: Int) -> String {
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            // Star width and precision consume their own integer arguments.
            for field in [group(2), group(3)] where field.hasPrefix("*") {
                let explicit = field.dropFirst().dropLast()
                record(Int(explicit), type: "d")
            }
            let conversion = group(5)
            let type: String
            switch conversion {
            case "i", "d": type = group(4) + "d"
            case "u", "o", "x", "X": type = group(4) + "u"
            case "f", "F", "e", "E", "g", "G", "a", "A": type = group(4) + "f"
            default: type = group(4) + conversion
            }
            record(Int(group(1)), type: type)
            cursor = NSMaxRange(match.range)
        }
        guard !(usedPositional && usedSequential) else { return nil }
        return signature.sorted()
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
            let branches = variable
                .filter { !metadataKeys.contains($0.key) }
                .compactMap { $0.value as? String }
            let signatures = branches.compactMap(placeholderSignature)
            guard signatures.count == branches.count,
                  branches.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { return nil }
            let branchSignatures = Array(Set(signatures))
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
