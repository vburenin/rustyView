import Foundation

enum DisplayTitle {
    private static let trailingTechnicalTag = try? NSRegularExpression(
        pattern: #"(?ix)(?:[\s._\-–—]*[\[(]?\s*(?:2160p|1080p|720p|576p|480p|4k|uhd|hdr10\+?|hdr|sdr|dolby\s*vision|dovi|dv|bdremux|blu[\s._-]?ray|bdrip|brrip|web[\s._-]?dl|webrip|remux|x26[45]|h[.\s_-]?26[45]|hevc|avc|av1|10[\s._-]?bit|8[\s._-]?bit|dts(?:[\s._-]?hd)?(?:[\s._-]?ma)?|true[\s._-]?hd|atmos|aac|ac[\s._-]?3|eac[\s._-]?3|ddp?\s*\d(?:\.\d)?|\d(?:\.\d)?[\s._-]?ch)\s*[\])]?)$"#,
        options: []
    )

    private static let trailingSeparators = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: ".-_–—")
    )

    private static let redundantEpisodeLabel = try? NSRegularExpression(
        pattern: #"(?i)\bS\d{1,3}E(\d{1,4})\s*(?:[-–—:]|\s)\s*Episode\s+(\d{1,4})\s*$"#,
        options: []
    )

    static func clean(_ rawTitle: String) -> String {
        let fallback = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trailingTechnicalTag else { return fallback }

        var result = fallback
        while !result.isEmpty {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            guard let match = trailingTechnicalTag.firstMatch(in: result, range: range),
                  let matchRange = Range(match.range, in: result) else {
                break
            }
            result.removeSubrange(matchRange)
            result = result.trimmingCharacters(in: trailingSeparators)
        }
        result = removingRedundantEpisodeLabel(from: result)
        return result.isEmpty ? fallback : result
    }

    private static func removingRedundantEpisodeLabel(from title: String) -> String {
        guard let redundantEpisodeLabel else { return title }
        let fullRange = NSRange(title.startIndex..<title.endIndex, in: title)
        guard let match = redundantEpisodeLabel.firstMatch(in: title, range: fullRange),
              match.numberOfRanges == 3,
              let episodeCodeRange = Range(match.range(at: 1), in: title),
              let episodeLabelRange = Range(match.range(at: 2), in: title),
              Int(title[episodeCodeRange]) == Int(title[episodeLabelRange]),
              let matchedRange = Range(match.range, in: title) else {
            return title
        }

        let matchedText = title[matchedRange]
        guard let separatorRange = matchedText.range(
            of: #"\s*(?:[-–—:]|\s)\s*Episode\s+\d{1,4}\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return title
        }
        var result = title
        let removalStart = separatorRange.lowerBound
        let absoluteStart = title.index(matchedRange.lowerBound, offsetBy: matchedText.distance(from: matchedText.startIndex, to: removalStart))
        result.removeSubrange(absoluteStart..<result.endIndex)
        return result.trimmingCharacters(in: trailingSeparators)
    }
}

extension LibraryEntry {
    var displayTitle: String { isFolder ? title : DisplayTitle.clean(title) }
}

extension MediaItem {
    var displayTitle: String { DisplayTitle.clean(title) }
}

extension DownloadRecord {
    var displayTitle: String { DisplayTitle.clean(title) }
}

extension ActiveDownload {
    var displayTitle: String { DisplayTitle.clean(title) }
}
