#!/usr/bin/env swift

import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// This validator intentionally keeps the production language matcher out of
// the script. The matcher test matrix compiles the production source below
// with a small temporary harness, so the two implementations cannot drift.

struct ParseFailure: Error, CustomStringConvertible {
    let line: Int
    let message: String

    var description: String {
        line > 0 ? "line \(line): \(message)" : message
    }
}

struct ParsedStrings {
    let values: [String: String]
    let duplicateKeys: [String]
}

struct StringsParser {
    private let source: String
    private var index: String.Index
    private var line = 1

    init(source: String) {
        self.source = source
        index = source.startIndex
    }

    mutating func parse() throws -> ParsedStrings {
        var values: [String: String] = [:]
        var duplicates: [String] = []

        while true {
            try skipTrivia()
            guard !isAtEnd else { break }

            let key = try parseQuotedString(expected: "a quoted key")
            try skipTrivia()
            try consume("=", expected: "'='")
            try skipTrivia()
            let value = try parseQuotedString(expected: "a quoted value")
            try skipTrivia()
            try consume(";", expected: "';'")

            if values.updateValue(value, forKey: key) != nil {
                duplicates.append(key)
            }
        }

        return ParsedStrings(values: values, duplicateKeys: duplicates)
    }

    private var isAtEnd: Bool { index == source.endIndex }

    private mutating func skipTrivia() throws {
        while !isAtEnd {
            let character = source[index]

            if character == " " || character == "\t" || character == "\r" || character == "\n" {
                if character == "\n" { line += 1 }
                advance()
                continue
            }

            if character == "/" {
                let next = source.index(after: index)
                guard next < source.endIndex else { return }

                if source[next] == "/" {
                    advance()
                    advance()
                    while !isAtEnd && source[index] != "\n" { advance() }
                    continue
                }

                if source[next] == "*" {
                    let commentLine = line
                    advance()
                    advance()
                    var closed = false
                    while !isAtEnd {
                        if source[index] == "\n" { line += 1 }
                        if source[index] == "*" {
                            let afterStar = source.index(after: index)
                            if afterStar < source.endIndex && source[afterStar] == "/" {
                                advance()
                                advance()
                                closed = true
                                break
                            }
                        }
                        advance()
                    }
                    if !closed {
                        throw ParseFailure(line: commentLine, message: "unterminated block comment")
                    }
                    continue
                }
            }

            return
        }
    }

    private mutating func parseQuotedString(expected: String) throws -> String {
        guard !isAtEnd, source[index] == "\"" else {
            throw ParseFailure(line: line, message: "expected \(expected)")
        }
        advance()

        var result = ""
        while !isAtEnd {
            let character = source[index]
            if character == "\"" {
                advance()
                return result
            }
            if character == "\n" || character == "\r" {
                throw ParseFailure(line: line, message: "unterminated quoted string")
            }

            if character == "\\" {
                advance()
                guard !isAtEnd else {
                    throw ParseFailure(line: line, message: "unterminated escape sequence")
                }

                let escaped = source[index]
                switch escaped {
                case "n": result.append("\n"); advance()
                case "r": result.append("\r"); advance()
                case "t": result.append("\t"); advance()
                case "\\", "\"": result.append(escaped); advance()
                case "u":
                    result.append(try parseUnicodeEscape(digits: 4))
                case "U":
                    // OpenStep uses four hexadecimal UTF-16 code units for
                    // both \u and \U escapes. Surrogate pairs are combined
                    // below so escaped supplementary characters survive.
                    result.append(try parseUnicodeEscape(digits: 4))
                default:
                    // OpenStep strings permit escaped punctuation. Preserve
                    // the punctuation while still accepting valid syntax.
                    result.append(escaped)
                    advance()
                }
                continue
            }

            result.append(character)
            advance()
        }

        throw ParseFailure(line: line, message: "unterminated quoted string")
    }

    private mutating func parseUnicodeCodeUnit(digits: Int) throws -> UInt32 {
        guard !isAtEnd, source[index] == "u" || source[index] == "U" else {
            throw ParseFailure(line: line, message: "invalid Unicode escape")
        }
        advance() // 'u' or 'U'
        var hexadecimal = ""
        for _ in 0..<digits {
            guard !isAtEnd else {
                throw ParseFailure(line: line, message: "incomplete Unicode escape")
            }
            hexadecimal.append(source[index])
            advance()
        }

        guard let scalarValue = UInt32(hexadecimal, radix: 16) else {
            throw ParseFailure(line: line, message: "invalid Unicode escape")
        }
        return scalarValue
    }

    private mutating func parseUnicodeEscape(digits: Int) throws -> String {
        let scalarValue = try parseUnicodeCodeUnit(digits: digits)

        if (0xD800...0xDBFF).contains(scalarValue) {
            guard digits == 4, !isAtEnd, source[index] == "\\" else {
                throw ParseFailure(line: line, message: "unpaired high surrogate in Unicode escape")
            }
            let marker = source.index(after: index)
            guard marker < source.endIndex,
                  source[marker] == "u" || source[marker] == "U"
            else {
                throw ParseFailure(line: line, message: "unpaired high surrogate in Unicode escape")
            }
            advance() // the backslash before the low-surrogate escape
            let lowValue = try parseUnicodeCodeUnit(digits: 4)
            guard (0xDC00...0xDFFF).contains(lowValue) else {
                throw ParseFailure(line: line, message: "invalid Unicode surrogate pair")
            }
            let combined = 0x10000
                + ((scalarValue - 0xD800) << 10)
                + (lowValue - 0xDC00)
            guard let scalar = UnicodeScalar(combined) else {
                throw ParseFailure(line: line, message: "invalid Unicode scalar")
            }
            return String(scalar)
        }

        guard let scalar = UnicodeScalar(scalarValue) else {
            throw ParseFailure(line: line, message: "invalid Unicode scalar")
        }
        return String(scalar)
    }

    private mutating func consume(_ expected: Character, expected description: String) throws {
        guard !isAtEnd, source[index] == expected else {
            throw ParseFailure(line: line, message: "expected \(description)")
        }
        advance()
    }

    private mutating func advance() {
        index = source.index(after: index)
    }
}

struct LocalizationPackage {
    let identifier: String
    let directory: URL
    var strings: [String: String] = [:]
    var stringsDict: [String: Any] = [:]
}

