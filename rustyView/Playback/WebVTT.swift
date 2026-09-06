import Foundation

struct SubtitleCue: Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String
    func contains(_ time: Double) -> Bool { start <= time && time < end }
}

enum WebVTTParser {
    static func parse(_ data: Data) throws -> [SubtitleCue] {
        guard var text = String(data: data, encoding: .utf8) else { throw SubtitleError.invalidEncoding }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first,
              firstLine == "WEBVTT" || firstLine.hasPrefix("WEBVTT ") || firstLine.hasPrefix("WEBVTT\t") else {
            throw SubtitleError.invalidFormat
        }
        let blocks = text.components(separatedBy: "\n\n")
        var cues: [(order: Int, cue: SubtitleCue)] = []
        for (order, block) in blocks.dropFirst().enumerated() {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let first = lines.first, !first.hasPrefix("NOTE"), first != "STYLE", first != "REGION" else { continue }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let sides = lines[timingIndex].components(separatedBy: "-->")
            guard sides.count == 2, let start = timestamp(sides[0]),
                  let end = timestamp(sides[1].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""),
                  end > start else { continue }
            // Remove actual markup before decoding escaped angle brackets. A
            // literal &lt;b&gt; must remain visible as <b>, not become markup.
            let unstyled = lines.dropFirst(timingIndex + 1).joined(separator: "\n")
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            let cueText = decodeReferences(unstyled).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cueText.isEmpty { cues.append((order, SubtitleCue(start: start, end: end, text: cueText))) }
        }
        guard !cues.isEmpty else { throw SubtitleError.invalidFormat }
        return cues.sorted { $0.cue.start == $1.cue.start ? $0.order < $1.order : $0.cue.start < $1.cue.start }.map(\.cue)
    }

    private static func timestamp(_ raw: String) -> Double? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let last = parts.last, let seconds = Double(last),
              let minutes = UInt64(parts[parts.count - 2]),
              let hours = parts.count == 3 ? UInt64(parts[0]) : 0,
              seconds.isFinite, seconds >= 0, seconds < 60, minutes < 60 else { return nil }
        let result = Double(hours) * 3600 + Double(minutes) * 60 + seconds
        return result.isFinite ? result : nil
    }

    private static func decodeReferences(_ text: String) -> String {
        let named: [Substring: String] = ["amp": "&", "lt": "<", "gt": ">", "nbsp": "\u{00a0}", "lrm": "\u{200e}", "rlm": "\u{200f}"]
        var output = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard text[cursor] == "&" else { output.append(text[cursor]); cursor = text.index(after: cursor); continue }
            let start = text.index(after: cursor)
            let bound = text.index(start, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
            guard let semicolon = text[start..<bound].firstIndex(of: ";") else {
                output.append("&"); cursor = start; continue
            }
            let reference = text[start..<semicolon]
            var decoded = named[reference]
            if decoded == nil, reference.hasPrefix("#") {
                let numeric = reference.dropFirst()
                let hexadecimal = numeric.hasPrefix("x") || numeric.hasPrefix("X")
                if let value = UInt32(hexadecimal ? numeric.dropFirst() : numeric, radix: hexadecimal ? 16 : 10),
                   value != 0, let scalar = UnicodeScalar(value) { decoded = String(scalar) }
            }
            if let decoded { output += decoded; cursor = text.index(after: semicolon) }
            else { output.append("&"); cursor = start }
        }
        return output
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
