import Testing
import Foundation

/// Guards the String Catalogs: a key missing in one language falls back to English silently at runtime,
/// so coverage is enforced here instead.
@Suite struct LocalizationCatalogTests {
    static let languages = ["tr", "de", "fr", "es", "ja", "pt-BR"]
    /// Languages whose count strings need distinct plural forms (Japanese uses `other` only).
    static let pluralLanguages = ["tr", "de", "fr", "es", "pt-BR"]

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let catalogPaths = [
        "Sources/Leftless/Localizable.xcstrings",
        "Sources/LeftlessCore/Localizable.xcstrings",
        "App/InfoPlist.xcstrings",
    ]

    typealias JSON = [String: Any]

    static func strings(_ relativePath: String) throws -> [String: JSON] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(relativePath))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? JSON)
        #expect(root["sourceLanguage"] as? String == "en", "\(relativePath): source language")
        return try #require(root["strings"] as? [String: JSON])
    }

    /// Every leaf `stringUnit` under a localization (plain, plural variants and substitutions).
    static func stringUnits(in node: JSON) -> [JSON] {
        var units: [JSON] = []
        if let unit = node["stringUnit"] as? JSON { units.append(unit) }
        if let variations = node["variations"] as? JSON {
            for case let byCase as JSON in variations.values {
                for case let variant as JSON in byCase.values { units += stringUnits(in: variant) }
            }
        }
        if let substitutions = node["substitutions"] as? JSON {
            for case let substitution as JSON in substitutions.values { units += stringUnits(in: substitution) }
        }
        return units
    }

    /// Plural variants either on the whole string or on a substituted argument.
    static func pluralVariants(in localization: JSON) -> [JSON] {
        var result: [JSON] = []
        if let plural = (localization["variations"] as? JSON)?["plural"] as? JSON { result.append(plural) }
        if let substitutions = localization["substitutions"] as? JSON {
            for case let substitution as JSON in substitutions.values {
                if let plural = (substitution["variations"] as? JSON)?["plural"] as? JSON { result.append(plural) }
            }
        }
        return result
    }

    @Test(arguments: catalogPaths)
    func everyKeyTranslatedInAllLanguages(_ path: String) throws {
        let strings = try Self.strings(path)
        #expect(!strings.isEmpty, "\(path) has no keys")
        for (key, entry) in strings where entry["shouldTranslate"] as? Bool != false {
            let localizations = entry["localizations"] as? JSON ?? [:]
            for language in Self.languages {
                guard let localization = localizations[language] as? JSON else {
                    Issue.record("\(path): \"\(key)\" missing \(language)")
                    continue
                }
                let units = Self.stringUnits(in: localization)
                #expect(!units.isEmpty, "\(path): \"\(key)\" [\(language)] has no string unit")
                for unit in units {
                    let value = unit["value"] as? String ?? ""
                    #expect(unit["state"] as? String == "translated" && !value.isEmpty,
                            "\(path): \"\(key)\" [\(language)] not translated")
                }
            }
        }
    }

    @Test(arguments: catalogPaths)
    func countKeysHavePluralVariants(_ path: String) throws {
        let strings = try Self.strings(path)
        for (key, entry) in strings where key.contains("%lld") {
            let localizations = entry["localizations"] as? JSON ?? [:]
            for language in Self.pluralLanguages {
                let plurals = Self.pluralVariants(in: localizations[language] as? JSON ?? [:])
                #expect(plurals.contains { $0["one"] != nil && $0["other"] != nil },
                        "\(path): \"\(key)\" [\(language)] needs plural one/other")
            }
        }
    }

    @Test func noTurkishLiteralsInAppSources() throws {
        let turkish = CharacterSet(charactersIn: "çğıöşüÇĞİÖŞÜ")
        let sources = Self.repoRoot.appendingPathComponent("Sources/Leftless")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for literal in Self.stringLiterals(in: text) where literal.rangeOfCharacter(from: turkish) != nil {
                Issue.record("\(file.lastPathComponent): Turkish literal \"\(literal)\"")
            }
        }
    }

    @Test func literalScannerSkipsCommentsAndFindsStrings() {
        let source = """
        // "yorum: çöp"
        let a = "Çöp" /* "ş" */ + "ok"
        """
        #expect(Self.stringLiterals(in: source) == ["Çöp", "ok"])
    }

    /// Contents of string literals in Swift source, ignoring `//` and `/* */` comments.
    static func stringLiterals(in source: String) -> [String] {
        var literals: [String] = []
        var current = ""
        var inString = false, inLineComment = false, inBlockComment = false
        var chars = Array(source)[...]
        while let c = chars.popFirst() {
            if inLineComment {
                if c == "\n" { inLineComment = false }
            } else if inBlockComment {
                if c == "*", chars.first == "/" { chars.removeFirst(); inBlockComment = false }
            } else if inString {
                if c == "\\", let next = chars.popFirst() {
                    current.append(c); current.append(next)
                } else if c == "\"" {
                    literals.append(current); current = ""; inString = false
                } else {
                    current.append(c)
                }
            } else if c == "/", chars.first == "/" {
                inLineComment = true
            } else if c == "/", chars.first == "*" {
                chars.removeFirst(); inBlockComment = true
            } else if c == "\"" {
                inString = true
            }
        }
        return literals.filter { !$0.isEmpty }
    }
}