/// PropertyListSerialization intentionally keeps the last value when an XML
/// dictionary repeats a key. Keep a second XML pass so duplicate keys inside
/// any plist dictionary are reported instead of silently changing a resource.
final class StringsDictDuplicateKeyDelegate: NSObject, XMLParserDelegate {
    private(set) var duplicateKeys: [String] = []
    private var dictionaryKeys: [[String: Bool]] = []
    private var isReadingKey = false
    private var keyText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "dict":
            dictionaryKeys.append([:])
        case "key":
            isReadingKey = true
            keyText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isReadingKey { keyText.append(string) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "key":
            defer {
                isReadingKey = false
                keyText = ""
            }
            guard !dictionaryKeys.isEmpty else { return }
            if dictionaryKeys[dictionaryKeys.count - 1][keyText] == true {
                duplicateKeys.append(keyText)
            } else {
                dictionaryKeys[dictionaryKeys.count - 1][keyText] = true
            }
        case "dict":
            _ = dictionaryKeys.popLast()
        default:
            break
        }
    }
}

struct ValidationReport {
    private(set) var failures: [String] = []

    var isValid: Bool { failures.isEmpty }

    mutating func fail(_ message: String) {
        failures.append(message)
    }

    func printFailures() {
        for failure in failures {
            print("error: \(failure)")
        }
    }
}

let fileManager = FileManager.default
let repositoryRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
let localizationRoot = repositoryRoot
    .appendingPathComponent("Tactile", isDirectory: true)
    .appendingPathComponent("Localization", isDirectory: true)

func isValidResourceIdentifier(_ identifier: String) -> Bool {
    let tokens = identifier.replacingOccurrences(of: "_", with: "-")
        .split(separator: "-", omittingEmptySubsequences: false)
        .map(String.init)
    guard let language = tokens.first,
          (2...8).contains(language.count),
          language.unicodeScalars.allSatisfy({
              ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
          })
    else { return false }

    // This is deliberately only a resource-name sanity check. Matching is
    // tested by compiling LanguageIdentifierMatcher.swift below.
    guard !tokens.dropFirst().contains(where: { $0.isEmpty }) else { return false }
    for token in tokens.dropFirst() {
        let isAlphanumeric = token.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57)
                || ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122)
        }
        guard isAlphanumeric, (1...8).contains(token.count) else { return false }
    }
    return true
}

func canonicalResourceIdentifier(_ identifier: String) -> String {
    identifier.replacingOccurrences(of: "_", with: "-").lowercased()
}

func decodeStringsSource(_ data: Data) -> String? {
    let hasUTF16ByteOrderMark = data.starts(with: [0xFF, 0xFE])
        || data.starts(with: [0xFE, 0xFF])
    let containsNUL = data.contains(0)
    let encodings: [String.Encoding]
    if hasUTF16ByteOrderMark || containsNUL {
        encodings = [.utf16, .utf16LittleEndian, .utf16BigEndian, .utf8]
    } else {
        encodings = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian]
    }

    for encoding in encodings {
        guard var source = String(data: data, encoding: encoding) else { continue }
        if source.first == "\u{FEFF}" { source.removeFirst() }
        return source
    }
    return nil
}

func loadStrings(at url: URL, report: inout ValidationReport, packageID: String) -> [String: String] {
    guard let data = try? Data(contentsOf: url),
          let source = decodeStringsSource(data)
    else {
        report.fail("\(packageID)/Localizable.strings: unable to read UTF-8 data")
        return [:]
    }

    do {
        var parser = StringsParser(source: source)
        let parsed = try parser.parse()
        for key in parsed.duplicateKeys {
            report.fail("\(packageID)/Localizable.strings: duplicate key '\(key)'")
        }
        for (key, value) in parsed.values where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            report.fail("\(packageID)/Localizable.strings: empty value for key '\(key)'")
        }
        return parsed.values
    } catch let failure as ParseFailure {
        report.fail("\(packageID)/Localizable.strings: \(failure)")
    } catch {
        report.fail("\(packageID)/Localizable.strings: \(error)")
    }
    return [:]
}

func loadStringsDict(at url: URL, report: inout ValidationReport, packageID: String) -> [String: Any] {
    guard let data = try? Data(contentsOf: url) else {
        report.fail("\(packageID)/Localizable.stringsdict: unable to read data")
        return [:]
    }

    // An empty optional stringsdict is equivalent to omitting the file. This
    // keeps the resource layout convenient for languages without plurals.
    let whitespaceBytes: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
    if data.allSatisfy({ whitespaceBytes.contains($0) }) { return [:] }

    // XMLParser gives duplicate-key diagnostics that plist deserialization
    // cannot provide. Binary plists have no XML key stream to inspect; the
    // normal PropertyListSerialization pass below still validates those.
    let xmlData: Data
    if data.starts(with: [0xEF, 0xBB, 0xBF]) {
        xmlData = Data(data.dropFirst(3))
    } else {
        xmlData = data
    }
    if let first = xmlData.first(where: { !whitespaceBytes.contains($0) }), first == 0x3C {
        let delegate = StringsDictDuplicateKeyDelegate()
        let parser = XMLParser(data: xmlData)
        parser.delegate = delegate
        if !parser.parse(), let parserError = parser.parserError {
            report.fail(
                "\(packageID)/Localizable.stringsdict: invalid XML (\(parserError.localizedDescription))"
            )
            return [:]
        }
        for key in delegate.duplicateKeys {
            report.fail("\(packageID)/Localizable.stringsdict: duplicate key '\(key)'")
        }
    }

    do {
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        )
        guard let dictionary = plist as? [String: Any] else {
            report.fail("\(packageID)/Localizable.stringsdict: top level must be a dictionary")
            return [:]
        }
        validateStringsDictValues(dictionary, path: "\(packageID)/Localizable.stringsdict", report: &report)
        return dictionary
    } catch {
        report.fail("\(packageID)/Localizable.stringsdict: invalid property list (\(error))")
        return [:]
    }
}

func validateStringsDictValues(
    _ value: Any,
    path: String,
    report: inout ValidationReport
) {
    if let string = value as? String {
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            report.fail("\(path): empty value")
        }
        return
    }
    if let dictionary = value as? [String: Any] {
        for (key, child) in dictionary {
            validateStringsDictValues(child, path: "\(path).\(key)", report: &report)
        }
        return
    }
    if let array = value as? [Any] {
        for (index, child) in array.enumerated() {
            validateStringsDictValues(child, path: "\(path)[\(index)]", report: &report)
        }
    }
}

