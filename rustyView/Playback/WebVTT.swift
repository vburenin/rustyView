import Foundation

struct SubtitleCue: Hashable, Sendable {
    let start: Double
    let end: Double
    let text: String
    func contains(_ time: Double) -> Bool { start <= time && time < end }
}

enum WebVTTParser {
    static func parse(_ data: Data, allowEmpty: Bool = false) throws -> [SubtitleCue] {
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
        // A window with no dialogue is a successful load. Only a header/NOTE
        // document qualifies; malformed timing still cannot become active.
        let emptyDocument = blocks.dropFirst().allSatisfy {
            let block = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return block.isEmpty || block == "NOTE" || block.hasPrefix("NOTE ") || block.hasPrefix("NOTE\n")
        }
        guard !cues.isEmpty || (allowEmpty && emptyDocument) else { throw SubtitleError.invalidFormat }
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

/// One online selection owns its connection and a bounded set of movie-time
/// windows. Complete offline captions continue to use the ordinary URL.
@MainActor
final class StreamingSubtitleSession {
    static let windowSeconds = 120
    let path: String
    let client: RustyDLNAClient
    let selection: SubtitleSelection
    let index: Int
    var pendingStart: Int?
    var loadID = UUID()
    private var windows: [(start: Int, cues: [SubtitleCue])] = []
    private(set) var cues: [SubtitleCue] = []

    init(path: String, client: RustyDLNAClient, selection: SubtitleSelection, index: Int) {
        self.path = path; self.client = client; self.selection = selection; self.index = index
    }

    static func start(at time: Double) -> Int {
        guard time.isFinite else { return 0 }
        return Int(min(max(0, time), 2_592_000)) / windowSeconds * windowSeconds
    }

    func contains(_ start: Int) -> Bool { windows.contains { $0.start == start } }

    func insert(_ cues: [SubtitleCue], start: Int) {
        windows.removeAll { $0.start == start }
        windows.append((start, cues))
        if windows.count > 3 { windows.removeFirst(windows.count - 3) }
        var seen = Set<SubtitleCue>()
        self.cues = windows.sorted { $0.start < $1.start }.flatMap(\.cues)
            .filter { seen.insert($0).inserted }.sorted { $0.start < $1.start }
    }

    func request(start: Int) throws -> URLRequest {
        guard var components = URLComponents(string: path) else { throw SubtitleError.invalidFormat }
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "start" }
        query.append(URLQueryItem(name: "start", value: String(start)))
        components.queryItems = query
        guard let path = components.string else { throw SubtitleError.invalidFormat }
        var request = try client.authorizedRequest(serverPath: path)
        request.timeoutInterval = RustyDLNAClient.captionPreparationTimeout
        return request
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
