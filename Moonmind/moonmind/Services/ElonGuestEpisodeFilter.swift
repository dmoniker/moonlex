import Foundation

/// Shared rules: episode metadata indicates **Elon Musk is the interview guest**, not a passing mention.
enum ElonGuestEpisodeFilter {
    static func passes(_ episode: Episode) -> Bool {
        let title = episode.title.lowercased()
        let desc = episode.descriptionPlain.lowercased()
        let show = episode.showTitle.lowercased()
        let hay = title + " " + desc + " " + show

        let strongElon = hay.contains("elon musk") || (hay.contains("elon") && hay.contains("musk"))
        if haystackBlacklist.contains(where: { hay.contains($0) }), !strongElon {
            return false
        }
        guard strongElon else { return false }

        if peopleByWTFShouldExcludeNonEnglishOrTrailer(title: title, description: desc, show: show) {
            return false
        }

        if titleElonMentionNotGuestPatterns.contains(where: { title.contains($0) }) {
            return false
        }

        if let guestHeadline = primaryGuestHeadlineFromNumberedEpisodeTitle(episode.title) {
            let trimmed = guestHeadline.trimmingCharacters(in: .whitespacesAndNewlines)
            if !headlineNamesElonMusk(trimmed) {
                let tokenCount = trimmed.split { $0.isWhitespace }.filter { !$0.isEmpty }.count
                if tokenCount >= 2 {
                    return false
                }
            }
        }

        if titleIndicatesElonIsInterviewGuest(title) { return true }

        let descOpening = String(desc.prefix(1_600))
        if descriptionOpeningIndicatesElonIsGuest(descOpening) { return true }

        return false
    }

    // MARK: - Private

    private static let haystackBlacklist: [String] = [
        "ufo", "uap", "missing persons", "sonic mysteries", "nightwatcher",
        "cmo journeys", "49th parallel", "metamuse",
    ]

    /// People by WTF publishes the same Elon interview in other languages and a short trailer; keep only the main English episode.
    private static func peopleByWTFShouldExcludeNonEnglishOrTrailer(
        title: String,
        description: String,
        show: String
    ) -> Bool {
        guard show.contains("people by wtf") else { return false }
        if title.contains("trailer") { return true }
        if titleContainsDevanagari(title) { return true }

        let descHead = String(description.prefix(500))
        let blob = title + " " + descHead
        return peopleByWTFNonEnglishMarkers.contains { blob.contains($0) }
    }

    /// Hindi (and related) releases often use Devanagari in the title while the English episode stays Latin-only.
    private static func titleContainsDevanagari(_ title: String) -> Bool {
        title.unicodeScalars.contains { (0x0900 ... 0x097F).contains($0.value) }
    }

    private static let peopleByWTFNonEnglishMarkers: [String] = [
        "(hindi", "hindi)", "[hindi]", " hindi ", " hindi:", "(हिंदी", "हिंदी)",
        "hindi audio", "hindi version", "in hindi", "hindi dub", "dubbed in hindi",
        "telugu", "tamil", "kannada", "malayalam", "marathi", "gujarati", "bengali", "punjabi", "urdu",
        "(spanish", "español", " spanish ", "french version", "german version",
    ]

    private static let titleElonMentionNotGuestPatterns: [String] = [
        " reacts to ", " react to ", " reaction to ",
        " responds to ", " response to ",
        " breaks down ", " explains ",
        " deep dive on elon", " deepfake",
        "excerpt", "clip:", " clips:", "highlights",
        "according to elon", "elon says", "elon tweeted", "elon's tweet",
    ]

    private static func titleIndicatesElonIsInterviewGuest(_ title: String) -> Bool {
        let hasFullName = title.contains("elon musk")
        let hasSplitName = title.contains("elon") && title.contains("musk")
        guard hasFullName || hasSplitName else { return false }

        let guestPhrases = [
            "with elon musk", "w/ elon musk", " w elon musk", "w elon musk,",
            "featuring elon musk", "feat. elon musk", "feat elon musk",
            "guest elon musk", "guest: elon musk",
            "interview with elon musk", "interview w/ elon musk",
            "elon musk interview", "elon musk joins", "elon musk returns",
        ]
        if guestPhrases.contains(where: { title.contains($0) }) { return true }

        if title.trimmingCharacters(in: .whitespaces).hasPrefix("elon musk") { return true }

        if title.range(of: #":\s*elon musk"#, options: .regularExpression) != nil { return true }

        if title.contains(" - elon musk") || title.hasSuffix("elon musk") { return true }
        if title.contains("— elon musk") || title.contains("– elon musk") { return true }

        if title.contains("| elon musk |") || title.contains("| elon musk,") { return true }

        return false
    }

    private static func primaryGuestHeadlineFromNumberedEpisodeTitle(_ rawTitle: String) -> String? {
        let t = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hashRange = t.range(of: #"#\d+"#, options: .regularExpression) else { return nil }
        var idx = hashRange.upperBound
        while idx < t.endIndex, t[idx].isWhitespace { idx = t.index(after: idx) }
        guard idx < t.endIndex else { return nil }
        let dashChars: Set<Character> = ["–", "-", "—"]
        guard dashChars.contains(t[idx]) else { return nil }
        idx = t.index(after: idx)
        while idx < t.endIndex, t[idx].isWhitespace { idx = t.index(after: idx) }
        guard idx < t.endIndex else { return nil }
        let rest = t[idx...]
        let guestPart: Substring
        if let colon = rest.firstIndex(of: ":") {
            guestPart = rest[..<colon]
        } else {
            guestPart = rest[...]
        }
        let trimmed = guestPart.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func headlineNamesElonMusk(_ headline: String) -> Bool {
        let h = headline.lowercased()
        if h.contains("elon musk") { return true }
        if h == "elon" { return true }
        return false
    }

    private static func descriptionOpeningIndicatesElonIsGuest(_ prefix: String) -> Bool {
        let hasFullName = prefix.contains("elon musk")
        let hasSplitName = prefix.contains("elon") && prefix.contains("musk")
        guard hasFullName || hasSplitName else { return false }

        let signals = [
            "elon musk joins", "elon musk sits", "elon musk returns",
            "welcome elon musk", "welcomes elon musk",
            "joined by elon musk", "joining me is elon musk", "joining us is elon musk",
            "my guest elon musk", "our guest elon musk", "guest today, elon musk", "guest is elon musk",
            "interview with elon musk", "sit down with elon musk", "sits down with elon musk",
            "i talk with elon musk", "i speak with elon musk", "speaks with elon musk",
            "conversation with elon musk", "talked to elon musk", "talk with elon musk",
            "here with elon musk", "elon musk is here", "today we have elon musk", "present elon musk",
        ]
        return signals.contains { prefix.contains($0) }
    }
}