func loadPackages(at root: URL, report: inout ValidationReport) -> [LocalizationPackage] {
    guard let entries = try? fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        print("[localization] 未发现包：目录不存在或不可读：\(root.path)")
        return []
    }

    let directories = entries
        .filter { $0.pathExtension == "lproj" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    var packages: [LocalizationPackage] = []
    var seenIdentifiers: [String: String] = [:]
    for directory in directories {
        let identifier = directory.deletingPathExtension().lastPathComponent
        guard isValidResourceIdentifier(identifier) else {
            report.fail("\(directory.lastPathComponent): invalid BCP-47 resource identifier")
            continue
        }

        let canonicalIdentifier = canonicalResourceIdentifier(identifier)
        if let previous = seenIdentifiers[canonicalIdentifier] {
            report.fail(
                "\(identifier): duplicate resource identifier (also provided by \(previous))"
            )
        } else {
            seenIdentifiers[canonicalIdentifier] = identifier
        }

        let stringsURL = directory.appendingPathComponent("Localizable.strings")
        guard fileManager.fileExists(atPath: stringsURL.path) else {
            report.fail("\(identifier): missing Localizable.strings")
            continue
        }

        var package = LocalizationPackage(identifier: identifier, directory: directory)
        package.strings = loadStrings(at: stringsURL, report: &report, packageID: identifier)

        let stringsDictURL = directory.appendingPathComponent("Localizable.stringsdict")
        if fileManager.fileExists(atPath: stringsDictURL.path) {
            package.stringsDict = loadStringsDict(
                at: stringsDictURL,
                report: &report,
                packageID: identifier
            )
        }
        packages.append(package)
    }

    return packages
}

func difference(_ lhs: Set<String>, _ rhs: Set<String>) -> [String] {
    lhs.subtracting(rhs).sorted()
}

func compareKeySets(
    packages: [LocalizationPackage],
    report: inout ValidationReport
) {
    guard let english = packages.first(where: { $0.identifier.lowercased() == "en" }) else {
        report.fail("missing required English baseline package en.lproj")
        return
    }

    let englishStrings = Set(english.strings.keys)
    let englishPlural = Set(english.stringsDict.keys)

    for package in packages {
        let packageStrings = Set(package.strings.keys)
        let packagePlural = Set(package.stringsDict.keys)

        for key in difference(englishStrings, packageStrings) {
            report.fail("\(package.identifier): missing ordinary key '\(key)' from English baseline")
        }
        for key in difference(packageStrings, englishStrings) {
            report.fail("\(package.identifier): ordinary key '\(key)' is not in English baseline")
        }
        for key in difference(englishPlural, packagePlural) {
            report.fail("\(package.identifier): missing plural key '\(key)' from English baseline")
        }
        for key in difference(packagePlural, englishPlural) {
            report.fail("\(package.identifier): plural key '\(key)' is not in English baseline")
        }

        if package.strings["language.pack.display-name"] == nil {
            report.fail("\(package.identifier): missing required key 'language.pack.display-name'")
        }
        if package.strings["language.pack.display-name"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            report.fail("\(package.identifier): empty value for 'language.pack.display-name'")
        }

        for key in packageStrings.intersection(packagePlural).sorted() {
            report.fail("\(package.identifier): key '\(key)' appears in both .strings and .stringsdict")
        }
    }
}

private struct ParsedPrintfFormat {
    let signature: [String]
    let isValid: Bool
}

private let printfConversionCharacters: Set<UInt8> = Set(
    Array("@diuoxXfFeEgGaAcCsSp".utf8)
)
private let printfFlagCharacters: Set<UInt8> = Set(
    Array("-+#0 '".utf8)
)
private let printfLengthCharacters: Set<UInt8> = Set(
    Array("hlqztjL".utf8)
)

private func isASCIIDigit(_ byte: UInt8) -> Bool {
    (48...57).contains(byte)
}

private func parsePrintfInteger(_ bytes: [UInt8], index: inout Int) -> Int? {
    let start = index
    var value = 0
    while index < bytes.count, isASCIIDigit(bytes[index]) {
        let digit = Int(bytes[index] - 48)
        if value > (Int.max - digit) / 10 {
            index = start
            return nil
        }
        value = value * 10 + digit
        index += 1
    }
    return index == start ? nil : value
}

private func parsePrintfFormat(_ format: String) -> ParsedPrintfFormat {
    let bytes = Array(format.utf8)
    var positions: [Int: String] = [:]
    var nextImplicitPosition = 1
    var isValid = true
    var sawExplicitArgument = false
    var sawImplicitArgument = false
    var index = 0

    func addArgument(position: Int?, type: String) {
        if position == nil {
            sawImplicitArgument = true
        } else {
            sawExplicitArgument = true
        }
        if sawExplicitArgument && sawImplicitArgument {
            isValid = false
        }

        let actualPosition: Int
        if let position {
            if position < 1 { isValid = false }
            actualPosition = position
        } else {
            actualPosition = nextImplicitPosition
            nextImplicitPosition += 1
        }

        if let existing = positions[actualPosition], existing != type {
            isValid = false
        } else {
            positions[actualPosition] = type
        }
    }

    func consumeStarArgument() {
        // A star in a width or precision consumes an integer argument. A
        // positional star uses the POSIX form *m$, for example %2$*1$d.
        var starPosition: Int?
        if let number = parsePrintfInteger(bytes, index: &index) {
            if index < bytes.count, bytes[index] == 36 {
                starPosition = number
                index += 1
            } else {
                // Digits after a star are not a width; only *m$ is valid.
                isValid = false
            }
        }
        addArgument(position: starPosition, type: "*")
    }

    while index < bytes.count {
        guard bytes[index] == 37 else {
            index += 1
            continue
        }

        let percentIndex = index
        index += 1
        guard index < bytes.count else {
            isValid = false
            break
        }

        // A literal percent does not consume an argument.
        if bytes[index] == 37 {
            index += 1
            continue
        }

        // %#@variable@ is the special stringsdict variable reference, not
        // an NSString printf %@ argument. It is checked separately below.
        if bytes[index] == 35, index + 1 < bytes.count, bytes[index + 1] == 64 {
            index += 2
            let nameStart = index
            guard index < bytes.count,
                  (65...90).contains(bytes[index]) || (97...122).contains(bytes[index])
            else {
                isValid = false
                continue
            }
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                guard isASCIIDigit(byte)
                    || (65...90).contains(byte)
                    || (97...122).contains(byte)
                    || byte == 45
                    || byte == 95
                else { break }
                index += 1
            }
            guard index < bytes.count, bytes[index] == 64, index > nameStart else {
                isValid = false
                continue
            }
            index += 1
            continue
        }

        // Optional value argument position, such as %2$@. If the digits are
        // not followed by $, they are the minimum field width instead.
        var valuePosition: Int?
        let positionStart = index
        if let number = parsePrintfInteger(bytes, index: &index),
           index < bytes.count, bytes[index] == 36 {
            valuePosition = number
            index += 1
        } else {
            index = positionStart
        }

        while index < bytes.count, printfFlagCharacters.contains(bytes[index]) {
            index += 1
        }

        if index < bytes.count, bytes[index] == 42 {
            index += 1
            consumeStarArgument()
        } else {
            _ = parsePrintfInteger(bytes, index: &index)
        }

        if index < bytes.count, bytes[index] == 46 {
            index += 1
            if index < bytes.count, bytes[index] == 42 {
                index += 1
                consumeStarArgument()
            } else {
                _ = parsePrintfInteger(bytes, index: &index)
            }
        }

        var length = ""
        if index + 1 < bytes.count,
           bytes[index] == 104, bytes[index + 1] == 104 {
            length = "hh"
            index += 2
        } else if index + 1 < bytes.count,
                  bytes[index] == 108, bytes[index + 1] == 108 {
            length = "ll"
            index += 2
        } else if index < bytes.count, printfLengthCharacters.contains(bytes[index]) {
            length = String(UnicodeScalar(bytes[index]))
            index += 1
        }

        guard index < bytes.count, printfConversionCharacters.contains(bytes[index]) else {
            // Always make progress on malformed directives so a bad percent
            // cannot turn into an infinite loop.
            isValid = false
            index = max(index, percentIndex + 1)
            continue
        }
        let conversion = String(UnicodeScalar(bytes[index]))
        index += 1
        addArgument(position: valuePosition, type: length + conversion)
    }

    var signature = positions.keys.sorted().compactMap { position -> String? in
        guard let type = positions[position] else { return nil }
        return "\(position):\(type)"
    }
    if !isValid { signature.append("invalid-format") }
    return ParsedPrintfFormat(signature: signature, isValid: isValid)
}

