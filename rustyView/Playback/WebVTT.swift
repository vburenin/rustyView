import Foundation

struct SubtitleCue: Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String

    func contains(_ time: Double) -> Bool { start <= time && time < end }
}

enum WebVTTParser {
    static func parse(_ data: Data) throws -> [SubtitleCue] {
        guard var text = String(data: data, encoding: .utf8) else {
            throw SubtitleError.invalidEncoding
        }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard text.hasPrefix("WEBVTT") else { throw SubtitleError.invalidFormat }
        let blocks = text.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []
        for block in blocks.dropFirst() {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard !lines.isEmpty, !lines[0].hasPrefix("NOTE") else { continue }
            let timingIndex = lines.firstIndex(where: { $0.contains("-->") })
            guard let timingIndex else { continue }
            let sides = lines[timingIndex].components(separatedBy: "-->")
            guard sides.count == 2,
                  let start = timestamp(sides[0]),
                  let end = timestamp(sides[1].split(separator: " ").first.map(String.init) ?? ""),
                  end > start else { continue }
            let cueText = lines.dropFirst(timingIndex + 1)
                .joined(separator: "\n")
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cueText.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: cueText)) }
        }
        guard !cues.isEmpty else { throw SubtitleError.invalidFormat }
        return cues.sorted { $0.start < $1.start }
    }

    private static func timestamp(_ raw: String) -> Double? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let seconds = Double(parts.last ?? "")
        let minutes = Double(parts[parts.count - 2])
        let hours = parts.count == 3 ? Double(parts[0]) : 0
        guard let seconds, let minutes, let hours, minutes < 60, seconds < 60 else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}

enum SubtitleError: LocalizedError {
    case invalidEncoding
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .invalidEncoding: "The subtitle file uses an unsupported text encoding."
        case .invalidFormat: "The subtitle file is not valid WebVTT."
        }
    }
}
