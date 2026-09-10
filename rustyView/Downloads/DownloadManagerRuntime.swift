import Foundation
import Network
import CryptoKit
import UIKit

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var active: [ActiveDownload] = []
    @Published private(set) var completed: [DownloadRecord] = []
    @Published private(set) var preparationProgress: [UUID: DownloadPreparationProgress] = [:]
    @Published private(set) var isRestoring = true
    @Published private(set) var storageRecoveryAvailable = false
    @Published private(set) var storageRetryAvailable = false
    @Published private(set) var totalStoredBytes: Int64 = 0
    @Published private(set) var failure: UserFacingError?
    @Published var errorMessage: String? {
        didSet { if errorMessage == nil { failure = nil } }
    }

    private let store: DownloadManifestStore
    private let storage: DownloadStorageCoordinator
    private let vault: DownloadResumeVault
    private let delegate: DownloadSessionDelegate
    private let sessionIdentifier: String
    private let sessionConfiguration: URLSessionConfiguration?
    private var sessions: [String: URLSession] = [:]
    private var tasks: [UUID: URLSessionTask] = [:]
    private var journal: [DownloadQueueEntry] = []
    private var provisional: [UUID: DownloadQueueEntry] = [:]
    private var revision: UInt64 = 0
    private var connection: ServerConnection?
    private var statusClient: RustyDLNAClient?
    private var allowsCellularDownloads: Bool
    private var startup: Task<Void, Never>?
    private var ownershipStarted = false
    private var pending: Task<Void, Never>?
    private var operationNumber = 0
    private var storageIsReadable = true
    private var poller: Task<Void, Never>?
    private var pollerID: UUID?
    private var pollerDeadline: Date?
    private var nextOptionalRequest = Date.distantPast
    private var isApplicationInForeground = true
    private var activityObservers: [NSObjectProtocol] = []
    private var inventoryTask: Task<Void, Never>?
    private var pollSchedule: [UUID: DownloadPollSchedule] = [:]
    private var finalMediaLengths: [UUID: Int64] = [:]
    private var pendingPauses: Set<UUID> = []
    private var pendingCancellations: Set<UUID> = []
    private var network: NWPathMonitor?
    private var networkAvailable = true
    private var networkIsCellular = false
    private let maximumTransfers: Int

    init(store: DownloadManifestStore = DownloadManifestStore(), allowsCellularDownloads: Bool = true,
         sessionIdentifier: String? = nil, sessionConfiguration: URLSessionConfiguration? = nil,
         maximumTransfers: Int = 2, resumeSecrets: SecretStoring = KeychainStore()) {
        self.store = store
        storage = DownloadStorageCoordinator(store: store)
        vault = DownloadResumeVault(rootDirectory: store.rootDirectory, secrets: resumeSecrets)
        delegate = DownloadSessionDelegate(store: store, coordinator: storage)
        self.allowsCellularDownloads = allowsCellularDownloads
        self.sessionIdentifier = sessionIdentifier ?? "\(Bundle.main.bundleIdentifier ?? "com.example.rustyView").downloads"
        self.sessionConfiguration = sessionConfiguration
        self.maximumTransfers = max(1, min(4, maximumTransfers))
        delegate.owner = self
    }

    /// Reattach system-owned sessions even when the user has no saved login.
    /// No filesystem or media inspection runs on the UI actor during startup.
    func startBackgroundOwnership() {
        guard !ownershipStarted else { return }
        ownershipStarted = true
        BackgroundSessionEvents.shared.register { [weak self] identifier in
            self?.reconnectBackgroundSession(identifier)
        }
        if sessionConfiguration == nil {
            setApplicationInForeground(UIApplication.shared.applicationState != .background)
            for (name, foreground) in [(UIApplication.didEnterBackgroundNotification, false),
                                       (UIApplication.willEnterForegroundNotification, true)] {
                activityObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.setApplicationInForeground(foreground) }
                })
            }
            let monitor = NWPathMonitor()
            network = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in
                    guard let self else { return }
                    self.updateNetworkPath(available: path.status == .satisfied, cellular: path.usesInterfaceType(.cellular))
                }
            }
            monitor.start(queue: DispatchQueue(label: "downloads.network"))
        }
        startup = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.restoreRuntimeState()
            } catch {
                await self.reportRestorationFailure(error)
            }
            self.isRestoring = false
        }
    }

    func configure(connection: ServerConnection?, statusClient: RustyDLNAClient? = nil) {
        stopPoller()
        self.connection = connection
        self.statusClient = (try? statusClient?.ownedConnection()) ?? connection.map { owner in
            let client = RustyDLNAClient(configuration: .ephemeral)
            client.configure(owner)
            return client
        }
        delegate.update(connection: connection)
        pollSchedule.removeAll()
        startBackgroundOwnership()
        enqueueOperation { [weak self] in try await self?.schedule() }
    }

    /// Optional status and UI progress do not keep doing work after the app
    /// leaves the foreground. URLSession retains transfer and completion ownership.
    func setApplicationInForeground(_ foreground: Bool) {
        if isApplicationInForeground != foreground {
            if foreground { DownloadPerformanceTrace.event("Downloads Foreground") }
            else { DownloadPerformanceTrace.event("Downloads Background") }
        }
        isApplicationInForeground = foreground
        delegate.progressDelivery.setEnabled(foreground)
        ensurePoller()
    }

    func recoverStorageIndex() {
        enqueueOperation { [weak self] in
            guard let self, self.storageRecoveryAvailable else { return }
            self.isRestoring = true
            defer { self.isRestoring = false }
            let rebuilt = try await self.storage.recoverDamagedIndex()
            // An explicitly recovered index starts a fresh revision history.
            // Only rebase after the backend has accepted recovery.
            self.revision = 0
            self.apply(rebuilt)
            self.storageIsReadable = true
            self.storageRecoveryAvailable = false
            self.storageRetryAvailable = false
            self.errorMessage = nil
            var restored: [(String, URLSessionTask)] = []
            for (identifier, session) in self.sessions {
                restored.append(contentsOf: await session.allTasks.map { (identifier, $0) })
            }
            try await self.reconcile(restored)
            try await self.schedule()
        }
    }

    func retryStorageRestoration() {
        enqueueOperation { [weak self] in
            guard let self, self.storageRetryAvailable else { return }
            self.isRestoring = true
            defer { self.isRestoring = false }
            do {
                try await self.restoreRuntimeState()
                self.storageRetryAvailable = false
                self.errorMessage = nil
            } catch { await self.reportRestorationFailure(error) }
        }
    }

    private func restoreRuntimeState() async throws {
        apply(try await storage.restore())
        storageIsReadable = true
        storageRecoveryAvailable = false
        var restored: [(String, URLSessionTask)] = []
        // The unsuffixed identifier retains pre-policy system tasks.
        for identifier in allSessionIdentifiers {
            let found = await session(identifier: identifier).allTasks
            restored.append(contentsOf: found.map { (identifier, $0) })
        }
        try await reconcile(restored)
        for entry in journal where entry.resources?.contains(where: {
            $0.state == .running && $0.sessionIdentifier.map { !self.isOriginSession($0) } == true
        }) == true {
            try await pauseJob(entry.id, userInitiated: false)
        }
        apply(try await storage.revalidatePendingAssets())
        try await schedule()
    }

    private func reportRestorationFailure(_ failure: Error) async {
        self.failure = UserFacingError(failure)
        errorMessage = self.failure?.message
        do {
            // Scanning, reconnecting, or writing can fail after a valid read.
            // Preserve those intents and offer a retry, never an index rebuild.
            apply(try await storage.snapshot())
            storageIsReadable = true
            storageRecoveryAvailable = false
            storageRetryAvailable = true
        } catch {
            storageIsReadable = false
            switch error {
            case DownloadStoreError.invalidManifest, DownloadQueueError.invalidJournal:
                storageRecoveryAvailable = true
                storageRetryAvailable = false
            default:
                storageRecoveryAvailable = false
                storageRetryAvailable = true
            }
        }
    }

    func waitForPendingOperations() async {
        startBackgroundOwnership()
        await startup?.value
        var observed: Int
        repeat {
            observed = operationNumber
            await pending?.value
        } while observed != operationNumber
        await inventoryTask?.value
    }

    func waitUntilRestored() async {
        startBackgroundOwnership()
        await startup?.value
    }

    func updateNetworkPath(available: Bool, cellular: Bool) {
        networkAvailable = available
        networkIsCellular = cellular
        ensurePoller()
        enqueueOperation { [weak self] in try await self?.schedule() }
    }

    func start(item: MediaItem, kind: DownloadKind, client: RustyDLNAClient, quality: String = "auto",
               qualityProfile: QualityProfile? = nil, audioIndex: Int? = nil) throws {
        guard let connection else { throw RustyDLNAError.notConfigured }
        guard storageIsReadable else { throw DownloadQueueError.invalidJournal }
        let path: String
        if kind == .original {
            guard let original = item.downloadURL else {
                throw RustyDLNAError.http(status: 404, message: "This title cannot be downloaded.", code: nil)
            }
            path = original
        } else {
            // The server's status lookup can be scoped by movie/request alone.
            // Use the client's unique initial request identity so concurrent
            // renditions cannot observe another download or player's producer.
            path = client.compatiblePath(for: item, delivery: "mp4", quality: quality, audioIndex: audioIndex)
        }
        _ = try client.authorizedRequest(serverPath: path)
        let audio = audioIndex ?? item.defaultAudioIndex
        var metadata = DownloadTaskMetadata(recordID: UUID(), serverOrigin: connection.serverIdentity,
            mediaID: item.id, title: item.title, kind: kind, fileExtension: kind == .compatible ? "mp4" : item.ext,
            durationSeconds: item.durationSeconds, resolution: item.resolution, serverPath: path, retryAttempt: 0,
            qualityID: kind == .compatible ? quality : nil,
            qualityLabel: kind == .compatible ? qualityProfile?.label ?? (quality == "auto" ? "Auto" : quality) : nil,
            audioTrackIndex: kind == .compatible ? audio : nil,
            audioTrackLabel: kind == .compatible ? item.audioTracks.first { $0.index == audio }?.selectionLabel(defaultIndex: item.defaultAudioIndex) : nil,
            accountUsername: connection.username)
        metadata.attemptID = UUID()
        metadata.movie = MovieMetadata(item: item)
        guard !active.contains(where: { DownloadOwnership.sameRendition($0.metadata, metadata) }),
              !completed.contains(where: { connection.owns(serverIdentity: $0.serverOrigin, accountUsername: $0.accountUsername)
                  && $0.mediaID == item.id && $0.kind == kind && $0.isReadyToWatch
                  && $0.qualityID == metadata.qualityID && $0.audioTrackIndex == metadata.audioTrackIndex }) else { return }
        let plan = OfflinePackagePlan(metadata: metadata, movie: MovieMetadata(item: item))
        var entry = DownloadQueueEntry(metadata: metadata)
        entry.packagePlan = plan
        entry.resources = plan.resources.map { DownloadResourceDescriptor(resource: $0) }
        entry.enqueuedAt = Date()
        provisional[entry.id] = entry
        publish()
        let intent = entry
        let estimate = DownloadOutputSummary.estimatedByteCount(item: item, kind: kind, quality: quality,
                                                               profile: qualityProfile, audioIndex: audioIndex)
        enqueueOperation { [weak self] in
            guard let self else { return }
            self.apply(try await self.storage.enqueue(intent))
            self.provisional.removeValue(forKey: intent.id)
            self.publish()
            if let estimate, let capacity = await self.availableCapacity(), estimate > capacity,
               var failed = self.entry(intent.id), let mediaIndex = failed.resources?.firstIndex(where: { $0.resource.kind == .media }) {
                failed.state = .failed
                failed.reason = "There is not enough free space for this download. Remove saved movies or free device storage, then retry."
                failed.failure = UserFacingError(category: .storage, message: failed.reason)
                failed.resources?[mediaIndex].state = .failed
                failed.resources?[mediaIndex].reason = failed.reason
                failed.resources?[mediaIndex].failure = failed.failure
                try await self.save(failed)
                return
            }
            try await self.schedule()
        }
    }

    func pause(_ download: ActiveDownload) {
        guard let entry = entry(download.id), !entry.state.isTerminal,
              !pendingCancellations.contains(entry.id),
              ![.failed, .paused, .pausing].contains(entry.state), pendingPauses.insert(entry.id).inserted else { return }
        // Stop network delivery immediately, even when another movie is being
        // inspected ahead of the durable pause operation.
        suspendTransfers(entry)
        DownloadPerformanceTrace.event("Download Pause Requested")
        setVisiblePhase(download.id, .pausing)
        ensurePoller()
        enqueueOperation { [weak self] in
            guard let self else { return }
            defer { self.pendingPauses.remove(entry.id); self.publish(); self.ensurePoller() }
            do { try await self.pauseJob(entry.id, userInitiated: true) }
            catch {
                // A rejected durable pause must not strand a suspended task.
                for resource in self.entry(entry.id)?.resources ?? [] {
                    if let task = self.tasks[resource.transferID], task.state == .suspended { task.resume() }
                }
                throw error
            }
        }
    }

    func resume(_ download: ActiveDownload) {
        enqueueOperation { [weak self] in
            guard let self, var entry = self.entry(download.id), entry.state == .paused else { return }
            for index in entry.resources?.indices ?? 0..<0 where entry.resources?[index].state == .paused {
                entry.resources?[index].state = .queued
                entry.resources?[index].failure = nil
            }
            if let issue = entry.failure, self.failure?.id == issue.id { self.errorMessage = nil }
            entry.failure = nil
            entry.state = .queued
            try await self.save(entry)
            try await self.finishPackage(entry.id)
            try await self.schedule()
        }
    }

    func retry(_ download: ActiveDownload) {
        enqueueOperation { [weak self] in
            guard let self, var entry = self.entry(download.id), entry.state == .failed else { return }
            guard DownloadOwnership.matches(entry.metadata, connection: self.connection) else {
                entry.reason = DownloadQueueError.missingOwnership.localizedDescription
                entry.failure = UserFacingError(DownloadQueueError.missingOwnership)
                try await self.save(entry)
                return
            }
            let old = entry.metadata
            if entry.resources?.contains(where: { $0.state == .delivered || $0.state == .running }) != true {
                entry.metadata.attemptID = UUID()
            }
            // Successfully staged siblings retain the same logical attempt.
            // Only the failed resource receives a new transfer UUID.
            for index in entry.resources?.indices ?? 0..<0 where entry.resources?[index].state == .failed {
                if entry.resources?[index].resource.kind == .media, entry.metadata.kind == .compatible,
                   let path = entry.metadata.serverPath {
                    let replacement = try DownloadPreparedRequest.replacementPath(path)
                    entry.metadata.serverPath = replacement
                    entry.resources?[index].serverPath = replacement
                    self.cancelPreparedRequest(old)
                }
                try? await self.vault.remove(entry.resources?[index].resumeReference)
                entry.resources?[index].resumeReference = nil
                entry.resources?[index].transferID = UUID()
                entry.resources?[index].retryAttempt = 0
                entry.resources?[index].scheduledAt = nil
                entry.resources?[index].state = .queued
                entry.resources?[index].reason = nil
                entry.resources?[index].failure = nil
            }
            entry.metadata.retryAttempt = 0
            entry.state = .queued
            entry.reason = nil
            entry.failure = nil
            entry.scheduledAt = nil
            self.apply(try await self.storage.update(entry, expectedAttemptID: old.attemptID))
            try await self.finishPackage(entry.id)
            try await self.schedule()
        }
    }

    func cancel(_ download: ActiveDownload) {
        guard let entry = entry(download.id), !entry.state.isTerminal,
              pendingCancellations.insert(download.id).inserted else { return }
        startBackgroundOwnership()
        // Acknowledge the tap and stop receiving immediately. Keep tasks owned
        // until the tombstone commits so a storage error can restore the row.
        suspendTransfers(entry)
        DownloadPerformanceTrace.event("Download Cancel Requested")
        publish()
        ensurePoller()
        // Cancellation may overtake media inspection. The actor rechecks its
        // durable tombstone after inspection returns; the UI never waits for it.
        let previous = pending
        let cancellation = Task { [weak self] in
            guard let self else { return }
            defer { self.pendingCancellations.remove(download.id); self.publish(); self.ensurePoller() }
            await self.startup?.value
            if self.provisional[download.id] != nil { await previous?.value }
            do {
                self.apply(try await self.storage.cancel(recordID: download.id))
                await self.cancelTransfers(entry)
                self.cancelPreparedRequest(entry.metadata)
            } catch {
                if let snapshot = try? await self.storage.snapshot() { self.apply(snapshot) }
                if self.entry(download.id)?.state.isTerminal == false {
                    for resource in self.entry(download.id)?.resources ?? [] {
                        if let task = self.tasks[resource.transferID], task.state == .suspended,
                           !self.pendingPauses.contains(download.id) { task.resume() }
                    }
                }
                self.failure = UserFacingError(error)
                self.errorMessage = self.failure?.message
            }
        }
        enqueueOperation { [weak self] in await cancellation.value; try await self?.schedule() }
    }

    func dismissFailure(_ download: ActiveDownload) { cancel(download) }

    func delete(_ record: DownloadRecord) {
        enqueueOperation { [weak self] in
            guard let self else { return }
            if let entry = self.entry(record.id) { await self.cancelTransfers(entry) }
            self.apply(try await self.storage.delete(recordID: record.id))
            try await self.schedule()
        }
    }

    func setAllowsCellularDownloads(_ allowed: Bool) {
        guard allowed != allowsCellularDownloads else { return }
        allowsCellularDownloads = allowed
        enqueueOperation { [weak self] in
            guard let self else { return }
            let live = self.journal.filter { !$0.state.isTerminal && $0.state != .paused && $0.state != .failed }
            for entry in live { try await self.pauseJob(entry.id, userInitiated: false) }
            try await self.schedule()
        }
    }

    func localURL(for record: DownloadRecord) -> URL { store.localURL(for: record) }
    func artworkURL(for record: DownloadRecord) -> URL? { store.cachedArtworkURL(for: record) }
    func captionURL(for record: DownloadRecord, caption: OfflineCaption) -> URL? { store.cachedCaptionURL(for: record, caption: caption) }
    func record(for mediaID: String) -> DownloadRecord? {
        guard let connection else { return nil }
        return completed.filter { connection.owns(serverIdentity: $0.serverOrigin, accountUsername: $0.accountUsername) && $0.mediaID == mediaID }
            .sorted {
                if $0.isReadyToWatch != $1.isReadyToWatch { return $0.isReadyToWatch }
                if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
                return $0.id.uuidString < $1.id.uuidString
            }.first
    }
    func activeDownload(for mediaID: String) -> ActiveDownload? {
        active.first { $0.mediaID == mediaID && DownloadOwnership.matches($0.metadata, connection: connection) }
    }
    func preparationProgress(for download: ActiveDownload) -> DownloadPreparationProgress? { preparationProgress[download.id] }

    func resourceProgress(_ envelope: DownloadTaskEnvelope, received: Int64, expected: Int64?) {
        guard !pendingPauses.contains(envelope.metadata.recordID),
              let (entry, resource) = owned(envelope), resource.state == .running else { return }
        if let limit = resource.sizeLimit, received > limit {
            tasks[resource.transferID]?.cancel()
            Task { [weak self] in
                await self?.resourceFailure(envelope, message: "A download resource exceeded its supported size.", retryable: false,
                                            failure: UserFacingError(category: .invalidMedia))
            }
            return
        }
        guard envelope.kind == .media, isApplicationInForeground else { return }
        guard active.first(where: { $0.id == entry.id })?.phase != .finishing else { return }
        let expected = expected ?? finalMediaLengths[resource.transferID].flatMap { $0 >= received ? $0 : nil }
        setVisiblePhase(entry.id, .downloading(progress: expected.map { min(1, Double(received) / Double($0)) } ?? 0,
                                              received: received, expected: expected))
    }

    func receive(_ receipt: DownloadReceipt, envelope: DownloadTaskEnvelope) async {
        enqueueOperation { [weak self] in
            guard let self else { return }
            let resumeReference = self.owned(envelope)?.1.resumeReference
            self.tasks.removeValue(forKey: envelope.transferID)
            if envelope.kind == .media {
                self.setVisiblePhase(envelope.metadata.recordID, .finishing)
            }
            do {
                self.apply(try await self.storage.receive(receipt))
                try? await self.vault.remove(resumeReference)
            } catch {
                self.apply(try await self.storage.snapshot())
                if self.owned(envelope)?.1.state == .delivered {
                    try await self.failPackage(envelope.metadata.recordID, message: error.localizedDescription, failure: UserFacingError(error))
                } else {
                    try await self.failResource(envelope, message: error.localizedDescription, retryable: false, failure: UserFacingError(error))
                }
            }
            try await self.schedule()
        }
        await pending?.value
    }

    func resourceFailure(_ envelope: DownloadTaskEnvelope, message: String, retryable: Bool,
                         resumeData: Data? = nil, cancelled: Bool = false, cannotResume: Bool = false,
                         failure: UserFacingError? = nil) async {
        enqueueOperation { [weak self] in
            guard let self else { return }
            self.tasks.removeValue(forKey: envelope.transferID)
            guard let (_, resource) = self.owned(envelope) else { try await self.schedule(); return }
            // cancel(byProducingResumeData:) is owned by pauseJob; its cancelled
            // completion must not turn an intentional pause into a failure.
            if cancelled && (resource.state == .pausing || resource.state == .paused) { return }
            let rejectedResume = cannotResume && resource.resumeReference != nil
            try await self.failResource(envelope, message: message, retryable: retryable || rejectedResume,
                                        resumeData: resumeData, cannotResume: rejectedResume, failure: failure)
            try await self.schedule()
        }
        await pending?.value
    }

    private func failResource(_ envelope: DownloadTaskEnvelope, message: String, retryable: Bool,
                              resumeData: Data? = nil, cannotResume: Bool = false, failure: UserFacingError? = nil) async throws {
        guard var (entry, resource) = owned(envelope), resource.state != .delivered,
              resource.state != .failed else { return }
        let previousFailure = entry.state == .failed ? entry.reason : nil
        let previousIssue = entry.state == .failed ? entry.failure : nil
        resource.failure = failure
        tasks.removeValue(forKey: resource.transferID)
        resource.taskIdentifier = nil
        resource.sessionIdentifier = nil
        if let resumeData { resource.resumeReference = try await vault.save(resumeData, envelope: envelope) }
        if cannotResume {
            try? await vault.remove(resource.resumeReference)
            resource.resumeReference = nil
            resource.reason = "The server could not resume the saved bytes. This download will restart."
        } else { resource.reason = message }
        if retryable && resource.retryAttempt < DownloadRetryPolicy.maximumAttempts {
            resource.retryAttempt += 1
            resource.scheduledAt = Date().addingTimeInterval(DownloadRetryPolicy.delay(forAttempt: resource.retryAttempt))
            resource.transferID = UUID()
            resource.state = .queued
            entry.state = previousFailure == nil ? .queued : .failed
        } else {
            resource.state = .failed
            if resource.resource.required || previousFailure != nil { entry.state = .failed }
        }
        if resource.resource.kind == .media {
            entry.metadata.retryAttempt = resource.retryAttempt
            entry.scheduledAt = resource.scheduledAt
        }
        entry.reason = resource.resource.kind == .media ? resource.reason : previousFailure ?? resource.reason
        entry.failure = resource.resource.kind == .media ? resource.failure : previousIssue ?? resource.failure
        replace(resource, in: &entry)
        try await save(entry)
        if !resource.resource.required && resource.state == .failed {
            try await finishPackage(entry.id)
        }
    }

    private func finishPackage(_ id: UUID) async throws {
        do { apply(try await storage.finishAvailablePackage(recordID: id)) }
        catch {
            apply(try await storage.snapshot())
            try await failPackage(id, message: error.localizedDescription, failure: UserFacingError(error))
        }
    }

    private func failPackage(_ id: UUID, message: String, failure: UserFacingError? = nil) async throws {
        guard var failed = entry(id), !failed.state.isTerminal else { return }
        failed.state = .failed
        failed.reason = message
        failed.failure = failure
        try await save(failed)
    }

    private func pauseJob(_ id: UUID, userInitiated: Bool) async throws {
        guard var entry = entry(id), !entry.state.isTerminal, entry.state != .failed else { return }
        entry.state = .pausing
        for index in entry.resources?.indices ?? 0..<0 {
            if [.queued, .running].contains(entry.resources?[index].state) { entry.resources?[index].state = .pausing }
        }
        try await save(entry)
        var resumeFailure: UserFacingError?
        for original in entry.resources ?? [] where original.state == .pausing {
            var resource = original
            var failedToSaveResume = false
            let envelope = DownloadTaskEnvelope(metadata: entry.metadata, resource: resource)
            if let task = tasks.removeValue(forKey: resource.transferID) as? URLSessionDownloadTask {
                resource.receivedBytes = max(0, task.countOfBytesReceived)
                resource.expectedBytes = task.countOfBytesExpectedToReceive > 0 ? task.countOfBytesExpectedToReceive : nil
                let data = await withCheckedContinuation { continuation in
                    task.cancel { continuation.resume(returning: $0) }
                }
                if let data {
                    do { resource.resumeReference = try await vault.save(data, envelope: envelope) }
                    catch {
                        let cause = UserFacingError(error)
                        let issue = UserFacingError(category: cause.category, title: cause.title,
                            message: "Download progress could not be saved. \(cause.message) Continuing will restart this file.")
                        try? await vault.remove(resource.resumeReference)
                        resource.resumeReference = nil
                        resource.reason = issue.message
                        resource.failure = issue
                        resumeFailure = resumeFailure ?? issue
                        failedToSaveResume = true
                    }
                }
                if resource.receivedBytes > 0 && resource.resumeReference == nil && !failedToSaveResume {
                    resource.reason = "The server did not provide resumable bytes. Continuing will restart this file."
                }
            }
            resource.transferID = UUID()
            resource.taskIdentifier = nil
            resource.sessionIdentifier = nil
            resource.state = userInitiated ? .paused : failedToSaveResume ? .failed : .queued
            replace(resource, in: &entry)
        }
        entry.state = userInitiated ? .paused : resumeFailure == nil ? .queued : .failed
        if let resumeFailure {
            entry.reason = resumeFailure.message
            entry.failure = resumeFailure
        }
        // scheduledAt and retryAttempt intentionally survive policy migration.
        try await save(entry)
        if userInitiated, let resumeFailure {
            failure = resumeFailure
            errorMessage = resumeFailure.message
        }
        if userInitiated { try await schedule() }
    }

    private func schedule() async throws {
        guard storageIsReadable else { return }
        // Background URLSession never sends taskIsWaitingForConnectivity. A
        // restored system task still needs a truthful wait label from NWPath.
        for original in journal where !original.state.isTerminal && ![.failed, .paused, .pausing].contains(original.state)
            && original.resources?.contains(where: { $0.state == .running }) == true {
            var entry = original
            let reason: DownloadWaitingReason? = !networkAvailable ? .network : !allowsCellularDownloads && networkIsCellular ? .wifi : nil
            if let reason, entry.state != .waiting || entry.waitingReason != reason {
                entry.state = .waiting
                entry.waitingReason = reason
                try await save(entry)
            } else if reason == nil, entry.state == .waiting, [.wifi, .network].contains(entry.waitingReason) {
                entry.state = .running
                entry.waitingReason = nil
                try await save(entry)
            }
        }
        var slots = max(0, maximumTransfers - tasks.count)
        let ordered = journal.filter { !$0.state.isTerminal && ![.failed, .paused, .pausing].contains($0.state)
            && !pendingPauses.contains($0.id) && !pendingCancellations.contains($0.id) }
            .sorted {
                let left = $0.enqueuedAt ?? .distantPast, right = $1.enqueuedAt ?? .distantPast
                return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
            }
        // One resource per job in each pass prevents a poster/caption bundle
        // from consuming every slot ahead of another selected movie.
        for _ in 0..<maximumTransfers {
            for original in ordered {
                guard var entry = entry(original.id), !entry.state.isTerminal,
                      let resource = entry.resources?.first(where: { $0.state == .queued }) else { continue }
                let reason: DownloadWaitingReason?
                if !DownloadOwnership.matches(entry.metadata, connection: connection)
                    && (resource.resumeReference == nil || entry.metadata.accountUsername == nil) { reason = .credentials }
                else if !networkAvailable { reason = .network }
                else if !allowsCellularDownloads && networkIsCellular { reason = .wifi }
                else if slots == 0 { reason = .turn }
                else { reason = nil }
                if let reason {
                    if entry.resources?.contains(where: { $0.state == .running }) != true,
                       entry.state != .waiting || entry.waitingReason != reason {
                        entry.state = .waiting
                        entry.waitingReason = reason
                        try await save(entry)
                    }
                    continue
                }
                try await launch(entry, resource: resource)
                slots -= 1
            }
        }
        ensurePoller()
    }

    private func launch(_ original: DownloadQueueEntry, resource originalResource: DownloadResourceDescriptor) async throws {
        var entry = original
        var resource = originalResource
        let identifier = originSessionIdentifier(metadata: entry.metadata)
        let session = session(identifier: identifier)
        let envelope = DownloadTaskEnvelope(metadata: entry.metadata, resource: resource)
        let task: URLSessionDownloadTask
        let resumeData: Data?
        do { resumeData = try await resource.resumeReference.flatMapAsync { try await vault.load($0, envelope: envelope) } }
        catch {
            resource.resumeReference = nil
            resource.reason = "The saved resume information could not be read. This file will restart."
            resumeData = nil
        }
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
            if let url = task.originalRequest?.url, !DownloadOriginPolicy.permits(url, metadata: entry.metadata) {
                task.cancel()
                throw RustyDLNAError.untrustedURL
            }
        } else {
            guard let connection, DownloadOwnership.matches(entry.metadata, connection: connection) else { throw DownloadQueueError.missingOwnership }
            let url = try connection.resolve(serverPath: resource.serverPath)
            var request = URLRequest(url: url)
            request.setValue(connection.authorizationHeader(), forHTTPHeaderField: "Authorization")
            request.setValue(resource.resource.kind == .media ? "video/*, application/octet-stream" : "*/*", forHTTPHeaderField: "Accept")
            // Policy belongs to the background session. This lets an opaque
            // resume request move between policy sessions without plist edits.
            request.allowsCellularAccess = true
            request.allowsExpensiveNetworkAccess = true
            request.allowsConstrainedNetworkAccess = true
            task = session.downloadTask(with: request)
        }
        task.taskDescription = String(data: try JSONEncoder().encode(envelope), encoding: .utf8)
        task.earliestBeginDate = resource.scheduledAt
        resource.taskIdentifier = task.taskIdentifier
        resource.sessionIdentifier = identifier
        resource.state = .running
        entry.state = .running
        entry.waitingReason = nil
        if resource.resource.kind == .media { entry.taskIdentifier = task.taskIdentifier }
        replace(resource, in: &entry)
        do { try await save(entry) } catch { task.cancel(); throw error }
        guard owned(envelope) != nil else { task.cancel(); return }
        tasks[resource.transferID] = task
        task.resume()
        publish()
    }

    private func reconcile(_ restored: [(String, URLSessionTask)]) async throws {
        guard storageIsReadable else { return }
        var claimed = Set<UUID>()
        var renditions: [DownloadTaskMetadata] = []
        for (sessionID, task) in restored.sorted(by: { $0.1.taskIdentifier < $1.1.taskIdentifier }) {
            guard task.state != .completed, task.state != .canceling,
                  let envelope = DownloadTaskEnvelope.decode(task.taskDescription) else { task.cancel(); continue }
            var entry = entry(envelope.metadata.recordID)
            if entry == nil {
                guard !renditions.contains(where: { DownloadOwnership.sameRendition($0, envelope.metadata) }) else { task.cancel(); continue }
                var legacy = DownloadQueueEntry(metadata: envelope.metadata)
                legacy.scheduledAt = task.earliestBeginDate
                legacy.enqueuedAt = .distantPast
                legacy = upgraded(legacy)
                if let index = legacy.resources?.firstIndex(where: { $0.id == envelope.resourceID }) {
                    legacy.resources?[index].transferID = envelope.transferID
                    legacy.resources?[index].scheduledAt = task.earliestBeginDate
                }
                do { apply(try await storage.enqueue(legacy)) }
                catch {
                    legacy.state = .failed
                    legacy.reason = error.localizedDescription
                    legacy.failure = UserFacingError(error)
                    provisional[legacy.id] = legacy
                    publish()
                    task.suspend()
                    throw error
                }
                entry = legacy
            }
            if let pendingIntent = provisional[envelope.metadata.recordID] {
                do {
                    apply(try await storage.enqueue(pendingIntent))
                    provisional.removeValue(forKey: pendingIntent.id)
                    publish()
                } catch { task.suspend(); throw error }
                task.suspend()
                continue
            }
            guard var existing = entry, !existing.state.isTerminal,
                  ![.failed, .paused, .pausing].contains(existing.state),
                  existing.metadata.attemptID == envelope.metadata.attemptID,
                  DownloadOwnership.sameRendition(existing.metadata, envelope.metadata),
                  (existing.metadata.retryAttempt ?? 0) <= (envelope.metadata.retryAttempt ?? 0),
                  var resource = existing.resources?.first(where: { $0.id == envelope.resourceID }),
                  resource.transferID == envelope.transferID,
                  claimed.insert(envelope.transferID).inserted else { task.cancel(); continue }
            resource.taskIdentifier = task.taskIdentifier
            resource.sessionIdentifier = sessionID
            resource.state = .running
            existing.state = .running
            if resource.resource.kind == .media { existing.taskIdentifier = task.taskIdentifier }
            replace(resource, in: &existing)
            do { try await save(existing) }
            catch {
                task.suspend()
                setVisiblePhase(existing.id, .failed(message: error.localizedDescription))
                throw error
            }
            tasks[resource.transferID] = task
            publish()
            if task.state == .running, task.earliestBeginDate.map({ $0 <= Date() }) != false,
               DownloadResponseValidator.failure(for: task.response) == nil {
                resourceProgress(envelope, received: max(0, task.countOfBytesReceived),
                                 expected: DownloadHTTPRange.completeLength(of: task.response))
            }
            renditions.append(existing.metadata)
            if task.state == .suspended, DownloadOwnership.matches(existing.metadata, connection: connection) { task.resume() }
        }
        for original in journal where !original.state.isTerminal {
            var entry = upgraded(original)
            for index in entry.resources?.indices ?? 0..<0 {
                guard let resource = entry.resources?[index], !claimed.contains(resource.transferID) else { continue }
                if resource.state == .running { entry.resources?[index].state = .queued }
                if resource.state == .pausing { entry.resources?[index].state = .paused }
                entry.resources?[index].taskIdentifier = nil
                entry.resources?[index].sessionIdentifier = nil
            }
            if entry.state == .pausing { entry.state = .paused }
            if entry != original { try await save(entry) }
        }
    }

    private func upgraded(_ original: DownloadQueueEntry) -> DownloadQueueEntry {
        guard original.resources == nil else { return original }
        var entry = original
        let movie = entry.metadata.movie ?? MovieMetadata(mediaID: entry.metadata.mediaID, title: entry.metadata.title,
                                                          durationSeconds: entry.metadata.durationSeconds.map(Double.init), resolution: entry.metadata.resolution)
        let plan = OfflinePackagePlan(metadata: entry.metadata, movie: movie)
        entry.packagePlan = plan
        entry.resources = plan.resources.map { resource in
            var descriptor = DownloadResourceDescriptor(resource: resource, transferID: entry.metadata.attemptID ?? entry.id)
            descriptor.retryAttempt = entry.metadata.retryAttempt ?? 0
            descriptor.scheduledAt = entry.scheduledAt
            descriptor.state = entry.state == .failed ? .failed : entry.state == .paused ? .paused : .queued
            return descriptor
        }
        return entry
    }

    private func cancelTransfers(_ entry: DownloadQueueEntry) async {
        for (transferID, task) in tasks where DownloadSessionDelegate.metadata(for: task)?.recordID == entry.id {
            task.cancel()
            tasks.removeValue(forKey: transferID)
        }
        for resource in entry.resources ?? [] {
            tasks.removeValue(forKey: resource.transferID)?.cancel()
            try? await vault.remove(resource.resumeReference)
        }
        for session in sessions.values {
            for task in await session.allTasks where DownloadSessionDelegate.metadata(for: task)?.recordID == entry.id { task.cancel() }
        }
    }

    private func suspendTransfers(_ entry: DownloadQueueEntry) {
        for resource in entry.resources ?? [] {
            if let task = tasks[resource.transferID], task.state == .running { task.suspend() }
        }
    }

    private var allSessionIdentifiers: [String] {
        let legacy = [sessionIdentifier] + DownloadSessionPolicy.allCases.map { sessionIdentifier + "." + $0.rawValue }
        let recorded = journal.flatMap { $0.resources ?? [] }.compactMap(\.sessionIdentifier).filter { isOriginSession($0) }
        return Array(Set(legacy + recorded)).sorted()
    }
    private func originSessionIdentifier(metadata: DownloadTaskMetadata) -> String {
        let url = URL(string: metadata.serverOrigin)
        let origin = url.map(URLOrigin.init(url:))
        let value = "\(origin?.scheme ?? "")|\(origin?.host ?? "")|\(origin?.port ?? 0)"
        let hash = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return sessionIdentifier + ".origin-" + hash + "." + DownloadSessionPolicy.selected(allowsCellular: allowsCellularDownloads).rawValue
    }
    private func isOriginSession(_ identifier: String) -> Bool {
        let prefix = sessionIdentifier + ".origin-"
        guard identifier.hasPrefix(prefix) else { return false }
        let parts = identifier.dropFirst(prefix.count).split(separator: ".")
        return parts.count == 2 && parts[0].count == 64 && parts[0].allSatisfy { $0.isHexDigit }
            && DownloadSessionPolicy(rawValue: String(parts[1])) != nil
    }
    private func session(identifier: String) -> URLSession {
        if let session = sessions[identifier] { return session }
        let policy: DownloadSessionPolicy = identifier.hasSuffix(".wifi") ? .wifi : .anyNetwork
        let session = URLSession(configuration: policy.configuration(identifier: identifier, template: sessionConfiguration), delegate: delegate, delegateQueue: nil)
        sessions[identifier] = session
        return session
    }
    private func reconnectBackgroundSession(_ identifier: String) {
        guard allSessionIdentifiers.contains(identifier) || isOriginSession(identifier) else { return }
        _ = session(identifier: identifier)
        startBackgroundOwnership()
    }
    private func enqueueOperation(_ operation: @escaping @MainActor () async throws -> Void) {
        startBackgroundOwnership()
        let previous = pending
        operationNumber += 1
        pending = Task { [weak self] in
            await self?.startup?.value
            await previous?.value
            do { try await operation() }
            catch {
                let failure = UserFacingError(error)
                self?.failure = failure
                self?.errorMessage = failure.message
                // Pending intent stays visible if the durable save itself fails.
                for id in self?.provisional.keys.map({ $0 }) ?? [] {
                    self?.provisional[id]?.state = .failed
                    self?.provisional[id]?.reason = failure.message
                    self?.provisional[id]?.failure = failure
                }
                self?.publish()
            }
        }
    }
    private func entry(_ id: UUID) -> DownloadQueueEntry? { journal.first { $0.id == id } ?? provisional[id] }
    private func owned(_ envelope: DownloadTaskEnvelope) -> (DownloadQueueEntry, DownloadResourceDescriptor)? {
        guard !pendingCancellations.contains(envelope.metadata.recordID),
              let entry = entry(envelope.metadata.recordID), !entry.state.isTerminal,
              entry.metadata.attemptID == envelope.metadata.attemptID,
              let resource = entry.resources?.first(where: { $0.id == envelope.resourceID && $0.transferID == envelope.transferID }) else { return nil }
        return (entry, resource)
    }
    private func replace(_ resource: DownloadResourceDescriptor, in entry: inout DownloadQueueEntry) {
        guard let index = entry.resources?.firstIndex(where: { $0.id == resource.id }) else { return }
        entry.resources?[index] = resource
    }
    private func save(_ entry: DownloadQueueEntry) async throws {
        apply(try await storage.update(entry, expectedAttemptID: entry.metadata.attemptID))
    }
    private func availableCapacity() async -> Int64? {
        let directory = store.rootDirectory
        return await Task.detached(priority: .utility) {
            try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        }.value
    }
    private func apply(_ snapshot: DownloadStorageSnapshot) {
        guard snapshot.revision >= revision else { return }
        revision = snapshot.revision
        journal = snapshot.queue
        completed = snapshot.records.sorted { $0.completedAt > $1.completedAt }
        publish()
        refreshInventory()
    }
    private func refreshInventory() {
        guard inventoryTask == nil else { return }
        inventoryTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let observed = self.revision
                do {
                    let items = try await self.storage.inventory()
                    guard self.revision == observed else { continue }
                    self.totalStoredBytes = items.reduce(0) { total, item in
                        let sum = total.addingReportingOverflow(max(0, item.byteCount))
                        return sum.overflow ? Int64.max : sum.partialValue
                    }
                } catch { break }
                break
            }
            self?.inventoryTask = nil
        }
    }
    private func publish() {
        let previous = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
        var entries = journal.filter { provisional[$0.id] == nil }
        entries.append(contentsOf: provisional.values)
        active = entries.compactMap { entry in
            guard var row = entry.activeDownload else { return nil }
            if entry.resources?.contains(where: { $0.resource.kind == .media && tasks[$0.transferID] != nil }) != true {
                row.taskIdentifier = -1
            }
            if let prior = previous[row.id], entry.state == .running, case .downloading = prior.phase { row.phase = prior.phase }
            if pendingPauses.contains(row.id) { row.phase = .pausing }
            if pendingCancellations.contains(row.id) { row.phase = .cancelling }
            return row
        }.sorted { (entry($0.id)?.enqueuedAt ?? .distantPast) < (entry($1.id)?.enqueuedAt ?? .distantPast) }
        let live = Set(active.map(\.id))
        preparationProgress = preparationProgress.filter { live.contains($0.key) }
        pollSchedule = pollSchedule.filter { live.contains($0.key) }
        let transfers = Set(journal.filter { live.contains($0.id) }.flatMap { $0.resources ?? [] }.map(\.transferID))
        finalMediaLengths = finalMediaLengths.filter { transfers.contains($0.key) }
    }
    private func setVisiblePhase(_ id: UUID, _ phase: DownloadPhase) {
        if let index = active.firstIndex(where: { $0.id == id }) {
            let next = pendingCancellations.contains(id) ? .cancelling : pendingPauses.contains(id) ? .pausing : phase
            if active[index].phase != next {
                if case .downloading = next { DownloadPerformanceTrace.event("Download UI Progress") }
                active[index].phase = next
            }
        }
    }

    // Compatibility entry points used by restoration/installation regression
    // tests; they enter the same asynchronous ownership pipeline as delegates.
    func restore(tasks: [URLSessionTask]) {
        enqueueOperation { [weak self] in
            try await self?.reconcile(tasks.map { ("restoration-test", $0) })
        }
    }
    func update(taskIdentifier: Int, phase: DownloadPhase, metadata: DownloadTaskMetadata? = nil) {
        guard let row = active.first(where: { metadata == nil
            ? $0.taskIdentifier == taskIdentifier : $0.id == metadata?.recordID && $0.metadata.attemptID == metadata?.attemptID }) else { return }
        setVisiblePhase(row.id, phase)
    }
    func handleFailure(taskIdentifier: Int, message: String, retryable: Bool, metadata: DownloadTaskMetadata? = nil) {
        guard let entry = journal.first(where: { metadata == nil ? $0.taskIdentifier == taskIdentifier : $0.id == metadata?.recordID }),
              let resource = entry.resources?.first(where: { $0.resource.kind == .media }) else { return }
        let envelope = DownloadTaskEnvelope(metadata: metadata ?? entry.metadata, resource: resource)
        enqueueOperation { [weak self] in
            try await self?.failResource(envelope, message: message, retryable: retryable)
            try await self?.schedule()
        }
    }
    func finish(taskIdentifier: Int, record: DownloadRecord, metadata: DownloadTaskMetadata? = nil) {
        enqueueOperation { [weak self] in self?.apply(try await self?.storage.snapshot() ?? DownloadStorageSnapshot()) }
    }

    private func stopPoller() {
        poller?.cancel()
        poller = nil
        pollerID = nil
        pollerDeadline = nil
    }

    private func pollingEntries() -> [DownloadQueueEntry] {
        guard isApplicationInForeground, let client = statusClient, networkAvailable,
              allowsCellularDownloads || !networkIsCellular else { return [] }
        return journal.filter { $0.metadata.kind == .compatible && !$0.state.isTerminal
            && ![.failed, .paused, .pausing].contains($0.state)
            && !pendingPauses.contains($0.id) && !pendingCancellations.contains($0.id)
            && DownloadOwnership.matches($0.metadata, connection: client.connection)
            && $0.resources?.contains(where: { $0.resource.kind == .media && $0.state == .running
                && tasks[$0.transferID]?.state == .running }) == true
            && pollState(for: $0).needsWork }
    }

    private func nextPollDate(for entry: DownloadQueueEntry) -> Date {
        let scheduled = entry.resources?.first { $0.resource.kind == .media }?.scheduledAt ?? .distantPast
        return max(pollState(for: entry).next, scheduled)
    }

    private func ensurePoller() {
        guard let next = pollingEntries().map({ nextPollDate(for: $0) }).min() else { stopPoller(); return }
        let deadline = max(next, nextOptionalRequest)
        if poller != nil {
            guard let planned = pollerDeadline else { return }
            if deadline >= planned { return }
        }
        stopPoller()
        let id = UUID()
        pollerID = id
        pollerDeadline = deadline
        poller = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)), tolerance: .milliseconds(100)) }
            catch { return }
            guard !Task.isCancelled, let self, self.pollerID == id else { return }
            self.pollerDeadline = nil
            self.nextOptionalRequest = Date().addingTimeInterval(1)
            await self.pollOne()
            guard !Task.isCancelled, self.pollerID == id else { return }
            self.poller = nil
            self.pollerID = nil
            self.ensurePoller()
        }
    }

    private func pollOne() async {
        guard let client = statusClient else { return }
        let now = Date()
        guard let entry = pollingEntries().filter({ nextPollDate(for: $0) <= now })
            .min(by: { nextPollDate(for: $0) < nextPollDate(for: $1) }),
              let path = entry.metadata.serverPath,
              let resource = entry.resources?.first(where: { $0.resource.kind == .media && $0.state == .running }),
              let mediaTask = tasks[resource.transferID], mediaTask.state == .running else { return }
        let envelope = DownloadTaskEnvelope(metadata: entry.metadata, resource: resource)
        var schedule = pollState(for: entry)
        if schedule.fetchFinalSize {
            let trace = DownloadPerformanceTrace.begin("Download Final Size Request")
            defer { DownloadPerformanceTrace.end("Download Final Size Request", trace) }
            schedule.lengthAttempts = min(3, schedule.lengthAttempts + 1)
            let length: Int64?
            var sizeEndpointUnavailable = false
            do { length = try await client.completedDownloadByteCount(serverPath: path) }
            catch {
                length = nil
                if case RustyDLNAError.authenticationFailed = error { sizeEndpointUnavailable = true }
                if case RustyDLNAError.http(let code, _, _) = error, [404, 405, 501].contains(code) { sizeEndpointUnavailable = true }
            }
            guard !Task.isCancelled, tasks[resource.transferID] === mediaTask, mediaTask.state == .running,
                  let current = owned(envelope), current.1.state == .running,
                  current.0.metadata.serverPath == path, DownloadOwnership.matches(entry.metadata, connection: connection) else { return }
            if let length, let row = active.first(where: { $0.id == entry.id }) {
                let received: Int64
                if case .downloading(_, let bytes, _) = row.phase { received = bytes } else { received = 0 }
                if length >= received {
                    finalMediaLengths[resource.transferID] = length
                    schedule.preparationComplete = true
                    if let preparation = preparationProgress[entry.id] {
                        preparationProgress[entry.id] = DownloadPreparationProgress(
                            producedSeconds: preparation.producedSeconds, durationSeconds: entry.metadata.durationSeconds, isComplete: true)
                    }
                    resourceProgress(envelope, received: received, expected: length)
                }
            }
            schedule.fetchFinalSize = !sizeEndpointUnavailable && finalMediaLengths[resource.transferID] == nil
                && (schedule.sizeOnly || schedule.lengthAttempts < 3)
            // Without the optional status endpoint, an unknown-length HEAD is
            // expected while output grows. Keep checking at a bounded cadence.
            schedule.next = Date().addingTimeInterval(schedule.sizeOnly ? 60 : 3)
            pollSchedule[entry.id] = schedule
            return
        }
        do {
            let trace = DownloadPerformanceTrace.begin("Download Preparation Status")
            defer { DownloadPerformanceTrace.end("Download Preparation Status", trace) }
            let status = try await client.transcodeStatus(mediaID: entry.metadata.mediaID, compatiblePath: path)
            guard !Task.isCancelled, tasks[resource.transferID] === mediaTask, mediaTask.state == .running,
                  let current = owned(envelope), current.1.state == .running,
                  current.0.metadata.serverPath == path, DownloadOwnership.matches(entry.metadata, connection: connection) else { return }
            let produced = status.producedSeconds ?? (status.state == "ready" ? preparationProgress[entry.id]?.producedSeconds : nil)
            if let produced,
               let progress = DownloadPreparationProgress(producedSeconds: produced, durationSeconds: entry.metadata.durationSeconds,
                                                         isComplete: status.state == "ready") {
                if preparationProgress[entry.id] != progress { preparationProgress[entry.id] = progress }
            } else if status.state == "ready" {
                if preparationProgress[entry.id] != nil { preparationProgress.removeValue(forKey: entry.id) }
            }
            schedule.succeeded(retryHint: status.retryAfterSeconds)
            schedule.preparationComplete = status.state == "ready"
            if status.state == "ready", schedule.lengthAttempts < 3, finalMediaLengths[resource.transferID] == nil,
               DownloadProgressValues.expectedByteCount(reported: mediaTask.countOfBytesExpectedToReceive,
                                                        response: mediaTask.response) == nil {
                schedule.fetchFinalSize = true
                schedule.next = Date()
            }
        } catch {
            schedule.failed(error)
            if case RustyDLNAError.http(let code, _, _) = error, [404, 405, 501].contains(code),
               finalMediaLengths[resource.transferID] == nil,
               DownloadProgressValues.expectedByteCount(reported: mediaTask.countOfBytesExpectedToReceive,
                                                        response: mediaTask.response) == nil {
                schedule.sizeOnly = true
                schedule.fetchFinalSize = true
                schedule.next = Date().addingTimeInterval(15)
            }
        }
        pollSchedule[entry.id] = schedule
    }
    private func pollState(for entry: DownloadQueueEntry) -> DownloadPollSchedule {
        let transferID = entry.resources?.first { $0.resource.kind == .media }?.transferID
        if let state = pollSchedule[entry.id], state.transferID == transferID { return state }
        return DownloadPollSchedule(transferID: transferID)
    }
    private func cancelPreparedRequest(_ metadata: DownloadTaskMetadata) {
        guard metadata.kind == .compatible, let path = metadata.serverPath, let connection,
              DownloadOwnership.matches(metadata, connection: connection) else { return }
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(connection)
        Task {
            for attempt in 0..<3 {
                do { _ = try await client.cancelTranscode(mediaID: metadata.mediaID, compatiblePath: path); return }
                catch RustyDLNAError.authenticationFailed { return }
                catch RustyDLNAError.http(let status, _, _) where (400..<500).contains(status) && status != 408 && status != 429 { return }
                catch { guard attempt < 2 else { return }; try? await Task.sleep(for: .seconds(attempt == 0 ? 1 : 3)) }
            }
        }
    }
    deinit {
        poller?.cancel(); inventoryTask?.cancel(); network?.cancel()
        for observer in activityObservers { NotificationCenter.default.removeObserver(observer) }
    }
}

private struct DownloadPollSchedule {
    var transferID: UUID?
    var next = Date.distantPast
    var failures = 0
    var unsupported = false
    var fetchFinalSize = false
    var lengthAttempts = 0
    var sizeOnly = false
    var preparationComplete = false
    var needsWork: Bool { fetchFinalSize || (!unsupported && !preparationComplete) }
    mutating func succeeded(retryHint: UInt64?) {
        failures = 0
        next = Date().addingTimeInterval(max(3, min(60, Double(retryHint ?? 3))))
    }
    mutating func failed(_ error: Error) {
        if case RustyDLNAError.http(let status, _, _) = error, [404, 405, 501].contains(status) { unsupported = true }
        if case RustyDLNAError.authenticationFailed = error { unsupported = true }
        failures = min(5, failures + 1)
        next = Date().addingTimeInterval(min(60, pow(2, Double(failures))))
    }
}

private extension Optional {
    func flatMapAsync<T>(_ transform: (Wrapped) async throws -> T?) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