/// Returns a stable position:type signature. Explicit positional arguments
/// are sorted by position, so a translation may reorder arguments without
/// being rejected; adding/removing an argument, changing its type, or
/// changing a star width/precision argument is detected. Literal %% pairs
/// consume no arguments. The special %#@variable@ stringsdict reference is
/// ignored here and validated as a plural variable below.
func printfSignature(_ format: String) -> [String] {
    parsePrintfFormat(format).signature
}

func comparePrintfSignatures(
    packages: [LocalizationPackage],
    report: inout ValidationReport
) {
    guard let english = packages.first(where: { $0.identifier.lowercased() == "en" }) else { return }

    // Iterate every baseline key so a translation cannot add a placeholder to
    // a previously static string unnoticed. `%%` contributes no signature.
    for key in english.strings.keys.sorted() {
        let englishFormat = english.strings[key] ?? ""
        let englishParsed = parsePrintfFormat(englishFormat)
        let englishSignature = englishParsed.signature
        if !englishParsed.isValid {
            report.fail("en: invalid printf format for '\(key)'")
        }
        for package in packages where package.identifier.lowercased() != "en" {
            guard let localized = package.strings[key] else { continue }
            let localizedParsed = parsePrintfFormat(localized)
            let localizedSignature = localizedParsed.signature
            if !localizedParsed.isValid {
                report.fail("\(package.identifier): invalid printf format for '\(key)'")
            }
            if englishSignature.isEmpty, localizedSignature.isEmpty { continue }
            guard localizedSignature == englishSignature else {
                report.fail(
                    "\(package.identifier): printf signature mismatch for '\(key)' "
                        + "(en: \(englishSignature), localized: \(localizedSignature))"
                )
                continue
            }
        }
    }
}

func pluralFormatVariables(_ format: String) -> [String] {
    let pattern = #"%#@([A-Za-z][A-Za-z0-9_-]*)@"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(format.startIndex..<format.endIndex, in: format)
    return expression.matches(in: format, range: range).compactMap {
        guard $0.numberOfRanges > 1,
              let swiftRange = Range($0.range(at: 1), in: format)
        else { return nil }
        return String(format[swiftRange])
    }
}

func dictionaryKeys(_ value: Any) -> Set<String> {
    (value as? [String: Any]).map { Set($0.keys) } ?? []
}

private let pluralMetadataKeys: Set<String> = [
    "NSStringFormatSpecTypeKey",
    "NSStringFormatValueTypeKey"
]

private let pluralCategoryKeys: Set<String> = [
    "zero", "one", "two", "few", "many", "other"
]

func pluralValueType(_ value: String) -> String? {
    // NSStringFormatValueTypeKey commonly contains d/ld/lld/f/@. Keep the
    // length modifier because it is part of the C printf argument type.
    let bytes = Array(value.utf8)
    guard let conversion = bytes.last,
          printfConversionCharacters.contains(conversion)
    else { return nil }
    let length = String(decoding: bytes.dropLast(), as: UTF8.self)
    guard ["", "h", "hh", "l", "ll", "q", "z", "t", "j", "L"].contains(length)
    else { return nil }
    return value
}

func validatePluralEntry(
    _ entry: [String: Any],
    key: String,
    packageID: String,
    report: inout ValidationReport
) -> (format: String, variables: [String])? {
    let path = "\(packageID)/Localizable.stringsdict: '\(key)'"
    guard let format = entry["NSStringLocalizedFormatKey"] as? String,
          !format.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        report.fail("\(path) missing NSStringLocalizedFormatKey")
        return nil
    }

    let variables = pluralFormatVariables(format)
    let uniqueVariables = Array(Set(variables)).sorted()
    guard !uniqueVariables.isEmpty else {
        report.fail("\(path) has no %#@variable@ reference")
        return nil
    }

    let allowedEntryKeys = Set(["NSStringLocalizedFormatKey"]).union(uniqueVariables)
    for extraKey in Set(entry.keys).subtracting(allowedEntryKeys).sorted() {
        report.fail("\(path) contains unexpected key '\(extraKey)'")
    }

    for variable in uniqueVariables {
        let variablePath = "\(path).\(variable)"
        guard let dictionary = entry[variable] as? [String: Any] else {
            report.fail("\(variablePath) is missing or not a dictionary")
            continue
        }

        guard let specType = dictionary["NSStringFormatSpecTypeKey"] as? String,
              !specType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            report.fail("\(variablePath) missing NSStringFormatSpecTypeKey")
            continue
        }
        guard specType == "NSStringPluralRuleType" else {
            report.fail("\(variablePath) has unsupported NSStringFormatSpecTypeKey '\(specType)'")
            continue
        }

        guard let valueTypeValue = dictionary["NSStringFormatValueTypeKey"] as? String,
              let valueType = pluralValueType(valueTypeValue)
        else {
            report.fail("\(variablePath) missing or invalid NSStringFormatValueTypeKey")
            continue
        }

        guard let other = dictionary["other"] as? String,
              !other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            report.fail("\(variablePath) requires a non-empty 'other' branch")
            continue
        }

        let allowedVariableKeys = pluralMetadataKeys.union(pluralCategoryKeys)
        for extraKey in Set(dictionary.keys).subtracting(allowedVariableKeys).sorted() {
            report.fail("\(variablePath) contains unexpected key '\(extraKey)'")
        }

        let expectedSignature = ["1:\(valueType)"]
        for category in Set(dictionary.keys).intersection(pluralCategoryKeys).sorted() {
            guard let branch = dictionary[category] as? String else {
                report.fail("\(variablePath).\(category) must be a string")
                continue
            }
            if branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                report.fail("\(variablePath).\(category) is empty")
            }
            let actualSignature = printfSignature(branch)
            if actualSignature != expectedSignature {
                report.fail(
                    "\(variablePath).\(category) printf signature does not match "
                        + "value type \(valueTypeValue) (expected: \(expectedSignature), actual: \(actualSignature))"
                )
            }
        }
    }
    return (format, variables.sorted())
}

