import Foundation

nonisolated enum LanguageIdentifierMatcher {
    private struct Tag {
        let identifier: String
        let language: String
        let likelyScript: String?
        let likelyRegion: String?
        let explicitScript: String?
        let explicitRegion: String?

        init?(_ rawIdentifier: String) {
            guard let identifier = LanguageIdentifierMatcher.normalize(rawIdentifier) else { return nil }
            let tokens = identifier.split(separator: "-").map(String.init)
            guard let first = tokens.first else { return nil }

            self.identifier = identifier
            language = first.lowercased()
            explicitScript = tokens.dropFirst().first(where: {
                $0.count == 4 && $0.unicodeScalars.allSatisfy(CharacterSet.letters.contains)
            })
            explicitRegion = tokens.dropFirst().first(where: {
                ($0.count == 2 && $0.unicodeScalars.allSatisfy(CharacterSet.letters.contains))
                    || ($0.count == 3 && $0.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains))
            })

            let language = Locale.Language(identifier: identifier)
            likelyScript = language.script?.identifier
            likelyRegion = language.region?.identifier
        }
    }

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

    static func match(
        preferredIdentifier: String?,
        availableIdentifiers: [String],
        fallbackIdentifier: String
    ) -> String {
        let fallback = normalize(fallbackIdentifier) ?? fallbackIdentifier
        guard let preferredIdentifier, let preferred = Tag(preferredIdentifier) else { return fallback }
        let candidates = availableIdentifiers.compactMap(Tag.init)

        if let exact = candidates.first(where: { $0.identifier == preferred.identifier }) {
            return exact.identifier
        }

        let ranked = candidates.compactMap { candidate -> (Tag, Int)? in
            guard candidate.language == preferred.language else { return nil }
            // A variant/extlang-specific package is not a generic package.
            // Such packages are selected only by the exact match above.
            let baseCount = 1 + (candidate.explicitScript == nil ? 0 : 1)
                + (candidate.explicitRegion == nil ? 0 : 1)
            guard candidate.identifier.split(separator: "-").count == baseCount else { return nil }
            if let candidateScript = candidate.explicitScript,
               candidateScript.caseInsensitiveCompare(preferred.likelyScript ?? "") != .orderedSame {
                return nil
            }
            if let candidateRegion = candidate.explicitRegion,
               candidateRegion.caseInsensitiveCompare(preferred.likelyRegion ?? "") != .orderedSame {
                return nil
            }

            let score: Int
            switch (candidate.explicitScript, candidate.explicitRegion) {
            case (.some, .some): score = 900
            case (.some, .none): score = 800
            case (.none, .some): score = 700
            case (.none, .none): score = 600
            }
            return (candidate, score)
        }
        .sorted {
            $0.1 == $1.1 ? $0.0.identifier < $1.0.identifier : $0.1 > $1.1
        }

        return ranked.first?.0.identifier ?? fallback
    }
}
