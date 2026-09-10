import os

/// Instruments markers contain phase names only: never URLs, accounts, movie
/// metadata, task descriptions, or credentials. They do not upload telemetry.
enum DownloadPerformanceTrace {
    private static let log = OSLog(subsystem: "rustyView", category: .pointsOfInterest)

    static func begin(_ phase: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: phase, signpostID: id)
        return id
    }

    static func end(_ phase: StaticString, _ id: OSSignpostID) {
        os_signpost(.end, log: log, name: phase, signpostID: id)
    }

    static func event(_ phase: StaticString) {
        os_signpost(.event, log: log, name: phase)
    }
}