func comparePluralBranchSignatures(
    englishVariable: [String: Any],
    localizedVariable: [String: Any],
    key: String,
    variable: String,
    packageID: String,
    report: inout ValidationReport
) {
    guard let englishOther = englishVariable["other"] as? String else { return }
    let englishOtherSignature = printfSignature(englishOther)
    for category in Set(localizedVariable.keys).intersection(pluralCategoryKeys).sorted() {
        guard let localizedValue = localizedVariable[category] as? String else { continue }
        let reference = (englishVariable[category] as? String) ?? englishOther
        let referenceSignature = printfSignature(reference)
        let localizedSignature = printfSignature(localizedValue)
        if localizedSignature != referenceSignature {
            report.fail(
                "\(packageID): plural printf signature mismatch for "
                    + "'\(key).\(variable).\(category)' "
                    + "(en: \(referenceSignature), localized: \(localizedSignature))"
            )
        }
        // Keep this explicit so an English 'other' branch with a malformed
        // signature is still diagnosed even when a locale adds new categories.
        if englishOtherSignature.isEmpty {
            report.fail("en/Localizable.stringsdict: '\(key).\(variable).other' has no printf argument")
        }
    }
}

func compareStringsDictStructure(
    packages: [LocalizationPackage],
    report: inout ValidationReport
) {
    guard let english = packages.first(where: { $0.identifier.lowercased() == "en" }) else { return }

    var englishEntries: [String: (format: String, variables: [String])] = [:]
    for key in english.stringsDict.keys.sorted() {
        guard let englishEntry = english.stringsDict[key] as? [String: Any],
              let validated = validatePluralEntry(
                  englishEntry,
                  key: key,
                  packageID: "en",
                  report: &report
              )
        else {
            report.fail("en/Localizable.stringsdict: plural key '\(key)' must contain a dictionary")
            continue
        }
        englishEntries[key] = validated

        for package in packages where package.identifier.lowercased() != "en" {
            guard let localizedEntry = package.stringsDict[key] as? [String: Any],
                  let localized = validatePluralEntry(
                      localizedEntry,
                      key: key,
                      packageID: package.identifier,
                      report: &report
                  )
            else {
                continue
            }

            let englishVariables = validated.variables
            if localized.variables != englishVariables {
                report.fail(
                    "\(package.identifier): plural variables mismatch for '\(key)' "
                        + "(en: \(englishVariables), localized: \(localized.variables))"
                )
            }

            let englishFormatSignature = printfSignature(validated.format)
            let localizedFormatSignature = printfSignature(localized.format)
            if localizedFormatSignature != englishFormatSignature {
                report.fail(
                    "\(package.identifier): plural format printf signature mismatch for '\(key)' "
                        + "(en: \(englishFormatSignature), localized: \(localizedFormatSignature))"
                )
            }

            for variable in Set(englishVariables).union(localized.variables).sorted() {
                guard let englishVariable = english.stringsDict[key] as? [String: Any],
                      let englishDictionary = englishVariable[variable] as? [String: Any],
                      let localizedDictionary = localizedEntry[variable] as? [String: Any]
                else {
                    report.fail("\(package.identifier): plural variable '\(variable)' missing for '\(key)'")
                    continue
                }
                if englishDictionary["NSStringFormatSpecTypeKey"] as? String
                    != localizedDictionary["NSStringFormatSpecTypeKey"] as? String {
                    report.fail(
                        "\(package.identifier): plural spec type mismatch for '\(key).\(variable)'"
                    )
                }
                if englishDictionary["NSStringFormatValueTypeKey"] as? String
                    != localizedDictionary["NSStringFormatValueTypeKey"] as? String {
                    report.fail(
                        "\(package.identifier): plural value type mismatch for '\(key).\(variable)'"
                    )
                }
                comparePluralBranchSignatures(
                    englishVariable: englishDictionary,
                    localizedVariable: localizedDictionary,
                    key: key,
                    variable: variable,
                    packageID: package.identifier,
                    report: &report
                )
            }
        }
    }

    for package in packages where package.identifier.lowercased() != "en" {
        for key in package.stringsDict.keys.sorted() where englishEntries[key] == nil {
            // Key-set validation reports this separately; validating the
            // extra entry here still catches malformed plural dictionaries.
            if let entry = package.stringsDict[key] as? [String: Any] {
                _ = validatePluralEntry(entry, key: key, packageID: package.identifier, report: &report)
            }
        }
    }
}

struct SourceLocalizationReferences {
    var fixedKeys: Set<String> = []
    var dynamicPrefixes: Set<String> = []
}

// This is a SettingsPane raw value used as an SF Symbol name, not a lookup
// key. Keep the source audit focused on strings that can reach Localizer.
private let nonLocalizationSourceStrings: Set<String> = [
    "waveform.path"
]

func sourceLocalizationReferences(repositoryRoot: URL) -> SourceLocalizationReferences {
    var references = SourceLocalizationReferences()
    let sourceRoot = repositoryRoot.appendingPathComponent("Tactile", isDirectory: true)
    let pattern = "\"((?:language|window|menu|onboarding|settings|feedback|waveform|dialog|format|a11y|error)\\.[^\"]*)\""
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let enumerator = fileManager.enumerator(
              at: sourceRoot,
              includingPropertiesForKeys: [.isRegularFileKey],
              options: [.skipsHiddenFiles]
          )
    else { return references }

    for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
        guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in expression.matches(in: source, range: range) {
            guard match.numberOfRanges > 1,
                  let swiftRange = Range(match.range(at: 1), in: source)
            else { continue }
            let key = String(source[swiftRange])
            guard !nonLocalizationSourceStrings.contains(key) else { continue }
            if let interpolation = key.range(of: "\\(") {
                let prefix = String(key[..<interpolation.lowerBound])
                if !prefix.isEmpty { references.dynamicPrefixes.insert(prefix) }
            } else if !key.contains("\\") {
                references.fixedKeys.insert(key)
            }
        }
    }
    return references
}

