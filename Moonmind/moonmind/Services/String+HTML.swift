import Foundation
import UIKit

private enum PlainTextLinkDetection {
    static let detector: NSDataDetector? = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}

extension String {
    /// Minimal HTML → plain text for show notes (good enough for podcast RSS).
    var strippingHTML: String {
        var s = Self.removingScriptsAndStyles(from: self)
        s = Self.expandingAnchorsToPlainTextWithHrefs(s)
        let patterns: [(String, String)] = [
            ("<br\\s*/?>", "\n"),
            ("</p>", "\n\n"),
            ("</div>", "\n"),
            ("<[^>]+>", " "),
        ]
        for (pattern, repl) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: repl)
            }
        }
        return Self.normalizingPlainAfterHTMLStrip(s).insertingNewlinesBeforeBracketTimestamps()
    }

    /// Plain text for newsletter HTML: block structure, lists, fewer run-on paragraphs.
    var strippingHTMLNewsletter: String {
        var s = Self.removingScriptsAndStyles(from: self)
        s = Self.expandingAnchorsToPlainTextWithHrefs(s)
        let patterns: [(String, String)] = [
            ("(?s)<figure.*?</figure>", "\n"),
            ("(?s)<picture.*?</picture>", ""),
            ("(?s)<svg.*?</svg>", ""),
            ("<br\\s*/?>", "\n"),
            ("(?i)</p\\s*>", "\n\n"),
            ("(?i)<p(\\s[^>]*)?>", ""),
            ("(?i)</div\\s*>", "\n"),
            ("(?i)<h[1-6](\\s[^>]*)?>", "\n\n"),
            ("(?i)</h[1-6]\\s*>", "\n\n"),
            ("(?i)</li\\s*>", "\n"),
            ("(?i)<li(\\s[^>]*)?>", "\n• "),
            ("(?i)</blockquote\\s*>", "\n\n"),
            ("(?i)<blockquote(\\s[^>]*)?>", "\n"),
            ("(?i)<hr\\s*/?>", "\n\n—\n\n"),
            ("<[^>]+>", " "),
        ]
        for (pattern, repl) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: repl)
            }
        }
        return Self.normalizingPlainAfterHTMLStrip(Self.decodingNumericHTMLEntities(s))
            .insertingNewlinesBeforeBracketTimestamps()
    }

    /// Many podcast feeds pack chapter markers in one HTML block (`…segment.</a><a…>[00:02:12]…`), which
    /// becomes a single run-on paragraph after tag stripping. Break before `[H:MM:SS]`-style timestamps.
    func insertingNewlinesBeforeBracketTimestamps() -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(.)(\[(?:\d{1,2}):(?:\d{2}):(?:\d{2})\])"#,
            options: []
        ) else { return self }
        let range = NSRange(startIndex..., in: self)
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: "$1\n$2")
    }

    /// Detects `http`/`https` URLs etc. for plain-text show notes; link spans use `UIColor.link` and open on tap in `Text(AttributedString)`.
    func attributedPlainTextDetectingLinks() -> AttributedString {
        guard !isEmpty else { return AttributedString() }
        let mas = NSMutableAttributedString(string: self, attributes: [.foregroundColor: UIColor.label])
        guard let detector = PlainTextLinkDetection.detector else { return AttributedString(mas) }
        let full = NSRange(location: 0, length: (self as NSString).length)
        for match in detector.matches(in: self, options: [], range: full).reversed() {
            guard let url = match.url else { continue }
            mas.addAttributes(
                [
                    .link: url,
                    .foregroundColor: UIColor.link,
                ],
                range: match.range
            )
        }
        return AttributedString(mas)
    }

    /// Rich text for article bodies (Substack `content:encoded`, etc.), scaled for Dynamic Type.
    func attributedArticleFromHTML() -> NSAttributedString? {
        var body = Self.removingScriptsAndStyles(from: self)
        body = Self.strippingHeavyVisualHTML(from: body)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let wrapped = """
        <!DOCTYPE html>
        <html><head><meta charset=\"utf-8\"></head><body>\(trimmed)</body></html>
        """
        guard let data = wrapped.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let raw = try? NSMutableAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }
        Self.applySemanticTextColors(to: raw)
        Self.normalizeArticleFonts(raw)
        return raw
    }

    /// RSS show notes often use `<a href="https://…">X</a>`; stripping tags leaves "X" with no URL. Inline the
    /// `href` next to the anchor text (when the text isn’t already a URL) so `NSDataDetector` can make it tappable.
    private static func expandingAnchorsToPlainTextWithHrefs(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?is)<a[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#,
            options: []
        ) else { return html }
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: html, options: [], range: full)
        if matches.isEmpty { return html }
        var result = ""
        var lastEnd = 0
        for match in matches {
            let matchRange = match.range
            if matchRange.location > lastEnd {
                result += ns.substring(with: NSRange(location: lastEnd, length: matchRange.location - lastEnd))
            }
            let hrefRaw = decodeMinimalHTMLEntities(ns.substring(with: match.range(at: 1)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let inner = anchorFragmentToPlain(ns.substring(with: match.range(at: 2)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hrefVisible: String = {
                if hrefRaw.hasPrefix("//") { return "https:\(hrefRaw)" }
                return hrefRaw
            }()
            let merged: String
            if inner.isEmpty {
                merged = hrefVisible
            } else if inner.range(of: #"^(https?://|mailto:)"#, options: .regularExpression) != nil {
                merged = inner
            } else if inner.caseInsensitiveCompare(hrefVisible) == .orderedSame {
                merged = hrefVisible
            } else {
                merged = "\(inner) \(hrefVisible)"
            }
            result += merged
            lastEnd = matchRange.location + matchRange.length
        }
        if lastEnd < ns.length {
            result += ns.substring(from: lastEnd)
        }
        return result
    }

    private static func anchorFragmentToPlain(_ innerHTML: String) -> String {
        var s = innerHTML
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: [.caseInsensitive]) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return decodeMinimalHTMLEntities(s)
    }

    private static func decodeMinimalHTMLEntities(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func removingScriptsAndStyles(from html: String) -> String {
        var s = html
        let patterns = ["(?s)<script.*?</script>", "(?s)<style.*?</style>"]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            }
        }
        return s
    }

    /// Drops embedded figures and inline SVG so the HTML importer focuses on copy and links.
    private static func strippingHeavyVisualHTML(from html: String) -> String {
        var s = html
        let patterns = ["(?s)<figure.*?</figure>", "(?s)<picture.*?</picture>", "(?s)<svg.*?</svg>"]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\n")
            }
        }
        return s
    }

    private static func normalizingPlainAfterHTMLStrip(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodingNumericHTMLEntities(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);", options: []) else {
            return s
        }
        let range = NSRange(s.startIndex..., in: s)
        var result = ""
        var lastEnd = s.startIndex
        for match in regex.matches(in: s, range: range) {
            guard let fullRange = Range(match.range, in: s) else { continue }
            result += s[lastEnd ..< fullRange.lowerBound]
            guard match.numberOfRanges >= 3,
                  let hexRange = Range(match.range(at: 1), in: s),
                  let numRange = Range(match.range(at: 2), in: s)
            else {
                lastEnd = fullRange.upperBound
                continue
            }
            let isHex = !s[hexRange].isEmpty
            let digits = String(s[numRange])
            let codePoint: UInt32?
            if isHex {
                codePoint = UInt32(digits, radix: 16)
            } else {
                codePoint = UInt32(digits, radix: 10)
            }
            if let cp = codePoint, let scalar = UnicodeScalar(cp) {
                result.append(Character(scalar))
            }
            lastEnd = fullRange.upperBound
        }
        result += s[lastEnd...]
        return result
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func applySemanticTextColors(to attributed: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.foregroundColor, value: UIColor.label, range: full)
        attributed.enumerateAttribute(.link, in: full, options: [.longestEffectiveRangeNotRequired]) { value, range, _ in
            if value != nil {
                attributed.addAttribute(.foregroundColor, value: UIColor.link, range: range)
            }
        }
    }

    private static func normalizeArticleFonts(_ attributed: NSMutableAttributedString) {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let full = NSRange(location: 0, length: attributed.length)
        guard full.length > 0 else { return }

        attributed.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            guard let old = value as? UIFont else {
                attributed.addAttribute(.font, value: body, range: range)
                return
            }
            let traits = old.fontDescriptor.symbolicTraits
            var descriptor = body.fontDescriptor
            if traits.contains(.traitBold) {
                descriptor = descriptor.withSymbolicTraits(.traitBold) ?? descriptor
            }
            if traits.contains(.traitItalic) {
                let next = descriptor.symbolicTraits.union(.traitItalic)
                descriptor = descriptor.withSymbolicTraits(next) ?? descriptor
            }
            let font = UIFont(descriptor: descriptor, size: body.pointSize)
            attributed.addAttribute(.font, value: font, range: range)
        }
    }
}
