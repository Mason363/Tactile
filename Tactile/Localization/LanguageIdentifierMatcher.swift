import Foundation

nonisolated enum LanguageIdentifierMatcher {
    static func normalize(_ rawIdentifier: String) -> String? {
        let replaced = rawIdentifier.replacingOccurrences(of: "_", with: "-")
        guard !replaced.hasPrefix("-"), !replaced.hasSuffix("-"), !replaced.contains("--") else {
            return nil
        }
        let rawTokens = replaced.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let rawLanguage = rawTokens.first,
              (2...8).contains(rawLanguage.count),
              isASCIIAlpha(rawLanguage)
        else { return nil }

        var normalized = [rawLanguage.lowercased()]
        var index = 1

        // Up to three extlang subtags may follow a two- or three-letter
        // primary language (for example zh-cmn-Hans).
        var extlangCount = 0
        while rawLanguage.count <= 3, index < rawTokens.count,
              rawTokens[index].count == 3, isASCIIAlpha(rawTokens[index]), extlangCount < 3 {
            normalized.append(rawTokens[index].lowercased())
            index += 1
            extlangCount += 1
        }

        if index < rawTokens.count, rawTokens[index].count == 4, isASCIIAlpha(rawTokens[index]) {
            let script = rawTokens[index]
            normalized.append(script.prefix(1).uppercased() + script.dropFirst().lowercased())
            index += 1
        }

        if index < rawTokens.count {
            let region = rawTokens[index]
            if region.count == 2, isASCIIAlpha(region) {
                normalized.append(region.uppercased())
                index += 1
            } else if region.count == 3, isASCIIDigit(region) {
                normalized.append(region)
                index += 1
            }
        }

        var variants: Set<String> = []
        while index < rawTokens.count, isVariant(rawTokens[index]) {
            let variant = rawTokens[index].lowercased()
            guard variants.insert(variant).inserted else { return nil }
            normalized.append(variant)
            index += 1
        }

        // Extensions and private-use subtags are valid input but do not
        // participate in language-pack matching. Validate them before
        // returning the normalized base identifier.
        var extensionSingletons: Set<String> = []
        while index < rawTokens.count {
            let singleton = rawTokens[index].lowercased()
            guard singleton.count == 1, isASCIIAlphanumeric(singleton) else { return nil }
            index += 1

            if singleton == "x" {
                guard index < rawTokens.count else { return nil }
                while index < rawTokens.count {
                    let token = rawTokens[index]
                    guard (1...8).contains(token.count), isASCIIAlphanumeric(token) else { return nil }
                    index += 1
                }
                break
            }

            guard extensionSingletons.insert(singleton).inserted else { return nil }

            var extensionSubtagCount = 0
            while index < rawTokens.count, rawTokens[index].count != 1 {
                let token = rawTokens[index]
                guard (2...8).contains(token.count), isASCIIAlphanumeric(token) else { return nil }
                index += 1
                extensionSubtagCount += 1
            }
            guard extensionSubtagCount > 0 else { return nil }
        }
        return normalized.joined(separator: "-")
    }

    private static func isVariant(_ token: String) -> Bool {
        ((5...8).contains(token.count) && isASCIIAlphanumeric(token))
            || (token.count == 4 && token.first?.isNumber == true && isASCIIAlphanumeric(token))
    }

    private static func isASCIIAlpha(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }
    }

    private static func isASCIIDigit(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
    }

    private static func isASCIIAlphanumeric(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value)
                || (65...90).contains($0.value)
                || (97...122).contains($0.value)
        }
    }

    /// Picks the pack macOS itself would choose for these preferences:
    /// Foundation's bundle-localization matching over the whole list, the
    /// rule AppKit, file panels, and Sparkle follow, so Tactile shows the same
    /// language as the system UI around it. Scripts stay apart (zh-Hant never
    /// borrows zh-Hans); an unmatched list gets the fallback.
    static func match(
        preferredIdentifiers: [String],
        availableIdentifiers: [String],
        fallbackIdentifier: String
    ) -> String {
        let fallback = normalize(fallbackIdentifier) ?? fallbackIdentifier
        var available: [String] = []
        for identifier in availableIdentifiers.compactMap(normalize) where !available.contains(identifier) {
            available.append(identifier)
        }
        let preferences = preferredIdentifiers.compactMap(normalize)
        guard !available.isEmpty, !preferences.isEmpty else { return fallback }

        // The fallback is always a candidate, so an unmatched list lands on it.
        let candidates = [fallback] + available.filter { $0 != fallback }
        guard let chosen = Bundle.preferredLocalizations(from: candidates, forPreferences: preferences).first,
              available.contains(chosen)
        else { return fallback }
        return chosen
    }
}