func sourceReferenceAudit(
    repositoryRoot: URL,
    packages: [LocalizationPackage],
    report: inout ValidationReport
) {
    guard let english = packages.first(where: { $0.identifier.lowercased() == "en" }) else { return }
    let references = sourceLocalizationReferences(repositoryRoot: repositoryRoot)
    let resourceKeys = Set(english.strings.keys).union(english.stringsDict.keys)

    for key in references.fixedKeys.subtracting(resourceKeys).sorted() {
        report.fail("source audit: code key '\(key)' has no English resource")
    }

    let dynamicallyReferenced = resourceKeys.filter { key in
        references.dynamicPrefixes.contains { key.hasPrefix($0) }
    }
    for key in resourceKeys
        .subtracting(references.fixedKeys)
        .subtracting(dynamicallyReferenced)
        .sorted() {
        report.fail("source audit: English resource key '\(key)' is not referenced by Swift")
    }
}

func runMatcherMatrix(
    repositoryRoot: URL,
    packageIdentifiers: [String],
    report: inout ValidationReport
) {
    let matcherURL = repositoryRoot
        .appendingPathComponent("Tactile", isDirectory: true)
        .appendingPathComponent("Localization", isDirectory: true)
        .appendingPathComponent("LanguageIdentifierMatcher.swift")

    guard fileManager.fileExists(atPath: matcherURL.path) else {
        report.fail("matcher source not found: \(matcherURL.path)")
        return
    }

    let temporaryRoot = fileManager.temporaryDirectory
        .appendingPathComponent("tactile-localization-validator-\(UUID().uuidString)", isDirectory: true)
    do {
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    } catch {
        report.fail("unable to create matcher test directory: \(error)")
        return
    }
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    let harnessURL = temporaryRoot.appendingPathComponent("MatcherHarness.swift")
    let executableURL = temporaryRoot.appendingPathComponent("matcher-harness")
    let harness = #"""
    import Foundation
    #if canImport(Darwin)
    import Darwin
    #else
    import Glibc
    #endif

    struct MatcherCase {
        let name: String
        let preferred: String?
        let available: [String]
        let expected: String
    }

    @main
    struct MatcherHarness {
        static func main() {
            let cases = [
                MatcherCase(name: "zh-Hans exact", preferred: "zh-Hans", available: ["en", "zh-Hans"], expected: "zh-Hans"),
                MatcherCase(name: "zh-Hans-CN -> zh-Hans", preferred: "zh-Hans-CN", available: ["en", "zh-Hans"], expected: "zh-Hans"),
                MatcherCase(name: "zh-CN -> zh-Hans", preferred: "zh-CN", available: ["en", "zh-Hans"], expected: "zh-Hans"),
                MatcherCase(name: "zh-SG -> zh-Hans", preferred: "zh-SG", available: ["en", "zh-Hans"], expected: "zh-Hans"),
                MatcherCase(name: "zh-Hant exact", preferred: "zh-Hant", available: ["en", "zh-Hant"], expected: "zh-Hant"),
                MatcherCase(name: "zh-Hant -> en", preferred: "zh-Hant", available: ["en", "zh-Hans"], expected: "en"),
                MatcherCase(name: "zh-TW -> en", preferred: "zh-TW", available: ["en", "zh-Hans"], expected: "en"),
                MatcherCase(name: "zh-HK -> en", preferred: "zh-HK", available: ["en", "zh-Hans"], expected: "en"),
                MatcherCase(name: "zh-MO -> en", preferred: "zh-MO", available: ["en", "zh-Hans"], expected: "en"),
                MatcherCase(name: "en exact", preferred: "en", available: ["en"], expected: "en"),
                MatcherCase(name: "en-US -> en", preferred: "en-US", available: ["en"], expected: "en"),
                MatcherCase(name: "en-GB -> en", preferred: "en-GB", available: ["en"], expected: "en"),
                MatcherCase(name: "fr exact", preferred: "fr", available: ["en", "fr"], expected: "fr"),
                MatcherCase(name: "fr-FR -> fr", preferred: "fr-FR", available: ["en", "fr"], expected: "fr"),
                MatcherCase(name: "fr-FR does not use fr-CA", preferred: "fr-FR", available: ["en", "fr-CA"], expected: "en"),
                MatcherCase(name: "pt exact", preferred: "pt", available: ["en", "pt"], expected: "pt"),
                MatcherCase(name: "pt-BR does not use pt-PT", preferred: "pt-BR", available: ["en", "pt-PT"], expected: "en"),
                MatcherCase(name: "pt-PT exact match", preferred: "pt-PT", available: ["en", "pt-PT"], expected: "pt-PT"),
                MatcherCase(name: "pt-BR uses generic pt", preferred: "pt-BR", available: ["en", "pt"], expected: "pt"),
                MatcherCase(name: "Unicode extension is ignored", preferred: "zh-CN-u-nu-hanidec", available: ["en", "zh-Hans"], expected: "zh-Hans"),
                MatcherCase(name: "Unicode extension on English", preferred: "en-US-u-ca-gregory", available: ["en"], expected: "en"),
                MatcherCase(name: "numeric extension singleton", preferred: "en-0-abc", available: ["en"], expected: "en"),
                MatcherCase(name: "private-use extension is ignored", preferred: "en-US-x-private", available: ["en"], expected: "en"),
                MatcherCase(name: "underscore normalization", preferred: "zh_CN", available: ["en", "zh-Hans"], expected: "zh-Hans"),
                MatcherCase(name: "invalid preferred identifier", preferred: "1-invalid", available: ["en", "fr"], expected: "en"),
                MatcherCase(name: "invalid preferred language", preferred: "x-private", available: ["en", "fr"], expected: "en"),
                MatcherCase(name: "invalid candidates are ignored", preferred: "fr-FR", available: ["en", "!!!", "fr"], expected: "fr"),
                MatcherCase(name: "variant package is not generic", preferred: "fr-FR", available: ["en", "fr-1901"], expected: "en"),
                MatcherCase(name: "missing preferred identifier", preferred: nil, available: ["fr", "en"], expected: "en")
            ]
            let packageIdentifiers = __PACKAGE_IDENTIFIERS__

            var failures: [String] = []
            for test in cases {
                let actual = LanguageIdentifierMatcher.match(
                    preferredIdentifier: test.preferred,
                    availableIdentifiers: test.available,
                    fallbackIdentifier: "en"
                )
                if actual != test.expected {
                    failures.append("\(test.name): expected \(test.expected), got \(actual)")
                }
            }

            let invalidIdentifiers = ["", "1", "a", "1234", "x-private"]
            for identifier in invalidIdentifiers where LanguageIdentifierMatcher.normalize(identifier) != nil {
                failures.append("normalize(\(identifier.debugDescription)) unexpectedly accepted invalid identifier")
            }

            // RFC 5646 permits numeric extension singletons; the invalid
            // condition here is reusing the same singleton more than once.
            if LanguageIdentifierMatcher.normalize("en-0-abc") == nil {
                failures.append("normalize(\"en-0-abc\") incorrectly rejected a numeric extension singleton")
            }
            if LanguageIdentifierMatcher.normalize("en-u-ca-gregory-u-nu-latn") != nil {
                failures.append("normalize(\"en-u-ca-gregory-u-nu-latn\") accepted a duplicate extension singleton")
            }
            if LanguageIdentifierMatcher.normalize("en-u-ca-gregory-U-nu-latn") != nil {
                failures.append("normalize(\"en-u-ca-gregory-U-nu-latn\") accepted a case-insensitive duplicate singleton")
            }
            if LanguageIdentifierMatcher.normalize("en-u") != nil {
                failures.append("normalize(\"en-u\") accepted an extension without a subtag")
            }
            if LanguageIdentifierMatcher.normalize("en-1901-1901") != nil {
                failures.append("normalize(\"en-1901-1901\") accepted a duplicate variant")
            }

            var normalizedPackageIdentifiers: [String: String] = [:]
            for rawIdentifier in packageIdentifiers {
                guard let normalized = LanguageIdentifierMatcher.normalize(rawIdentifier) else {
                    failures.append("resource identifier \(rawIdentifier.debugDescription) is rejected by production matcher")
                    continue
                }
                if let previous = normalizedPackageIdentifiers[normalized] {
                    failures.append(
                        "resource identifiers \(previous.debugDescription) and \(rawIdentifier.debugDescription) normalize to the same \(normalized)"
                    )
                } else {
                    normalizedPackageIdentifiers[normalized] = rawIdentifier
                }
            }

            if failures.isEmpty {
                print(
                    "matcher matrix passed: \(cases.count) cases, "
                        + "\(invalidIdentifiers.count + 5 + packageIdentifiers.count) normalization checks"
                )
                return
            }
            for failure in failures { print("matcher error: \(failure)") }
            exit(1)
        }
    }
    """#.replacingOccurrences(
        of: "__PACKAGE_IDENTIFIERS__",
        with: "[" + packageIdentifiers.map(\.debugDescription).joined(separator: ", ") + "]"
    )

    do {
        try harness.write(to: harnessURL, atomically: true, encoding: .utf8)
    } catch {
        report.fail("unable to write matcher harness: \(error)")
        return
    }

    let configuredCompiler = ProcessInfo.processInfo.environment["SWIFTC"] ?? "/usr/bin/xcrun"
    let compilerURL = URL(fileURLWithPath: configuredCompiler)
    let usesXcrun = compilerURL.lastPathComponent == "xcrun"
    let arguments: [String] = (usesXcrun ? ["swiftc"] : []) + [
        matcherURL.path,
        harnessURL.path,
        "-module-cache-path",
        temporaryRoot.appendingPathComponent("ModuleCache", isDirectory: true).path,
        "-o",
        executableURL.path
    ]

    let compilation = Process()
    compilation.executableURL = compilerURL
    compilation.arguments = arguments
    let outputPipe = Pipe()
    compilation.standardOutput = outputPipe
    compilation.standardError = outputPipe

    do {
        try compilation.run()
        compilation.waitUntilExit()
    } catch {
        report.fail("unable to compile production matcher with \(configuredCompiler): \(error)")
        return
    }

    let compilationOutput = String(
        data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    guard compilation.terminationStatus == 0 else {
        report.fail(
            "production matcher compilation failed"
                + (compilationOutput.isEmpty ? "" : ":\n\(compilationOutput)")
        )
        return
    }

    let execution = Process()
    execution.executableURL = executableURL
    let executionPipe = Pipe()
    execution.standardOutput = executionPipe
    execution.standardError = executionPipe
    do {
        try execution.run()
        execution.waitUntilExit()
    } catch {
        report.fail("unable to execute matcher matrix: \(error)")
        return
    }

    let executionOutput = String(
        data: executionPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    if !executionOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        print(executionOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if execution.terminationStatus != 0 {
        report.fail("production matcher test matrix failed")
    }
}

func runSelfTests(repositoryRoot: URL, report: inout ValidationReport) {
    var assertionCount = 0

    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertionCount += 1
        if !condition() { report.fail("self-test: \(message)") }
    }

    do {
        var parser = StringsParser(
            source: "\"duplicate\" = \"first\";\n\"duplicate\" = \"second\";"
        )
        let parsed = try parser.parse()
        check(parsed.duplicateKeys == ["duplicate"], ".strings duplicate key was not reported")
        check(parsed.values["duplicate"] == "second", "last duplicate value was not retained for diagnostics")
    } catch {
        report.fail("self-test: .strings duplicate fixture failed to parse: \(error)")
    }

    do {
        var parser = StringsParser(
            source: "\"emoji\" = \"\\uD83D\\uDE00\";\n\"dash\" = \"\\U2014\";\n\"empty\" = \"\";"
        )
        let parsed = try parser.parse()
        check(parsed.values["emoji"] == "😀", "UTF-16 surrogate pair was not decoded")
        check(parsed.values["dash"] == "—", "four-digit \\U escape was not decoded")
        check(parsed.values["empty"]?.isEmpty == true, "empty .strings value was not retained")
    } catch {
        report.fail("self-test: Unicode .strings fixture failed to parse: \(error)")
    }
    let utf16Source = "\"utf16\" = \"value\";"
    check(
        decodeStringsSource(utf16Source.data(using: .utf16)!) == utf16Source,
        "UTF-16 .strings data was not decoded"
    )

    do {
        var parser = StringsParser(source: "\"broken\" = \"unterminated;\n")
        do {
            _ = try parser.parse()
            report.fail("self-test: unterminated .strings value was accepted")
        } catch is ParseFailure {
            assertionCount += 1
        } catch {
            report.fail("self-test: unterminated .strings reported wrong error: \(error)")
        }
    }

    let duplicateXML = Data(
        """
        <plist version="1.0"><dict>
          <key>root</key><string>one</string>
          <key>root</key><string>two</string>
          <key>nested</key><dict>
            <key>child</key><string>one</string>
            <key>child</key><string>two</string>
          </dict>
        </dict></plist>
        """.utf8
    )
    let duplicateDelegate = StringsDictDuplicateKeyDelegate()
    let duplicateParser = XMLParser(data: duplicateXML)
    duplicateParser.delegate = duplicateDelegate
    _ = duplicateParser.parse()
    check(
        Set(duplicateDelegate.duplicateKeys) == Set(["root", "child"]),
        "nested .stringsdict duplicate keys were not reported"
    )

    check(printfSignature("%d %@") == ["1:d", "2:@"], "implicit printf signature changed")
    check(
        printfSignature("%2$@ %1$d") == ["1:d", "2:@"],
        "positional printf reorder was not accepted"
    )
    check(
        printfSignature("%2$d %1$@") != printfSignature("%d %@"),
        "positional printf type swap was accepted"
    )
    check(printfSignature("100%%") == [], "escaped percent consumed an argument")
    check(
        printfSignature("%*.*f") == ["1:*", "2:*", "3:f"],
        "star width/precision arguments were not counted"
    )
    check(
        printfSignature("%3$*1$.*2$f") == ["1:*", "2:*", "3:f"],
        "positional star arguments were not mapped"
    )
    check(
        !parsePrintfFormat("%1$@ %@").isValid,
        "mixed positional and sequential printf arguments were accepted"
    )
    check(
        !parsePrintfFormat("%*10d").isValid,
        "digits after a printf star were accepted as a width"
    )
    check(
        !parsePrintfFormat("%n").isValid,
        "the unsupported printf %n conversion was accepted"
    )
    check(
        !parsePrintfFormat("bad %").isValid,
        "unterminated printf directive was accepted"
    )
    check(
        !parsePrintfFormat("%1$d %1$@").isValid,
        "conflicting positional printf types were accepted"
    )
    check(
        printfSignature("%#@count@") == [],
        "stringsdict variable reference was mistaken for printf argument"
    )
    check(pluralValueType("ld") == "ld", "plural length modifier was discarded")
    check(pluralValueType("bogus") == nil, "invalid plural value type was accepted")

    func pluralEntry(
        valueType: String = "d",
        branches: [String: String]
    ) -> [String: Any] {
        var variable: [String: Any] = [
            "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
            "NSStringFormatValueTypeKey": valueType
        ]
        for (category, value) in branches { variable[category] = value }
        return [
            "NSStringLocalizedFormatKey": "%#@count@",
            "count": variable
        ]
    }

    let english = LocalizationPackage(
        identifier: "en",
        directory: URL(fileURLWithPath: "/private/tmp/tactile-localization-self-test")
    )
    var englishPackage = english
    englishPackage.strings = [
        "language.pack.display-name": "English",
        "title": "Count: %d",
        "percent": "100%%"
    ]
    englishPackage.stringsDict = [
        "waveform.pulse-count": pluralEntry(branches: [
            "one": "%d pulse",
            "other": "%d pulses"
        ])
    ]

    var reorderedPackage = LocalizationPackage(
        identifier: "zh-Hans",
        directory: english.directory
    )
    reorderedPackage.strings = [
        "language.pack.display-name": "简体中文",
        "title": "数量：%1$d",
        "percent": "100%%"
    ]
    reorderedPackage.stringsDict = [
        "waveform.pulse-count": pluralEntry(branches: [
            "other": "%d 个脉冲",
            "few": "%d 个脉冲"
        ])
    ]

    var validReport = ValidationReport()
    compareKeySets(packages: [englishPackage, reorderedPackage], report: &validReport)
    comparePrintfSignatures(packages: [englishPackage, reorderedPackage], report: &validReport)
    compareStringsDictStructure(
        packages: [englishPackage, reorderedPackage],
        report: &validReport
    )
    check(validReport.isValid, "valid plural/reordered package was rejected: \(validReport.failures)")

    var badPackage = reorderedPackage
    badPackage.strings["title"] = "数量：%1$@"
    badPackage.strings.removeValue(forKey: "language.pack.display-name")
    badPackage.stringsDict["waveform.pulse-count"] = pluralEntry(branches: [
        "other": "%@",
        "few": "%@"
    ])
    var badReport = ValidationReport()
    compareKeySets(packages: [englishPackage, badPackage], report: &badReport)
    comparePrintfSignatures(packages: [englishPackage, badPackage], report: &badReport)
    compareStringsDictStructure(packages: [englishPackage, badPackage], report: &badReport)
    check(
        badReport.failures.contains { $0.contains("missing required key") }
            && badReport.failures.contains { $0.contains("printf signature mismatch") }
            && badReport.failures.contains { $0.contains("plural printf signature mismatch") },
        "error fixture did not expose key/display/printf/plural failures"
    )

    runMatcherMatrix(
        repositoryRoot: repositoryRoot,
        packageIdentifiers: ["en", "zh-Hans"],
        report: &report
    )

    if report.isValid {
        print("[localization] self-test passed: \(assertionCount) assertions")
    } else {
        report.printFailures()
    }
}

var report = ValidationReport()
if CommandLine.arguments.dropFirst().contains("--self-test") {
    runSelfTests(repositoryRoot: repositoryRoot, report: &report)
    exit(report.isValid ? 0 : 1)
}

let packages = loadPackages(at: localizationRoot, report: &report)

if packages.isEmpty {
    print("[localization] 未发现包：请先添加 Tactile/Localization/*.lproj 资源")
} else {
    print("[localization] discovered packages: \(packages.map(\.identifier).joined(separator: ", "))")
    compareKeySets(packages: packages, report: &report)
    comparePrintfSignatures(packages: packages, report: &report)
    compareStringsDictStructure(packages: packages, report: &report)
    sourceReferenceAudit(repositoryRoot: repositoryRoot, packages: packages, report: &report)
}

runMatcherMatrix(
    repositoryRoot: repositoryRoot,
    packageIdentifiers: packages.map(\.identifier),
    report: &report
)

if report.isValid && !packages.isEmpty {
    let ordinaryKeyCount = packages.first(where: { $0.identifier.lowercased() == "en" })?.strings.count ?? 0
    let pluralKeyCount = packages.first(where: { $0.identifier.lowercased() == "en" })?.stringsDict.count ?? 0
    print("[localization] validation passed: \(packages.count) packages, \(ordinaryKeyCount) ordinary keys, \(pluralKeyCount) plural keys")
    exit(0)
}

report.printFailures()
exit(1)
