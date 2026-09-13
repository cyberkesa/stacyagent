import Foundation

enum InputNormalizer {
    /// Cleans terminal/user text without changing semantic content or file paths.
    /// In particular, U+FFFD can appear when terminal redraw and UTF-8 input race;
    /// removing it often repairs terminal input where one decoded byte was replaced.
    static func sanitize(_ value: String) -> String {
        var output = value
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")

        // Keep tab/newline semantics but strip other control scalars that should
        // never participate in routing or task compilation.
        output.unicodeScalars.removeAll { scalar in
            CharacterSet.controlCharacters.contains(scalar) &&
            scalar.value != 0x09 &&
            scalar.value != 0x0A &&
            scalar.value != 0x0D
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func lexical(_ value: String) -> String {
        sanitize(value)
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func commandLexical(_ value: String) -> String {
        lexical(value)
            .trimmingCharacters(
                in: CharacterSet.punctuationCharacters
                    .union(.symbols)
                    .union(.whitespacesAndNewlines)
            )
    }
}
