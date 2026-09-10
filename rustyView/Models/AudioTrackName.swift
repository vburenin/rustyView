import Foundation

enum AudioTrackName {
    static func display(title: String?, language: String?, fallback: String) -> String {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let language = language?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        let knownLanguage = !language.isEmpty && language != "UND"
        if knownLanguage {
            return title.isEmpty || title.uppercased() == language ? language : "\(language) · \(title)"
        }
        return title.isEmpty ? fallback : title
    }
}
