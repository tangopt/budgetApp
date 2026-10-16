import Foundation

/// Decodes the glyph names BBVA Portugal's PDFs use instead of a text layer (spec §3: "BBVA
/// glyph decoding"). Their Type 3 fonts carry no `ToUnicode` map, only an encoding whose glyph
/// names spell the character:
///
/// - `UNIC00E9` → the code point (`é`);
/// - `L<letter><nn>0000` → the letter: `01` lowercase, `02` capital, and accented variants
///   (`11`/`12` acute, `13`/`14` grave, `15`/`16` circumflex, `19`/`20` tilde, `41`/`42`
///   cedilla — odd lowercase, even capital); seen in BBVA's PDFs, whose codes are Windows-1252;
/// - `ND<nn>0000` → the digit `nn % 10` (`ND100000` is `0`);
/// - `SP<nn>0000`, `SM<nn>0000`, `SA<nn>0000` → punctuation and symbols (`SP010000` space,
///   `SP110000` `.`, `SP130000` `:`, `SM020000` `%`, `SA010000` `+` …);
/// - plus the standard PostScript names (`A`, `space`, `comma`, `eacute` …) other PDFs use.
public enum GlyphNameDecoder {
    /// Punctuation and symbols, by the name's first four characters.
    static let punctuation: [String: String] = [
        "SP01": " ", "SP04": "\"", "SP06": "(", "SP07": ")", "SP08": ",", "SP10": "-", "SP11": ".", "SP12": "/",
        "SP13": ":", "SM02": "%", "SM04": "*", "SM20": "º", "SA01": "+"
    ]

    /// `L<letter><nn>` variants: the combining mark (nil for none); odd is lowercase.
    static let letterVariants: [String: (mark: String?, capital: Bool)] = [
        "01": (nil, false), "02": (nil, true),
        "11": ("\u{301}", false), "12": ("\u{301}", true), "13": ("\u{300}", false), "14": ("\u{300}", true),
        "15": ("\u{302}", false), "16": ("\u{302}", true), "19": ("\u{303}", false), "20": ("\u{303}", true),
        "41": ("\u{327}", false), "42": ("\u{327}", true)
    ]

    /// The character a glyph name stands for ("" for an unknown BBVA symbol), or nil for a name
    /// it doesn't know (the caller falls back to the character code).
    public static func character(forGlyphName rawName: String) -> String? {
        let name = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName
        let chars = Array(name)
        if name.hasPrefix("UNIC"), chars.count == 8, let scalar = UInt32(String(chars[4...]), radix: 16).flatMap(Unicode.Scalar.init) {
            return String(Character(scalar))
        }
        if chars.count == 8, name.hasSuffix("0000") {
            let variant = String(chars[2...3])
            if chars[0] == "L", chars[1].isASCII, chars[1].isUppercase, variant.allSatisfy(\.isNumber) {
                guard let (mark, capital) = letterVariants[variant] else { return nil }
                let letter = capital ? String(chars[1]) : chars[1].lowercased()
                return (letter + (mark ?? "")).precomposedStringWithCanonicalMapping
            }
            if name.hasPrefix("ND"), let digit = Int(variant) {
                return String(digit % 10)
            }
            if let symbol = punctuation[String(chars[0...3])] {
                return symbol
            }
            // An SP/SM/SA symbol not seen yet: dropped rather than guessed.
            if ["SP", "SM", "SA"].contains(String(chars[0...1])), variant.allSatisfy(\.isNumber) {
                return ""
            }
        }
        if let standard = standardNames[name] { return standard }
        if chars.count == 1 { return name } // `A`, `a`, `1`: the name is the character
        if name.hasPrefix("uni"), chars.count == 7, let scalar = UInt32(String(chars[3...]), radix: 16).flatMap(Unicode.Scalar.init) {
            return String(Character(scalar))
        }
        return nil
    }

    /// Replaces every `/UNICxxxx`, `/L<letter>nn0000`, `/NDnn0000`, `/SPnn0000`, `/SMnn0000`
    /// and `/SAnn0000` in `text` (glyph names some extractors print verbatim) with its
    /// character; unknown symbols are dropped and other names it doesn't know become `?`. A port of the scratch scripts' `dec`, which
    /// also reads the accented letter variants.
    public static func decode(_ text: String) -> String {
        guard text.contains("/") else { return text }
        let pattern = #"/(UNIC[0-9A-Fa-f]{4}|L[A-Z]\d{2}0000|(?:ND|SP|SM|SA)\d{2}0000)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += character(forGlyphName: source.substring(with: match.range(at: 1))) ?? "?"
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }

    /// Whether `name` is one of the obfuscated BBVA names (rather than a standard one).
    static func isObfuscatedName(_ name: String) -> Bool {
        let chars = Array(name)
        guard chars.count == 8 else { return false }
        if name.hasPrefix("UNIC") { return true }
        guard name.hasSuffix("0000") else { return false }
        return (chars[0] == "L" && chars[1].isUppercase) || ["ND", "SP", "SM", "SA"].contains(String(chars[0...1]))
    }

    /// The common PostScript glyph names (Adobe Glyph List) for Latin text.
    static let standardNames: [String: String] = [
        "space": " ", "exclam": "!", "quotedbl": "\"", "numbersign": "#", "dollar": "$", "percent": "%",
        "ampersand": "&", "quotesingle": "'", "quoteright": "’", "quoteleft": "‘", "parenleft": "(", "parenright": ")",
        "asterisk": "*", "plus": "+", "comma": ",", "hyphen": "-", "minus": "-", "period": ".", "slash": "/",
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "colon": ":", "semicolon": ";", "less": "<", "equal": "=", "greater": ">",
        "question": "?", "at": "@", "bracketleft": "[", "backslash": "\\", "bracketright": "]", "underscore": "_",
        "braceleft": "{", "bar": "|", "braceright": "}", "endash": "–", "emdash": "—", "bullet": "•",
        "Euro": "€", "euro": "€", "sterling": "£", "ordfeminine": "ª", "ordmasculine": "º", "degree": "°",
        "quotedblleft": "“", "quotedblright": "”", "guillemotleft": "«", "guillemotright": "»", "nbspace": " ",
        "Aacute": "Á", "aacute": "á", "Agrave": "À", "agrave": "à", "Acircumflex": "Â", "acircumflex": "â",
        "Atilde": "Ã", "atilde": "ã", "Ccedilla": "Ç", "ccedilla": "ç", "Eacute": "É", "eacute": "é",
        "Egrave": "È", "egrave": "è", "Ecircumflex": "Ê", "ecircumflex": "ê", "Iacute": "Í", "iacute": "í",
        "Oacute": "Ó", "oacute": "ó", "Ocircumflex": "Ô", "ocircumflex": "ô", "Otilde": "Õ", "otilde": "õ",
        "Uacute": "Ú", "uacute": "ú", "Udieresis": "Ü", "udieresis": "ü", "Ntilde": "Ñ", "ntilde": "ñ"
    ]
}
