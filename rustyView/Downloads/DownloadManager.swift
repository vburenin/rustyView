import Foundation

final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    weak var owner: DownloadManager?
    let store: DownloadManifestStore
    private let lock = NSLock()
    private var currentConnection: ServerConnection?

    init(store: DownloadManifestStore) {
        self.store = store
    }

    func update(connection: ServerConnection?) {
        lock.lock()
        currentConnection = connection
        lock.unlock()
    }

    private func connection() -> ServerConnection? {
        lock.lock()
        defer { lock.unlock() }
        return currentConnection
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = DownloadProgressValues.expectedByteCount(
            reported: totalBytesExpectedToWrite,
            response: downloadTask.response
        )
        let progress = expected.map { min(1, Double(totalBytesWritten) / Double($0)) } ?? 0
        Task { @MainActor [weak owner] in
            owner?.update(
                taskIdentifier: downloadTask.taskIdentifier,
                phase: .downloading(progress: progress, received: totalBytesWritten, expected: expected)
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let failure = DownloadResponseValidator.failure(for: downloadTask.response) {
            Task { @MainActor [weak owner] in
                owner?.handleFailure(
                    taskIdentifier: downloadTask.taskIdentifier,
                    message: failure,
                    retryable: DownloadResponseValidator.isRetryable(downloadTask.response)
                )
            }
            return
        }
        guard let description = downloadTask.taskDescription,
              let data = description.data(using: .utf8),
              let metadata = try? JSONDecoder().decode(DownloadTaskMetadata.self, from: data) else {
            Task { @MainActor [weak owner] in
                owner?.handleFailure(
                    taskIdentifier: downloadTask.taskIdentifier,
                    message: "The completed download had invalid metadata.",
                    retryable: false
                )
            }
            return
        }
        Task { @MainActor [weak owner] in
            owner?.update(taskIdentifier: downloadTask.taskIdentifier, phase: .finishing)
        }
        do {
            let record = try store.install(temporaryURL: location, metadata: metadata)
            Task { @MainActor [weak owner] in
                owner?.finish(taskIdentifier: downloadTask.taskIdentifier, record: record)
            }
        } catch {
            Task { @MainActor [weak owner] in
                owner?.handleFailure(
                    taskIdentifier: downloadTask.taskIdentifier,
                    message: error.localizedDescription,
                    retryable: false
                )
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in BackgroundSessionEvents.shared.finish() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor [weak owner] in
            owner?.handleFailure(
                taskIdentifier: task.taskIdentifier,
                message: error.localizedDescription,
                retryable: DownloadRetryPolicy.isRetryable(error)
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let connection = connection() else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let method = challenge.protectionSpace.authenticationMethod
        let challengeURL = URL(
            string: "\(challenge.protectionSpace.protocol ?? "https")://\(challenge.protectionSpace.host):\(challenge.protectionSpace.port)"
        )
        guard (method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest),
              challenge.previousFailureCount == 0,
              let challengeURL,
              connection.origin.matches(challengeURL) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(
            .useCredential,
            URLCredential(user: connection.username, password: connection.password, persistence: .forSession)
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let connection = connection(), let url = request.url, connection.origin.matches(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var active: [ActiveDownload] = []
    @Published private(set) var completed: [DownloadRecord] = []
    @Published private(set) var preparationProgress: [UUID: DownloadPreparationProgress] = [:]
    @Published var errorMessage: String?

    private let store: DownloadManifestStore
    private let delegate: DownloadSessionDelegate
    private let sessionIdentifier: String
    private var connection: ServerConnection?
    private weak var statusClient: RustyDLNAClient?
    private var progressPollers: [UUID: Task<Void, Never>] = [:]
    private var allowsCellularDownloads: Bool
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()

    init(
        store: DownloadManifestStore = DownloadManifestStore(),
        allowsCellularDownloads: Bool = true,
        sessionIdentifier: String? = nil
    ) {
        self.store = store
        self.allowsCellularDownloads = allowsCellularDownloads
        self.sessionIdentifier = sessionIdentifier
            ?? "\(Bundle.main.bundleIdentifier ?? "com.example.rustyView").downloads"
        delegate = DownloadSessionDelegate(store: store)
        delegate.owner = self
        do {
            completed = try store.loadValidated().records.sorted { $0.completedAt > $1.completedAt }
        } catch {
            completed = []
            errorMessage = error.localizedDescription
        }
    }

    func configure(connection: ServerConnection?, statusClient: RustyDLNAClient? = nil) {
        self.connection = connection
        self.statusClient = statusClient
        delegate.update(connection: connection)
        guard connection != nil else {
            stopAllProgressTracking()
            return
        }
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor in self?.restore(tasks: tasks) }
        }
    }

    func start(
        item: MediaItem,
        kind: DownloadKind,
        client: RustyDLNAClient,
        quality: String = "auto",
        qualityProfile: QualityProfile? = nil,
        audioIndex: Int? = nil
    ) throws {
        guard let connection else { throw RustyDLNAError.notConfigured }
        statusClient = client
        let origin = connection.baseURL.absoluteString
        guard !active.contains(where: { $0.serverOrigin == origin && $0.mediaID == item.id }),
              !completed.contains(where: { $0.serverOrigin == origin && $0.mediaID == item.id }) else {
            return
        }
        let serverPath: String
        let fileExtension: String
        switch kind {
        case .original:
            guard let path = item.downloadURL else {
                throw RustyDLNAError.http(status: 404, message: "This title cannot be downloaded.", code: nil)
            }
            serverPath = path
            fileExtension = item.ext
        case .compatible:
            serverPath = client.compatiblePath(
                for: item,
                delivery: "mp4",
                quality: quality,
                audioIndex: audioIndex
            )
            fileExtension = "mp4"
        }
        var request = try client.authorizedRequest(serverPath: serverPath)
        request.setValue("video/*, application/octet-stream", forHTTPHeaderField: "Accept")
        DownloadNetworkPolicy.apply(allowsCellularDownloads: allowsCellularDownloads, to: &request)
        let task = session.downloadTask(with: request)
        let selectedAudioIndex = audioIndex ?? item.defaultAudioIndex
        let selectedAudio = item.audioTracks.first { $0.index == selectedAudioIndex }
        let metadata = DownloadTaskMetadata(
            recordID: UUID(),
            serverOrigin: origin,
            mediaID: item.id,
            title: item.title,
            kind: kind,
            fileExtension: fileExtension,
            durationSeconds: item.durationSeconds,
            resolution: item.resolution,
            serverPath: serverPath,
            retryAttempt: 0,
            qualityID: kind == .compatible ? quality : nil,
            qualityLabel: kind == .compatible
                ? qualityProfile?.label ?? (quality == "auto" ? "Auto" : quality)
                : nil,
            audioTrackIndex: kind == .compatible ? selectedAudioIndex : nil,
            audioTrackLabel: kind == .compatible
                ? selectedAudio?.selectionLabel(defaultIndex: item.defaultAudioIndex)
                : nil
        )
        try configure(task, metadata: metadata)
        active.append(
            ActiveDownload(
                id: metadata.recordID,
                serverOrigin: metadata.serverOrigin,
                mediaID: item.id,
                title: item.title,
                kind: kind,
                phase: .queued,
                taskIdentifier: task.taskIdentifier,
                metadata: metadata
            )
        )
        task.resume()
        if let download = active.last { startProgressTracking(for: download) }
    }

    func cancel(_ download: ActiveDownload) {
        let identifier = download.taskIdentifier
        let compatiblePath = download.kind == .compatible ? download.metadata.serverPath : nil
        let client = statusClient
        active.removeAll { $0.id == download.id }
        stopProgressTracking(for: download.id)
        session.getAllTasks { tasks in
            tasks.first { $0.taskIdentifier == identifier }?.cancel()
        }
        if let compatiblePath, let client {
            Task {
                // Cancelling the transfer does not necessarily stop a server-side
                // producer immediately. Release this exact generation explicitly.
                try? await client.cancelTranscode(
                    mediaID: download.mediaID,
                    compatiblePath: compatiblePath
                )
            }
        }
    }

    func retry(_ download: ActiveDownload) {
        guard let index = active.firstIndex(where: { $0.id == download.id }) else { return }
        do {
            let task = try makeTask(metadata: active[index].metadata, scheduledAt: nil)
            active[index].taskIdentifier = task.taskIdentifier
            active[index].phase = .queued
            task.resume()
        } catch {
            active[index].phase = .failed(message: error.localizedDescription)
        }
    }

    func setAllowsCellularDownloads(_ allowed: Bool) {
        guard allowed != allowsCellularDownloads else { return }
        allowsCellularDownloads = allowed
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                for task in tasks {
                    guard let index = self.active.firstIndex(where: { $0.taskIdentifier == task.taskIdentifier }) else {
                        continue
                    }
                    let metadata = self.active[index].metadata
                    task.cancel()
                    do {
                        let replacement = try self.makeTask(metadata: metadata, scheduledAt: nil)
                        self.active[index].taskIdentifier = replacement.taskIdentifier
                        self.active[index].phase = .queued
                        replacement.resume()
                    } catch {
                        self.active[index].phase = .failed(message: error.localizedDescription)
                    }
                }
            }
        }
    }

    func delete(_ record: DownloadRecord) {
        do {
            try store.delete(record)
            completed.removeAll { $0.id == record.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func localURL(for record: DownloadRecord) -> URL {
        store.localURL(for: record)
    }

    func record(for mediaID: String) -> DownloadRecord? {
        guard let connection else { return nil }
        return completed.first {
            $0.serverOrigin == connection.baseURL.absoluteString && $0.mediaID == mediaID
        }
    }

    func activeDownload(for mediaID: String) -> ActiveDownload? {
        guard let connection else { return nil }
        return active.first {
            $0.serverOrigin == connection.baseURL.absoluteString && $0.mediaID == mediaID
        }
    }

    func preparationProgress(for download: ActiveDownload) -> DownloadPreparationProgress? {
        preparationProgress[download.id]
    }

    func update(taskIdentifier: Int, phase: DownloadPhase) {
        guard let index = active.firstIndex(where: { $0.taskIdentifier == taskIdentifier }) else { return }
        active[index].phase = phase
    }

    func handleFailure(taskIdentifier: Int, message: String, retryable: Bool) {
        guard let index = active.firstIndex(where: { $0.taskIdentifier == taskIdentifier }) else { return }
        guard retryable else {
            active[index].phase = .failed(message: message)
            stopProgressTracking(for: active[index].id)
            return
        }

        var metadata = active[index].metadata
        let attempt = (metadata.retryAttempt ?? 0) + 1
        metadata.retryAttempt = attempt
        let delay = DownloadRetryPolicy.delay(forAttempt: attempt)
        let scheduledAt = Date().addingTimeInterval(delay)
        do {
            let task = try makeTask(metadata: metadata, scheduledAt: delay > 0 ? scheduledAt : nil)
            active[index].metadata = metadata
            active[index].taskIdentifier = task.taskIdentifier
            active[index].phase = .retrying(attempt: attempt, scheduledAt: scheduledAt, reason: message)
            task.resume()
        } catch {
            active[index].phase = .failed(message: error.localizedDescription)
        }
    }

    func finish(taskIdentifier: Int, record: DownloadRecord) {
        if let id = active.first(where: { $0.taskIdentifier == taskIdentifier })?.id {
            stopProgressTracking(for: id)
        }
        active.removeAll { $0.taskIdentifier == taskIdentifier }
        completed.removeAll { $0.serverOrigin == record.serverOrigin && $0.mediaID == record.mediaID }
        completed.insert(record, at: 0)
    }

    func dismissFailure(_ download: ActiveDownload) {
        active.removeAll { $0.id == download.id }
        stopProgressTracking(for: download.id)
    }

    func restore(tasks: [URLSessionTask]) {
        var claimed = Set(completed.map { DownloadIdentity(serverOrigin: $0.serverOrigin, mediaID: $0.mediaID) })
        claimed.formUnion(active.map { DownloadIdentity(serverOrigin: $0.serverOrigin, mediaID: $0.mediaID) })

        for task in tasks {
            if active.contains(where: { $0.taskIdentifier == task.taskIdentifier }) { continue }
            guard let description = task.taskDescription,
                  let data = description.data(using: .utf8),
                  let metadata = try? JSONDecoder().decode(DownloadTaskMetadata.self, from: data) else {
                continue
            }
            let identity = DownloadIdentity(serverOrigin: metadata.serverOrigin, mediaID: metadata.mediaID)
            guard claimed.insert(identity).inserted else {
                task.cancel()
                continue
            }
            let expected = task.countOfBytesExpectedToReceive > 0 ? task.countOfBytesExpectedToReceive : nil
            let progress = expected.map {
                min(1, Double(task.countOfBytesReceived) / Double($0))
            } ?? 0
            let phase: DownloadPhase
            if let scheduledAt = task.earliestBeginDate,
               scheduledAt > Date(),
               let attempt = metadata.retryAttempt,
               attempt > 0 {
                phase = .retrying(
                    attempt: attempt,
                    scheduledAt: scheduledAt,
                    reason: "The previous attempt was interrupted."
                )
            } else if task.state == .suspended {
                phase = .queued
            } else {
                phase = .downloading(
                    progress: progress,
                    received: task.countOfBytesReceived,
                    expected: expected
                )
            }
            active.append(
                ActiveDownload(
                    id: metadata.recordID,
                    serverOrigin: metadata.serverOrigin,
                    mediaID: metadata.mediaID,
                    title: metadata.title,
                    kind: metadata.kind,
                    phase: phase,
                    taskIdentifier: task.taskIdentifier,
                    metadata: metadataWithServerPath(metadata, task: task)
                )
            )
            if let download = active.last { startProgressTracking(for: download) }
        }
    }

    private func startProgressTracking(for download: ActiveDownload) {
        guard download.kind == .compatible,
              download.metadata.durationSeconds.map({ $0 > 0 }) == true,
              download.metadata.serverPath != nil,
              let client = statusClient else {
            return
        }
        progressPollers[download.id]?.cancel()
        progressPollers[download.id] = Task { [weak self, weak client] in
            while !Task.isCancelled {
                guard let client,
                      let current = self?.active.first(where: { $0.id == download.id }),
                      let serverPath = current.metadata.serverPath else {
                    return
                }
                do {
                    let status = try await client.transcodeStatus(
                        mediaID: current.mediaID,
                        compatiblePath: serverPath
                    )
                    if let produced = status.producedSeconds,
                       let progress = DownloadPreparationProgress(
                           producedSeconds: produced,
                           durationSeconds: current.metadata.durationSeconds
                       ) {
                        self?.preparationProgress[current.id] = progress
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // Older servers omit this optional progress signal. The
                    // background transfer and its byte progress remain valid.
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func stopProgressTracking(for id: UUID) {
        progressPollers.removeValue(forKey: id)?.cancel()
        preparationProgress.removeValue(forKey: id)
    }

    private func stopAllProgressTracking() {
        for poller in progressPollers.values { poller.cancel() }
        progressPollers.removeAll()
        preparationProgress.removeAll()
    }

    private func makeTask(
        metadata originalMetadata: DownloadTaskMetadata,
        scheduledAt: Date?
    ) throws -> URLSessionDownloadTask {
        guard let serverPath = originalMetadata.serverPath else {
            throw RustyDLNAError.http(
                status: 0,
                message: "This older queued download cannot be retried automatically. Start it again from the movie page.",
                code: nil
            )
        }
        var metadata = originalMetadata
        metadata.serverPath = serverPath
        var request = try request(serverPath: serverPath, serverOrigin: metadata.serverOrigin)
        DownloadNetworkPolicy.apply(allowsCellularDownloads: allowsCellularDownloads, to: &request)
        let task = session.downloadTask(with: request)
        task.earliestBeginDate = scheduledAt
        try configure(task, metadata: metadata)
        return task
    }

    private func request(serverPath: String, serverOrigin: String) throws -> URLRequest {
        guard let connection, connection.baseURL.absoluteString == serverOrigin else {
            throw RustyDLNAError.notConfigured
        }
        let url = try connection.resolve(serverPath: serverPath)
        var request = URLRequest(url: url)
        request.setValue("video/*, application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(connection.authorizationHeader(), forHTTPHeaderField: "Authorization")
        return request
    }

    private func configure(_ task: URLSessionTask, metadata: DownloadTaskMetadata) throws {
        guard let description = String(data: try JSONEncoder().encode(metadata), encoding: .utf8) else {
            throw RustyDLNAError.invalidResponse
        }
        task.taskDescription = description
    }

    private func metadataWithServerPath(
        _ originalMetadata: DownloadTaskMetadata,
        task: URLSessionTask
    ) -> DownloadTaskMetadata {
        guard originalMetadata.serverPath == nil,
              let url = task.originalRequest?.url,
              let connection,
              connection.origin.matches(url) else {
            return originalMetadata
        }
        var metadata = originalMetadata
        metadata.serverPath = url.path + (url.query.map { "?\($0)" } ?? "")
        return metadata
    }
}

private struct DownloadIdentity: Hashable {
    let serverOrigin: String
    let mediaID: String
}
