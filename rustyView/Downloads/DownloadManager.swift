import Foundation
import Network

final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    weak var owner: DownloadManager?
    let store: DownloadManifestStore
    private let queueStore: DownloadQueueStore?
    private let coordinator: DownloadStorageCoordinator?
    private let processing = DispatchGroup()
    private let lock = NSLock()
    private var currentConnection: ServerConnection?
    private var discardedTasks: Set<Int> = []
    private var discardedRecords: Set<UUID> = []
    private var discardedAttempts: Set<DownloadAttemptIdentity> = []
    private var installedRecords: [Int: DownloadRecord] = [:]
    private var installedMetadata: [Int: DownloadTaskMetadata] = [:]
    private var progressEnvelopes: [ObjectIdentifier: (String?, DownloadTaskEnvelope)] = [:]
    let progressDelivery = DownloadProgressDelivery()

    init(store: DownloadManifestStore, queueStore: DownloadQueueStore? = nil,
         coordinator: DownloadStorageCoordinator? = nil) {
        self.store = store
        self.queueStore = queueStore
        self.coordinator = coordinator
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

    func discard(taskIdentifier: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        if let record = installedRecords[taskIdentifier] {
            try store.delete(record)
            installedRecords.removeValue(forKey: taskIdentifier)
            installedMetadata.removeValue(forKey: taskIdentifier)
        }
        discardedTasks.insert(taskIdentifier)
    }

    func discard(recordID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        for (identifier, record) in installedRecords where record.id == recordID {
            try store.delete(record)
            installedRecords.removeValue(forKey: identifier)
            installedMetadata.removeValue(forKey: identifier)
        }
        discardedRecords.insert(recordID)
    }

    func discard(metadata: DownloadTaskMetadata) throws {
        lock.lock()
        defer { lock.unlock() }
        let attempt = DownloadAttemptIdentity(metadata)
        for (identifier, installed) in installedMetadata where DownloadAttemptIdentity(installed) == attempt {
            if let record = installedRecords[identifier] { try store.delete(record) }
            installedRecords.removeValue(forKey: identifier)
            installedMetadata.removeValue(forKey: identifier)
        }
        discardedAttempts.insert(attempt)
    }

    func install(temporaryURL: URL, metadata: DownloadTaskMetadata, taskIdentifier: Int,
                 expectedByteCount: Int64? = nil) throws -> DownloadRecord? {
        guard !isDiscarded(taskIdentifier: taskIdentifier, metadata: metadata),
              try queueStore?.permitsInstallation(metadata: metadata) != false else { return nil }
        let inspection = try store.inspectDownload(temporaryURL: temporaryURL, metadata: metadata,
                                                   expectedByteCount: expectedByteCount)
        lock.lock()
        defer { lock.unlock() }
        guard !discardedTasks.contains(taskIdentifier),
              !discardedRecords.contains(metadata.recordID),
              !discardedAttempts.contains(DownloadAttemptIdentity(metadata)),
              try queueStore?.permitsInstallation(metadata: metadata) != false else { return nil }
        let alreadyInstalled = try store.loadValidated().records.contains { $0.id == metadata.recordID }
        let record = try store.install(temporaryURL: temporaryURL, metadata: metadata,
                                       expectedByteCount: expectedByteCount, inspection: inspection)
        // Idempotent duplicate delivery borrows the committed record; it does
        // not own that user's file for rollback if the duplicate is discarded.
        if !alreadyInstalled { installedRecords[taskIdentifier] = record }
        installedMetadata[taskIdentifier] = metadata
        return record
    }

    func acceptCompletion(taskIdentifier: Int, metadata: DownloadTaskMetadata? = nil, recordID: UUID? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let metadata, let current = installedMetadata[taskIdentifier],
           DownloadAttemptIdentity(metadata) != DownloadAttemptIdentity(current) {
            return false
        }
        let installed = installedMetadata.removeValue(forKey: taskIdentifier)
        let id = recordID ?? installedRecords[taskIdentifier]?.id
        installedRecords.removeValue(forKey: taskIdentifier)
        let attempt = (metadata ?? installed).map(DownloadAttemptIdentity.init)
        return !discardedTasks.contains(taskIdentifier)
            && id.map { !discardedRecords.contains($0) } != false
            && attempt.map { !discardedAttempts.contains($0) } != false
    }

    func isDiscarded(taskIdentifier: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return discardedTasks.contains(taskIdentifier)
    }

    private func isDiscarded(taskIdentifier: Int, metadata: DownloadTaskMetadata) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return discardedTasks.contains(taskIdentifier) || discardedRecords.contains(metadata.recordID)
            || discardedAttempts.contains(DownloadAttemptIdentity(metadata))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else { return }
        if coordinator != nil, let envelope = progressEnvelope(for: downloadTask) {
            if envelope.kind == .media, DownloadResponseValidator.failure(for: response) != nil { return }
            let expected = DownloadProgressValues.expectedByteCount(reported: totalBytesExpectedToWrite, response: response)
            if envelope.kind != .media {
                let limit = (envelope.kind == .artwork ? 20 : 5) * 1_024 * 1_024
                // Resource size enforcement is never delayed or disabled in
                // the background. Other sidecar progress has no visible row.
                if totalBytesWritten > limit {
                    Task { @MainActor [weak owner] in
                        owner?.resourceProgress(envelope, received: totalBytesWritten, expected: expected)
                    }
                }
            } else {
                progressDelivery.submit(.init(envelope: envelope, received: (envelope.byteOffset ?? 0) + totalBytesWritten, expected: expected)) { [weak owner] sample in
                    Task { @MainActor [weak owner] in
                        owner?.resourceProgress(sample.envelope, received: sample.received, expected: sample.expected)
                    }
                }
            }
            return
        }
        guard DownloadResponseValidator.failure(for: response) == nil else { return }
        let expected = DownloadProgressValues.expectedByteCount(
            reported: totalBytesExpectedToWrite,
            response: downloadTask.response
        )
        let progress = expected.map { min(1, Double(totalBytesWritten) / Double($0)) } ?? 0
        Task { @MainActor [weak owner] in
            owner?.update(
                taskIdentifier: downloadTask.taskIdentifier,
                phase: .downloading(progress: progress, received: totalBytesWritten, expected: expected),
                metadata: Self.metadata(for: downloadTask)
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        retireProgress(for: downloadTask)
        DownloadPerformanceTrace.event("Download File Received")
        if let coordinator {
            guard let envelope = DownloadTaskEnvelope.decode(downloadTask.taskDescription) else { downloadTask.cancel(); return }
            processing.enter()
            do {
                guard DownloadOriginPolicy.permits(downloadTask.response?.url, metadata: envelope.metadata) else {
                    throw RustyDLNAError.untrustedURL
                }
                if envelope.kind == .media, envelope.metadata.kind == .compatible,
                   let response = downloadTask.response as? HTTPURLResponse,
                   response.statusCode == 202,
                   response.value(forHTTPHeaderField: "X-RustyDLNA-Download") == "preparing" {
                    let delay = TimeInterval(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30
                    Task { @MainActor [weak owner, processing] in
                        await owner?.resourcePreparing(envelope, retryAfter: delay)
                        processing.leave()
                    }
                    return
                }
                if envelope.kind == .media, let response = downloadTask.response as? HTTPURLResponse,
                   response.statusCode == 416, response.value(forHTTPHeaderField: "X-RustyDLNA-Download") == "progressive",
                   let range = response.value(forHTTPHeaderField: "Content-Range"), range.hasPrefix("bytes */"),
                   let length = Int64(range.dropFirst(8)), let tag = response.value(forHTTPHeaderField: "ETag") {
                    Task { @MainActor [weak owner, processing] in
                        await owner?.resourceRangeComplete(envelope, length: length, entityTag: tag)
                        processing.leave()
                    }
                    return
                }
                if let failure = DownloadResponseValidator.failure(for: downloadTask.response), envelope.kind == .media {
                    completeFailure(envelope, message: failure,
                                    retryable: DownloadResponseValidator.isRetryable(downloadTask.response),
                                    failure: .downloadResponse(downloadTask.response))
                    return
                }
                guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                    completeFailure(envelope, message: "A download resource could not be retrieved.",
                                    retryable: DownloadResponseValidator.isRetryable(downloadTask.response),
                                    failure: .downloadResponse(downloadTask.response))
                    return
                }
                if envelope.kind == .media, response.value(forHTTPHeaderField: "X-RustyDLNA-Download") == "progressive" {
                    let range = try DownloadRangeReceipt(response: response, envelope: envelope)
                    let receipt = try coordinator.stageTemporaryFile(temporaryURL: location, metadata: envelope.metadata,
                        resourceID: envelope.resourceID, transferID: envelope.transferID, byteRange: range)
                    Task { @MainActor [weak owner, processing] in
                        await owner?.receive(receipt, envelope: envelope)
                        processing.leave()
                    }
                    return
                }
                guard (envelope.byteOffset ?? 0) == 0 else { throw DownloadStoreError.incompleteDownload }
                if response.statusCode == 206, DownloadHTTPRange.completeLength(of: response) == nil {
                    completeFailure(envelope, message: "The server is still preparing this file. This partial response cannot be used as a complete download.", retryable: true,
                                    failure: UserFacingError(category: .transient, message: "The server is still preparing this file. The download will retry when it is ready."))
                    return
                }
                let receipt = try coordinator.stageTemporaryFile(temporaryURL: location, metadata: envelope.metadata,
                                                                  resourceID: envelope.resourceID, transferID: envelope.transferID,
                                                                  expectedByteCount: DownloadHTTPRange.completeLength(of: response))
                Task { @MainActor [weak owner, processing] in
                    await owner?.receive(receipt, envelope: envelope)
                    processing.leave()
                }
            } catch {
                completeFailure(envelope, message: error.localizedDescription, retryable: false, failure: UserFacingError(error))
            }
            return
        }
        if let failure = DownloadResponseValidator.failure(for: downloadTask.response) {
            Task { @MainActor [weak owner] in
                owner?.handleFailure(
                    taskIdentifier: downloadTask.taskIdentifier,
                    message: failure,
                    retryable: DownloadResponseValidator.isRetryable(downloadTask.response),
                    metadata: Self.metadata(for: downloadTask)
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
            owner?.update(taskIdentifier: downloadTask.taskIdentifier, phase: .finishing, metadata: metadata)
        }
        do {
            guard let record = try install(temporaryURL: location, metadata: metadata,
                                           taskIdentifier: downloadTask.taskIdentifier,
                                           expectedByteCount: downloadTask.response?.expectedContentLength) else { return }
            Task { @MainActor [weak owner] in
                owner?.finish(taskIdentifier: downloadTask.taskIdentifier, record: record, metadata: metadata)
            }
        } catch {
            Task { @MainActor [weak owner] in
                owner?.handleFailure(
                    taskIdentifier: downloadTask.taskIdentifier,
                    message: error.localizedDescription,
                    retryable: false,
                    metadata: metadata
                )
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        processing.notify(queue: .main) { [weak owner] in
            Task { @MainActor in
                await owner?.waitForPendingOperations()
                BackgroundSessionEvents.shared.finish(identifier: identifier)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        retireProgress(for: task)
        guard let error else { return }
        if coordinator != nil, let envelope = DownloadTaskEnvelope.decode(task.taskDescription) {
            processing.enter()
            let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            let received = (envelope.byteOffset ?? 0) + task.countOfBytesReceived
            let expected = DownloadProgressValues.expectedByteCount(reported: task.countOfBytesExpectedToReceive, response: task.response)
            Task { @MainActor [weak owner, processing] in
                await owner?.resourceFailure(envelope, message: error.localizedDescription,
                                             retryable: DownloadRetryPolicy.isRetryable(error), resumeData: resumeData,
                                             received: received, expected: expected,
                                             cancelled: (error as NSError).code == NSURLErrorCancelled,
                                             cannotResume: [NSURLErrorUnknown, NSURLErrorBadURL, NSURLErrorUnsupportedURL,
                                                            NSURLErrorCannotOpenFile, NSURLErrorCannotWriteToFile,
                                                            NSURLErrorDownloadDecodingFailedToComplete]
                                                .contains((error as NSError).code), failure: UserFacingError(error))
                processing.leave()
            }
            return
        }
        Task { @MainActor [weak owner] in
            owner?.handleFailure(
                taskIdentifier: task.taskIdentifier,
                message: error.localizedDescription,
                retryable: DownloadRetryPolicy.isRetryable(error),
                metadata: Self.metadata(for: task)
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let metadata = Self.metadata(for: task),
              DownloadOriginPolicy.permits(challenge.protectionSpace, metadata: metadata) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            // Background redirects bypass the redirect delegate. A foreign
            // TLS origin must be rejected before an HTTP request can be sent.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let connection = connection(),
              DownloadOwnership.matches(metadata, connection: connection) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard let credential = ServerAuthenticationPolicy.credential(for: challenge, connection: connection) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(
            .useCredential,
            credential
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let connection = connection(), let metadata = Self.metadata(for: task),
              DownloadOwnership.matches(metadata, connection: connection),
              let url = request.url, connection.origin.matches(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    static func metadata(for task: URLSessionTask) -> DownloadTaskMetadata? {
        DownloadTaskEnvelope.decode(task.taskDescription)?.metadata
    }

    private func progressEnvelope(for task: URLSessionTask) -> DownloadTaskEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(task)
        if let cached = progressEnvelopes[key], cached.0 == task.taskDescription { return cached.1 }
        guard let envelope = DownloadTaskEnvelope.decode(task.taskDescription) else { return nil }
        progressEnvelopes[key] = (task.taskDescription, envelope)
        return envelope
    }

    private func retireProgress(for task: URLSessionTask) {
        lock.lock()
        let envelope = progressEnvelopes.removeValue(forKey: ObjectIdentifier(task))?.1
        lock.unlock()
        if let envelope { progressDelivery.remove(envelope.transferID) }
    }

    private func completeFailure(_ envelope: DownloadTaskEnvelope, message: String, retryable: Bool, failure: UserFacingError) {
        Task { @MainActor [weak owner, processing] in
            await owner?.resourceFailure(envelope, message: message, retryable: retryable, failure: failure)
            processing.leave()
        }
    }
}
