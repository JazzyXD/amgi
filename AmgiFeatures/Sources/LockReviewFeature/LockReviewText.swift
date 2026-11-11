//
//  LockReviewText.swift
//  LockReviewFeature
//

#if os(iOS)
import Foundation

/// Card HTML to the plain text a Live Activity can draw.
///
/// A Live Activity is SwiftUI only: no web view, so no card CSS, no images,
/// no MathJax. `CardText.plainText` in `AmgiCardWeb` is close, but it removes
/// tags without leaving a line break behind, which turns `猫<br>cat` into
/// `猫cat`. The Lock Screen card has room for a few short lines, so breaks
/// matter here.
enum LockReviewText {
    /// Front side as plain text.
    static func question(_ frontHTML: String) -> String {
        plain(frontHTML)
    }

    /// Back side as plain text, without the question repeated on top.
    ///
    /// Most back templates are `{{FrontSide}}<hr id=answer>…`. Showing the
    /// front again would spend the whole card on text the user just read.
    static func answer(frontHTML: String, backHTML: String) -> String {
        let divider = #"(?i)<hr\b[^>]*\bid\s*=\s*["']?answer["']?[^>]*>"#
        if let range = backHTML.range(of: divider, options: .regularExpression) {
            let afterDivider = plain(String(backHTML[range.upperBound...]))
            if !afterDivider.isEmpty { return afterDivider }
        }
        let full = plain(backHTML)
        let front = plain(frontHTML)
        if !front.isEmpty, full.hasPrefix(front) {
            let rest = full.dropFirst(front.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty { return rest }
        }
        return full
    }

    /// `Parent::Child` to `Child`.
    static func leafName(_ fullName: String) -> String {
        fullName.components(separatedBy: "::").last ?? fullName
    }

    /// Cuts `text` so its UTF-8 size stays within `maxBytes`. Bytes, not
    /// characters, because ActivityKit's 4 KB limit is on the encoded state
    /// and a Japanese or Punjabi card spends three bytes per character.
    static func clip(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let ellipsis = "\u{2026}"
        let budget = maxBytes - ellipsis.utf8.count
        var clipped = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > budget { break }
            clipped.append(character)
            used += size
        }
        return clipped + ellipsis
    }

    static func plain(_ html: String) -> String {
        var text = html
        // Blocks whose contents are not card text.
        text = replace(text, #"(?is)<style\b[^>]*>.*?</style>"#, "")
        text = replace(text, #"(?is)<script\b[^>]*>.*?</script>"#, "")
        text = replace(text, #"(?s)<!--.*?-->"#, "")
        // Audio markers and type-in-the-answer placeholders.
        text = replace(text, #"(?i)\[sound:[^\]]*\]"#, "")
        text = replace(text, #"\[\[type:[^\]]*\]\]"#, "")
        // An image cannot be drawn here; say that one was there.
        text = replace(text, #"(?i)<img\b[^>]*>"#, " [image] ")
        // Tags that end a line.
        text = replace(text, #"(?i)<br\s*/?>"#, "\n")
        text = replace(text, #"(?i)<hr\b[^>]*>"#, "\n")
        text = replace(
            text,
            #"(?i)</(?:div|p|li|tr|h[1-6]|ul|ol|table|blockquote|section|article|dd|dt)\s*>"#,
            "\n"
        )
        text = replace(text, #"(?i)</t[dh]\s*>"#, "  ")
        // Everything else is markup.
        text = replace(text, #"<[^>]+>"#, "")
        text = decodeEntities(text)
        // Tidy the whitespace the tags left behind.
        text = replace(text, #"[ \t ]+"#, " ")
        text = replace(text, #" ?\n ?"#, "\n")
        text = replace(text, #"\n{2,}"#, "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    private static let namedEntities: [(name: String, value: String)] = [
        ("nbsp", " "), ("lt", "<"), ("gt", ">"), ("quot", "\""), ("apos", "'"),
        ("hellip", "\u{2026}"), ("mdash", "\u{2014}"), ("ndash", "\u{2013}"),
        ("lsquo", "\u{2018}"), ("rsquo", "\u{2019}"), ("ldquo", "\u{201C}"), ("rdquo", "\u{201D}"),
        ("rarr", "\u{2192}"), ("larr", "\u{2190}"), ("times", "\u{00D7}"), ("deg", "\u{00B0}"),
    ]

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var named = text
        for entity in namedEntities {
            named = named.replacingOccurrences(of: "&\(entity.name);", with: entity.value)
        }

        // Numeric references: &#8594; and &#x2192;
        var decoded = ""
        var rest = Substring(named)
        while let range = rest.range(of: #"&#[xX]?[0-9a-fA-F]{1,6};"#, options: .regularExpression) {
            decoded += rest[rest.startIndex..<range.lowerBound]
            let body = rest[range].dropFirst(2).dropLast()
            let isHex = body.first == "x" || body.first == "X"
            let value = isHex ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
            if let value, value >= 0x20, let scalar = Unicode.Scalar(value) {
                decoded.unicodeScalars.append(scalar)
            } else {
                decoded += rest[range]
            }
            rest = rest[range.upperBound...]
        }
        decoded += rest
        // Ampersand last, so a decoded entity cannot be decoded twice.
        return decoded.replacingOccurrences(of: "&amp;", with: "&")
    }
}
#endif
