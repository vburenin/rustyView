import Foundation

struct PreparedPlaybackIdentity: Equatable, Sendable {
    let session: UInt64
    let generation: UInt64
}

/// One title opened by one viewer. Its client is an immutable credential
/// snapshot; downloads and other viewers have their own server sessions.
@MainActor
final class PreparedPlaybackSession {
    let client: RustyDLNAClient
    let mediaID: String
    private let sessionID = UInt64.random(in: 1...UInt64.max)
    private var generation: UInt64 = 0
    private(set) var activePath: String?
    private var heartbeat: Task<Void, Never>?
    private let heartbeatInterval: Duration

    init(client: RustyDLNAClient, mediaID: String, heartbeatInterval: Duration = .seconds(20)) throws {
        self.client = try client.ownedConnection()
        self.mediaID = mediaID
        self.heartbeatInterval = heartbeatInterval
    }

    func prepare(
        item: MediaItem,
        quality: String,
        audioIndex: Int?,
        startSeconds: Int,
        forceVideoTranscode: Bool
    ) -> String {
        cancelActive()
        generation += 1
        let path = client.compatiblePath(
            for: item,
            quality: quality,
            audioIndex: audioIndex,
            startSeconds: startSeconds,
            forceVideoTranscode: forceVideoTranscode,
            preparedIdentity: PreparedPlaybackIdentity(session: sessionID, generation: generation)
        )
        activePath = path
        let client = client
        let mediaID = mediaID
        let interval = heartbeatInterval
        heartbeat = Task {
            // Status renews the generation's two-minute lease even while
            // deliberately paused or reading entirely from AVPlayer's buffer.
            // Requests are serial, finite-timeout, and never change playback
            // merely because an optional status response failed.
            while !Task.isCancelled {
                _ = try? await client.transcodeStatus(mediaID: mediaID, compatiblePath: path)
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
        return path
    }

    func cancelActive() {
        heartbeat?.cancel()
        heartbeat = nil
        guard let path = activePath else { return }
        activePath = nil
        Self.cancel(path: path, mediaID: mediaID, client: client)
    }

    private nonisolated static func cancel(path: String, mediaID: String, client: RustyDLNAClient) {
        // Retain the old credential snapshot until cleanup finishes. DELETE
        // must be sent even before the media GET: the server records a tombstone
        // so a delayed abandoned GET cannot recreate this producer.
        Task {
            for attempt in 0..<3 {
                do {
                    _ = try await client.cancelTranscode(mediaID: mediaID, compatiblePath: path)
                    return
                } catch RustyDLNAError.authenticationFailed { return }
                catch RustyDLNAError.http(let status, _, _) where (400..<500).contains(status) && status != 408 && status != 429 { return }
                catch {
                    guard attempt < 2 else { return }
                    try? await Task.sleep(for: .seconds(attempt == 0 ? 1 : 3))
                }
            }
        }
    }

    deinit {
        heartbeat?.cancel()
        if let activePath { Self.cancel(path: activePath, mediaID: mediaID, client: client) }
    }
}
