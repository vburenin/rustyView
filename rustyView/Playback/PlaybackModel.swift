import AVFoundation
import Combine
import MediaPlayer
import UIKit

enum PlaybackMode: String, CaseIterable, Identifiable {
    case automatic
    case original
    case compatible
    case portable

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .original: "Original"
        case .compatible: "Compatible"
        case .portable: "Maximum Compatibility"
        }
    }
}

enum PlaybackAttempt: Equatable {
    case original
    case compatible
    case portable
}

enum PlaybackStartupAction: Equatable {
    case fallback(PlaybackAttempt)
    case retry
    case fail
}

enum PlaybackRouting {
    static func usesCompatibleStream(
        mode: PlaybackMode,
        quality: String,
        transcodeLikely: Bool
    ) -> Bool {
        switch mode {
        case .original:
            false
        case .compatible, .portable:
            true
        case .automatic:
            transcodeLikely || quality != "auto"
        }
    }

    static func attempt(
        mode: PlaybackMode,
        quality: String,
        transcodeLikely: Bool,
        selectedAudioIndex: Int? = nil,
        defaultAudioIndex: Int? = nil
    ) -> PlaybackAttempt {
        if mode == .portable { return .portable }
        if mode == .automatic,
           let selectedAudioIndex,
           let defaultAudioIndex,
           selectedAudioIndex != defaultAudioIndex {
            return .compatible
        }
        return usesCompatibleStream(mode: mode, quality: quality, transcodeLikely: transcodeLikely)
            ? .compatible
            : .original
    }

    static func nextFallback(after attempt: PlaybackAttempt, videoMode: String) -> PlaybackAttempt? {
        switch attempt {
        case .original:
            .compatible
        case .compatible where videoMode != "transcode":
            .portable
        case .compatible, .portable:
            nil
        }
    }

    static func startupAction(
        after attempt: PlaybackAttempt,
        videoMode: String,
        automaticFallbackEnabled: Bool,
        retryCount: Int
    ) -> PlaybackStartupAction {
        if automaticFallbackEnabled,
           let fallback = nextFallback(after: attempt, videoMode: videoMode) {
            return .fallback(fallback)
        }
        return retryCount < 1 ? .retry : .fail
    }
}

enum PlaybackTimeline {
    static func clampedTime(_ time: Double, duration: Double?) -> Double {
        let finiteTime = time.isFinite ? time : 0
        let lowerBounded = max(0, finiteTime)
        guard let duration, duration.isFinite, duration > 0 else { return lowerBounded }
        return min(lowerBounded, duration)
    }

    static func skipTarget(currentTime: Double, seconds: Double, duration: Double?) -> Double {
        clampedTime(currentTime + seconds, duration: duration)
    }

    static func progress(_ time: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(1, max(0, time / duration))
    }

    static func displayTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = max(0, Int(seconds))
        let hours = value / 3_600
        let minutes = (value % 3_600) / 60
        let remainingSeconds = value % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    static func localTime(forGlobalTime globalTime: Double, streamOffset: Double) -> Double? {
        let target = max(0, globalTime)
        let offset = max(0, streamOffset)
        guard target >= offset else { return nil }
        return target - offset
    }

    static func contains(
        _ time: Double,
        in ranges: [ClosedRange<Double>],
        tolerance: Double = 0.5
    ) -> Bool {
        guard time.isFinite else { return false }
        let tolerance = max(0, tolerance.isFinite ? tolerance : 0)
        return ranges.contains { range in
            time >= range.lowerBound - tolerance && time <= range.upperBound + tolerance
        }
    }

    static func activeChapterIndex(in chapters: [Chapter], at globalTime: Double) -> Int? {
        let time = max(0, globalTime)
        return chapters.first {
            time >= $0.startSeconds && time < $0.endSeconds
        }?.index
    }
}

@MainActor
final class PlaybackModel: ObservableObject {
    @Published private(set) var player = AVPlayer()
    @Published private(set) var item: MediaItem?
    @Published private(set) var movieMetadata: MovieMetadata?
    @Published private(set) var chapters: [MovieChapter] = []
    @Published private(set) var localAudioTracks: [LocalPlaybackTrack] = []
    @Published private(set) var localSubtitleTracks: [LocalPlaybackTrack] = []
    @Published private(set) var selectedLocalAudioID: String?
    @Published private(set) var selectedLocalSubtitleID: String?
    @Published private(set) var isLoadingLocalTracks = false
    @Published private(set) var currentTitle: String?
    @Published private(set) var isPresented = false
    @Published private(set) var isPreparing = false
    @Published var errorMessage: String?
    @Published private(set) var selectedAudioIndex: Int?
    @Published private(set) var selectedQuality = "auto"
    @Published private(set) var qualityNotice: String?
    @Published private(set) var qualityProfiles: [QualityProfile]?
    @Published private(set) var mode = PlaybackMode.automatic
    @Published private(set) var selectedCaptionIndex: Int?
    @Published private(set) var currentSubtitle: String?
    @Published private(set) var currentChapterIndex: Int?
    @Published var subtitleError: String?
    @Published private(set) var subtitleSelection = SubtitleSelectionState.off
    @Published private(set) var systemPlaybackNotice: String?
    @Published private(set) var mediaOutputPolicy = MediaOutputPolicy.native
    @Published private(set) var isExternalPlaybackActive = false
    @Published private(set) var isSystemInterrupted = false
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var bufferedTime = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var hasEnded = false
    @Published var playbackSpeed: Float = 1
    @Published var resizeMode = VideoResizeMode.fit
    @Published private(set) var transport = PlaybackTransportState()
    @Published private(set) var preparationMessage = "Preparing video…"
    @Published var requestError: String?
    @Published private(set) var isSavingStartOver = false
    @Published private(set) var isLoadingSavedPosition = false

    /// Changes for a new user request or Close, but not an internal recovery.
    var requestIdentity: UUID { startRequestID }
    var currentSourceURL: URL? { authenticatedAsset?.sourceURL ?? (player.currentItem?.asset as? AVURLAsset)?.url }

    private let client: RustyDLNAClient
    private let activityStore: any PlaybackActivityStore
    private let preferences: PlaybackPreferences
    private let system: PlaybackSystemController
    private var playerObservation: AnyCancellable?
    private var externalPlaybackObservation: AnyCancellable?
    private var interruptionResume: (viewingID: UUID, intentRevision: UInt64)?
    private var interruptedPendingRequest: UUID?
    private var userIntentRevision: UInt64 = 0
    private var lastNowPlayingSecond: Int?
    private var captionLoadTask: Task<[SubtitleCue], Error>?
    private var activityViewingID = UUID()
    private var activityStarted = false
    private var lastObservedPlaybackTime: Double?
    private var startRequestID = UUID()
    private var durableStartTask: Task<Void, Never>?
    private var currentSession = UUID()
    private var itemObservations: Set<AnyCancellable> = []
    private var lifetimeObservations: Set<AnyCancellable> = []
    private var timeObserver: Any?
    private var timeObserverPlayer: AVPlayer?
    private var subtitleCues: [SubtitleCue] = []
    private var streamOffset = 0.0
    private var lastProgressSave = 0.0
    private var activeServerOrigin: String?
    private var activeAccountUsername: String?
    private var activeMediaID: String?
    private var activeDuration = 0.0
    private var activeAttempt = PlaybackAttempt.original
    private var automaticFallbackEnabled = false
    private var authenticatedAsset: AuthenticatedMediaAsset?
    private var preparingAssetTask: Task<Void, Never>?
    private var startupWatchdog: Task<Void, Never>?
    private var startupRetryCount = 0
    private var viewingSession: PreparedPlaybackSession?
    private var localSource: (record: DownloadRecord, url: URL, captions: [LocalCaptionSource])?
    private var localTrackTask: Task<Void, Never>?
    private var localAudioGroup: AVMediaSelectionGroup?
    private var localLegibleGroup: AVMediaSelectionGroup?
    private var nativeAudioOptions: [String: AVMediaSelectionOption] = [:]
    private var nativeSubtitleOptions: [String: AVMediaSelectionOption] = [:]
    private var pendingSeek: Task<Void, Never>?
    private var pendingSeekID = UUID()
    private var pausedPlaybackFailure: String?
    private var progressWatchdog: PlaybackProgressWatchdog
    private let watchdogInterval: Duration
    private var captionRequest = UUID()
    private var isApplyingInitialSeek = false
    private var intent: PlaybackTransportState.Intent {
        get { transport.intent }
        set { transport.intent = newValue }
    }

    init(
        client: RustyDLNAClient,
        progressStore: PlaybackProgressStore = PlaybackProgressStore(),
        activityStore: (any PlaybackActivityStore)? = nil,
        preferences: PlaybackPreferences? = nil,
        systemController: PlaybackSystemController? = nil,
        progressTimeout: TimeInterval = 15,
        watchdogInterval: Duration = .seconds(1)
    ) {
        self.client = client
        self.activityStore = activityStore ?? LegacyPlaybackActivityAdapter(progressStore: progressStore)
        self.preferences = preferences ?? PlaybackPreferences()
        self.system = systemController ?? PlaybackSystemController()
        self.progressWatchdog = PlaybackProgressWatchdog(timeout: progressTimeout)
        self.watchdogInterval = watchdogInterval
        system.onEvent = { [weak self] in self?.handleSystemEvent($0) }
        system.onCommand = { [weak self] in self?.handleSystemCommand($0) }
        installTimeObserver()
        observePlayerState()
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveProgress(); self?.publishNowPlaying() }
            .store(in: &lifetimeObservations)
    }

    private func observePlayerState() {
        playerObservation = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.isPlaying = status == .playing
                self.isBuffering = self.canAdvance && status == .waitingToPlayAtSpecifiedRate && !self.isPreparing
                self.refreshTransportPhase()
                self.publishNowPlaying()
            }
        externalPlaybackObservation = player.publisher(for: \.isExternalPlaybackActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                guard let self else { return }
                self.isExternalPlaybackActive = active
                if active && self.requiresSubtitleOutputAcknowledgement {
                    self.pausePlayback()
                    self.systemPlaybackNotice = "Return playback here or turn subtitles off to continue on AirPlay."
                }
            }
    }

    func play(
        _ item: MediaItem,
        mode: PlaybackMode = .automatic,
        quality: String = "auto",
        audioIndex: Int? = nil,
        startAt explicitStart: Double? = nil,
        continuingAutomaticFallback: Bool = false,
        startupRetryCount: Int = 0,
        retainingViewingSession: Bool = false,
        preservingIntent: PlaybackTransportState.Intent? = nil,
        activityViewingID suppliedViewingID: UUID? = nil,
        qualityNotice: String? = nil,
        qualityProfiles: [QualityProfile]? = nil
    ) {
        if !retainingViewingSession && suppliedViewingID == nil { cancelPendingStart() }
        saveProgress()
        lastObservedPlaybackTime = nil
        preparingAssetTask?.cancel()
        preparingAssetTask = nil
        startupWatchdog?.cancel()
        pendingSeek?.cancel()
        pendingSeek = nil
        pendingSeekID = UUID()
        let sameItem = retainingViewingSession && self.item?.id == item.id && viewingSession != nil
        if !sameItem || suppliedViewingID != nil {
            activityViewingID = suppliedViewingID ?? UUID()
            activityStarted = false
        }
        if !sameItem {
            viewingSession?.cancelActive()
            viewingSession = nil
            self.qualityNotice = qualityNotice
            self.qualityProfiles = qualityProfiles
        }
        localSource = nil
        mediaOutputPolicy = .localRelay
        player.allowsExternalPlayback = false
        resetLocalTracks()
        movieMetadata = MovieMetadata(item: item)
        chapters = movieMetadata?.chapters ?? []
        pausedPlaybackFailure = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        authenticatedAsset?.stop()
        authenticatedAsset = nil
        isApplyingInitialSeek = false
        currentSession = UUID()
        let session = currentSession
        self.item = item
        transport = PlaybackTransportState(intent: preservingIntent ?? .playing)
        currentTitle = item.displayTitle
        self.mode = mode
        automaticFallbackEnabled = mode == .automatic || continuingAutomaticFallback
        self.startupRetryCount = startupRetryCount
        transport.recoveryAttempt = startupRetryCount
        preparationMessage = startupRetryCount > 0 ? "Reconnecting video…" : "Preparing video…"
        selectedQuality = quality
        selectedAudioIndex = audioIndex ?? item.defaultAudioIndex
        errorMessage = nil
        isPreparing = true
        isPresented = true
        activeServerOrigin = viewingSession?.client.connection?.serverIdentity ?? client.connection?.serverIdentity
        activeAccountUsername = viewingSession?.client.connection?.username ?? client.connection?.username
        activeMediaID = item.id
        activeDuration = Double(item.durationSeconds ?? 0)
        duration = activeDuration
        currentTime = 0
        bufferedTime = 0
        hasEnded = false
        if !sameItem {
            clearSubtitleSelection()
        }

        let savedPosition = activeLibraryKey.flatMap { activityStore.resumePosition(for: $0) }
        let startPosition = PlaybackTimeline.clampedTime(explicitStart ?? savedPosition ?? 0, duration: activeDuration)
        currentTime = startPosition
        streamOffset = 0
        currentChapterIndex = PlaybackTimeline.activeChapterIndex(
            in: item.chapters,
            at: startPosition
        )

        do {
            try activateAudioSession()
            if viewingSession == nil { viewingSession = try PreparedPlaybackSession(client: client, mediaID: item.id) }
            guard let viewingSession else { throw RustyDLNAError.notConfigured }
            let path: String
            let attempt = PlaybackRouting.attempt(
                mode: mode,
                quality: quality,
                transcodeLikely: item.transcodeLikely,
                selectedAudioIndex: selectedAudioIndex,
                defaultAudioIndex: item.defaultAudioIndex
            )
            activeAttempt = attempt
            transport.attempt = attempt
            transport.phase = .preparing
            if attempt != .original {
                path = viewingSession.prepare(
                    item: item,
                    quality: quality,
                    audioIndex: selectedAudioIndex,
                    startSeconds: Int(startPosition),
                    forceVideoTranscode: attempt == .portable
                )
            } else {
                viewingSession.cancelActive()
                path = item.sourceURL + (item.sourceURL.contains("?") ? "&" : "?") + "reason=native_ios"
            }
            let usesCompatibleStream = attempt != .original
            streamOffset = usesCompatibleStream ? Double(Int(startPosition)) : 0
            publishNowPlaying()
            scheduleStartupWatchdog(session: session)
            preparingAssetTask = Task { [weak self] in
                do {
                    let asset = try await viewingSession.client.asset(serverPath: path)
                    guard let self, self.currentSession == session, self.isPresented, !Task.isCancelled else {
                        asset.stop()
                        return
                    }
                    self.preparingAssetTask = nil
                    self.authenticatedAsset = asset
                    self.mediaOutputPolicy = asset.outputPolicy
                    self.player.allowsExternalPlayback = asset.outputPolicy.allowsExternalPlayback
                    let attemptID = asset.attemptID
                    asset.onFailure = { [weak self] failure in
                        guard let self, self.currentSession == session, self.authenticatedAsset?.attemptID == attemptID else { return }
                        self.finishWithFailure(failure.message)
                    }
                    if let rejection = asset.rejection, rejection.category == .transportSecurity {
                        self.finishWithFailure(rejection.message)
                        return
                    }
                    let playerItem = AVPlayerItem(asset: asset.asset)
                    self.observe(playerItem, session: session, initialSeek: usesCompatibleStream ? nil : self.currentTime)
                    self.player.replaceCurrentItem(with: playerItem)
                    self.loadLocalTracks(playerItem, session: session)
                    self.publishNowPlaying()
                    self.player.defaultRate = self.playbackSpeed
                    if self.canAdvance { self.player.playImmediately(atRate: self.playbackSpeed) }
                } catch {
                    guard let self, self.currentSession == session, !Task.isCancelled else { return }
                    self.preparingAssetTask = nil
                    self.finishWithFailure(UserFacingError(error).message)
                }
            }
        } catch {
            finishWithFailure(error.localizedDescription)
        }
    }

    func play(_ request: PlaybackRequest) {
        durableStartTask?.cancel()
        startRequestID = UUID()
        interruptedPendingRequest = isSystemInterrupted ? startRequestID : nil
        requestError = nil
        isSavingStartOver = false
        isLoadingSavedPosition = false
        guard owns(request) else {
            requestError = "The connection changed. Open this movie from the current library to watch online."
            if !isPresented { errorMessage = requestError }
            return
        }
        let viewingID = UUID()
        if request.start == .startOver {
            saveProgress()
            let requestID = startRequestID
            let activity = activity(for: request, viewingID: viewingID, event: .startedOver)
            isSavingStartOver = true
            durableStartTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.activityStore.commit(activity)
                    guard self.startRequestID == requestID, !Task.isCancelled, self.owns(request) else { return }
                    self.isSavingStartOver = false
                    self.perform(request, viewingID: viewingID)
                } catch {
                    guard self.startRequestID == requestID, !Task.isCancelled else { return }
                    self.isSavingStartOver = false
                    self.requestError = "Could not save Start Over. Your current playback and saved position are unchanged. \(error.localizedDescription)"
                }
            }
        } else if request.start == .resume && activityStore.isRestoring {
            let requestID = startRequestID
            isLoadingSavedPosition = true
            durableStartTask = Task { [weak self] in
                guard let self else { return }
                await self.activityStore.waitUntilRestored()
                guard self.startRequestID == requestID, !Task.isCancelled, self.owns(request) else { return }
                self.isLoadingSavedPosition = false
                self.perform(request, viewingID: viewingID)
            }
        } else {
            perform(request, viewingID: viewingID)
        }
    }

    private func owns(_ request: PlaybackRequest) -> Bool {
        guard case .online(_, let connection) = request.source else { return true }
        return client.connection?.serverIdentity == connection.serverIdentity && client.connection?.username == connection.username
    }

    private func perform(_ request: PlaybackRequest, viewingID: UUID) {
        let requestedIntent: PlaybackTransportState.Intent = interruptedPendingRequest == startRequestID ? .paused : .playing
        if requestedIntent == .playing && !isSystemInterrupted { systemPlaybackNotice = nil }
        switch request.source {
        case .online(let item, _):
            play(item, quality: request.quality, audioIndex: request.audioIndex ?? preferences.audioIndex(in: item),
                 startAt: request.start.explicitPosition, preservingIntent: requestedIntent, activityViewingID: viewingID,
                 qualityNotice: request.qualityNotice, qualityProfiles: request.qualityProfiles)
        case .offline(let record, let url, let captions):
            playLocal(record: record, url: url, captionSources: captions, startAt: request.start.explicitPosition,
                      preservingIntent: requestedIntent, activityViewingID: viewingID)
        }
    }

    var isOfflinePlayback: Bool { localSource != nil }
    var offlineAudioDescription: String? { localSource?.record.audioSelectionDescription }

    func retryCompatible() {
        guard let item, let nextAttempt = PlaybackRouting.nextFallback(
            after: activeAttempt,
            videoMode: PlaybackCompatibility.videoMode(for: item)
        ) else { return }
        play(
            item,
            mode: nextAttempt == .portable ? .portable : .compatible,
            quality: selectedQuality,
            audioIndex: selectedAudioIndex,
            startAt: globalTime,
            retainingViewingSession: true,
            preservingIntent: intent
        )
    }

    func retryCurrentPlayback() {
        let position = globalTime
        let retainedIntent = intent
        if let item {
            play(
                item, mode: mode, quality: selectedQuality, audioIndex: selectedAudioIndex,
                startAt: position, continuingAutomaticFallback: automaticFallbackEnabled,
                retainingViewingSession: true, preservingIntent: retainedIntent
            )
        } else if let localSource {
            playLocal(record: localSource.record, url: localSource.url, captionSources: localSource.captions,
                      startAt: position, preservingIntent: retainedIntent, retainingViewingID: true)
        }
    }

    @discardableResult
    func applyStreamingChanges(_ draft: StreamingSettingsDraft, profiles: [QualityProfile]) -> Bool {
        guard draft.isValid(in: profiles), let item else { return false }
        preferences.preferredQualityID = draft.quality
        qualityNotice = nil
        play(item, mode: draft.mode, quality: draft.quality, audioIndex: selectedAudioIndex, startAt: globalTime,
             retainingViewingSession: true, preservingIntent: intent)
        return true
    }

    var retryLabel: String? {
        guard let item, let attempt = PlaybackRouting.nextFallback(
            after: activeAttempt,
            videoMode: PlaybackCompatibility.videoMode(for: item)
        ) else { return nil }
        return attempt == .portable ? "Try Maximum Compatibility" : "Try Compatible Playback"
    }

    func selectAudio(_ index: Int) {
        guard let item, index != selectedAudioIndex else { return }
        let position = globalTime
        saveProgress()
        selectedAudioIndex = index
        preferences.preferredAudioLanguage = item.audioTracks.first { $0.index == index }?.language
        let selectedMode: PlaybackMode = activeAttempt == .portable ? .portable : .compatible
        play(
            item,
            mode: selectedMode,
            quality: selectedQuality,
            audioIndex: index,
            startAt: position,
            continuingAutomaticFallback: true,
            retainingViewingSession: true,
            preservingIntent: intent
        )
    }

    func togglePlayback() {
        if errorMessage != nil {
            retryCurrentPlayback()
        } else if hasEnded {
            resumePlayback()
        } else if intent == .playing {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    private func pausePlayback() {
        userIntentRevision &+= 1
        intent = .paused
        player.pause()
        isBuffering = false
        progressWatchdog.reset()
        lastObservedPlaybackTime = nil
        refreshTransportPhase()
        saveProgress()
        publishNowPlaying()
    }

    private func resumePlayback(userInitiated: Bool = true) {
        if userInitiated { userIntentRevision &+= 1; systemPlaybackNotice = nil }
        intent = .playing
        progressWatchdog.reset()
        guard !isSystemInterrupted else { player.pause(); refreshTransportPhase(); publishNowPlaying(); return }
        if let pausedPlaybackFailure {
            handlePlaybackFailure(pausedPlaybackFailure, session: currentSession)
            return
        }
        if hasEnded {
            restartAfterEnd()
        } else {
            do {
                try activateAudioSession()
            } catch {
                finishWithFailure(error.localizedDescription)
                return
            }
            player.playImmediately(atRate: playbackSpeed)
        }
        refreshTransportPhase()
        publishNowPlaying()
        scheduleStartupWatchdog(session: currentSession)
    }

    func setPlaybackSpeed(_ speed: Float) {
        guard speed.isFinite, speed >= 0.25, speed <= 2 else { return }
        playbackSpeed = speed
        player.defaultRate = speed
        if canAdvance && (isPlaying || player.rate > 0) {
            player.rate = speed
        }
        publishNowPlaying()
    }

    @discardableResult
    func skip(by seconds: Double) -> Double {
        let target = PlaybackTimeline.skipTarget(
            currentTime: globalTime,
            seconds: seconds,
            duration: duration > 0 ? duration : nil
        )
        seek(toGlobalTime: target)
        return target
    }

    func seek(toGlobalTime target: Double) {
        lastObservedPlaybackTime = nil
        let target = PlaybackTimeline.clampedTime(target, duration: duration > 0 ? duration : nil)
        pendingSeek?.cancel()
        pendingSeek = nil
        pendingSeekID = UUID()
        hasEnded = false
        currentTime = target
        publishNowPlaying()
        progressWatchdog.reset()
        if let localTime = PlaybackTimeline.localTime(
            forGlobalTime: target,
            streamOffset: streamOffset
        ), canSeekLocally(to: localTime) {
            guard player.currentItem?.status == .readyToPlay else {
                // Retain the new target for the readiness callback. Issuing an
                // early seek and a saved-position seek concurrently lets their
                // completions race even when they refer to the same item.
                transport.phase = .seeking
                updateSubtitle(at: target)
                updateChapter(at: target)
                return
            }
            let seekID = pendingSeekID
            let session = currentSession
            isApplyingInitialSeek = true
            transport.phase = .seeking
            player.seek(
                to: CMTime(seconds: localTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.currentSession == session, self.pendingSeekID == seekID else { return }
                    self.isApplyingInitialSeek = false
                    self.progressWatchdog.reset()
                    if self.canAdvance { self.player.playImmediately(atRate: self.playbackSpeed) }
                    else { self.player.pause() }
                    self.refreshTransportPhase()
                    self.publishNowPlaying()
                }
            }
            updateSubtitle(at: max(0, target))
            updateChapter(at: max(0, target))
            return
        }
        guard let item else { return }
        player.pause()
        viewingSession?.cancelActive()
        transport.phase = .seeking
        updateSubtitle(at: target)
        updateChapter(at: target)
        let seekID = pendingSeekID
        pendingSeek = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.pendingSeekID == seekID else { return }
            self.play(
                item, mode: self.mode, quality: self.selectedQuality,
                audioIndex: self.selectedAudioIndex, startAt: target,
                continuingAutomaticFallback: self.automaticFallbackEnabled,
                retainingViewingSession: true, preservingIntent: self.intent
            )
        }
    }

    func selectCaption(_ index: Int?) async {
        await selectSubtitle(id: index.map { "server-\($0)" })
    }

    var subtitleOptions: [PlaybackSubtitleOption] {
        let serverOptions = (item?.captions ?? []).map {
            PlaybackSubtitleOption(selection: .init(id: "server-\($0.index)", label: $0.label, delivery: .appOverlay),
                source: .server(index: $0.index), language: $0.language, isForced: false, isAvailable: $0.isPlayableOnDevice)
        }
        let nativeOptions = localSubtitleTracks.compactMap { track -> PlaybackSubtitleOption? in
            if nativeSubtitleOptions[track.id] != nil {
                return PlaybackSubtitleOption(selection: .init(id: track.id, label: track.title, delivery: .native),
                    source: .native(optionID: track.id), language: track.language, isForced: track.isForced, isAvailable: true)
            }
            guard let id = UUID(uuidString: track.id), localSource?.captions.contains(where: { $0.id == id }) == true else { return nil }
            return PlaybackSubtitleOption(selection: .init(id: track.id, label: track.title, delivery: .appOverlay),
                source: .offline(captionID: id), language: track.language, isForced: track.isForced, isAvailable: true)
        }
        return serverOptions + nativeOptions
    }

    var subtitleOutputNotice: String? {
        guard subtitleSelection.requested?.delivery == .appOverlay else { return nil }
        return "These subtitles aren’t available in Picture in Picture or AirPlay video."
    }

    var requiresSubtitleOutputAcknowledgement: Bool { subtitleSelection.requested?.delivery == .appOverlay }

    func turnSubtitlesOff() { clearSubtitleSelection() }

    func retrySubtitles() async {
        guard case .failed(let requested, _) = subtitleSelection else { return }
        await selectSubtitle(id: requested.id)
    }

    func selectSubtitle(id: String?) async {
        guard let id else { clearSubtitleSelection(); return }
        guard let option = subtitleOptions.first(where: { $0.id == id }) else {
            if let requested = subtitleSelection.requested {
                failSubtitle(requested, message: "This playback format does not include that subtitle. Choose an available subtitle or return to Original playback.")
            }
            return
        }
        clearSubtitleSelection()
        let request = captionRequest
        let viewingID = activityViewingID
        subtitleSelection = .loading(option.selection)
        guard option.isAvailable else {
            failSubtitle(option.selection, message: "This subtitle cannot be shown on this device. Choose another subtitle.")
            return
        }
        if case .native(let optionID) = option.source {
            guard let group = localLegibleGroup, let selected = nativeSubtitleOptions[optionID], let current = player.currentItem else {
                failSubtitle(option.selection, message: "This playback format does not include that subtitle. Choose an available subtitle.")
                return
            }
            current.select(selected, in: group)
            guard current.currentMediaSelection.selectedMediaOption(in: group) == selected else {
                failSubtitle(option.selection, message: "The movie could not enable that subtitle. Choose another subtitle or retry.")
                return
            }
            selectedLocalSubtitleID = optionID
            subtitleSelection = .active(option.selection)
            return
        }
        do {
            let task: Task<[SubtitleCue], Error>
            switch option.source {
            case .server(let index):
                guard let path = item?.captions.first(where: { $0.index == index })?.url else { throw SubtitleError.invalidFormat }
                let owner = try (viewingSession?.client ?? client).ownedConnection()
                task = Task {
                    let data = try await owner.data(serverPath: path)
                    try Task.checkCancellation()
                    return try await Task.detached(priority: .userInitiated) { try WebVTTParser.parse(data) }.value
                }
            case .offline(let captionID):
                guard let url = localSource?.captions.first(where: { $0.id == captionID })?.url, url.isFileURL else { throw SubtitleError.invalidFormat }
                task = Task.detached(priority: .userInitiated) { try WebVTTParser.parse(Data(contentsOf: url)) }
            case .native: return
            }
            captionLoadTask = task
            let cues = try await task.value
            guard request == captionRequest, viewingID == activityViewingID, !Task.isCancelled else { return }
            captionLoadTask = nil
            subtitleCues = cues
            subtitleSelection = .active(option.selection)
            switch option.source {
            case .server(let index): selectedCaptionIndex = index
            case .offline(let id): selectedLocalSubtitleID = id.uuidString
            case .native: break
            }
            updateSubtitle(at: globalTime)
            if isExternalPlaybackActive {
                pausePlayback()
                systemPlaybackNotice = "Return playback here or turn subtitles off to continue on AirPlay."
            }
        } catch {
            guard request == captionRequest, viewingID == activityViewingID, !Task.isCancelled else { return }
            captionLoadTask = nil
            let message = (error is SubtitleError) ? error.localizedDescription : UserFacingError(error).message
            failSubtitle(option.selection, message: message)
        }
    }

    private func failSubtitle(_ selection: SubtitleSelection, message: String) {
        subtitleSelection = .failed(selection, message: message)
        subtitleError = message
        selectedCaptionIndex = nil
        selectedLocalSubtitleID = nil
        currentSubtitle = nil
    }

    private func clearSubtitleSelection() {
        captionLoadTask?.cancel(); captionLoadTask = nil
        captionRequest = UUID()
        selectedCaptionIndex = nil
        selectedLocalSubtitleID = nil
        subtitleCues = []
        currentSubtitle = nil
        subtitleError = nil
        subtitleSelection = .off
        if let group = localLegibleGroup { player.currentItem?.select(nil, in: group) }
    }

    func resumePosition(for item: MediaItem) -> Double? {
        guard let origin = client.connection?.serverIdentity else { return nil }
        return activityStore.resumePosition(for: MovieLibraryKey(serverIdentity: origin, accountUsername: client.connection?.username, mediaID: item.id))
    }

    func resumePosition(for record: DownloadRecord) -> Double? {
        guard let position = activityStore.resumePosition(for: MovieLibraryKey(serverIdentity: record.serverOrigin,
                    accountUsername: record.accountUsername, mediaID: record.mediaID)) else { return nil }
        if let duration = record.assetInspection?.durationSeconds, duration.isFinite, duration > 0 {
            // A position saved from the online catalog may not fit this actual
            // file. Apply the existing end exclusion to the inspected duration
            // before offering Resume, just as playback uses that duration.
            guard ResumePolicy.resumePosition(position: position, duration: duration) != nil else { return nil }
        }
        return position
    }

    func playLocal(
        record: DownloadRecord,
        url: URL,
        captionSources: [LocalCaptionSource] = [],
        startAt: Double? = nil,
        preservingIntent: PlaybackTransportState.Intent? = nil,
        retainingViewingID: Bool = false,
        activityViewingID suppliedViewingID: UUID? = nil
    ) {
        if !retainingViewingID && suppliedViewingID == nil { cancelPendingStart() }
        preparingAssetTask?.cancel()
        preparingAssetTask = nil
        saveProgress()
        if !retainingViewingID {
            activityViewingID = suppliedViewingID ?? UUID()
            activityStarted = false
        }
        lastObservedPlaybackTime = nil
        viewingSession?.cancelActive()
        viewingSession = nil
        let retainedAudioID = retainingViewingID ? selectedLocalAudioID : nil
        pendingSeek?.cancel()
        pendingSeek = nil
        pendingSeekID = UUID()
        resetLocalTracks()
        localSource = (record, url, captionSources)
        qualityNotice = nil
        qualityProfiles = nil
        movieMetadata = record.movieMetadata
        chapters = record.movieMetadata.chapters
        pausedPlaybackFailure = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        transport = PlaybackTransportState(intent: preservingIntent ?? .playing, phase: .preparing)
        startupRetryCount = 0
        startupWatchdog?.cancel()
        authenticatedAsset?.stop()
        authenticatedAsset = nil
        activeAttempt = .original
        automaticFallbackEnabled = false
        isApplyingInitialSeek = false
        if !retainingViewingID { clearSubtitleSelection() }
        selectedAudioIndex = nil
        currentSession = UUID()
        item = nil
        mode = .original
        errorMessage = nil
        isPreparing = true
        isPresented = true
        streamOffset = 0
        currentChapterIndex = nil
        activeServerOrigin = record.serverOrigin
        activeAccountUsername = record.accountUsername
        activeMediaID = record.mediaID
        if let inspectedDuration = record.assetInspection?.durationSeconds,
           inspectedDuration.isFinite, inspectedDuration > 0 {
            activeDuration = inspectedDuration
        } else {
            activeDuration = Double(record.durationSeconds ?? 0)
        }
        duration = activeDuration
        currentTime = 0
        bufferedTime = 0
        hasEnded = false
        currentTitle = record.displayTitle
        let savedPosition = startAt ?? resumePosition(for: record)
        let target = PlaybackTimeline.clampedTime(savedPosition ?? 0, duration: activeDuration)
        // A stale source duration can leave a saved position beyond the actual
        // downloaded asset. Start that copy at its beginning instead of seeking
        // to an impossible end and appearing stuck.
        let resume = activeDuration > 0 && target >= activeDuration ? 0 : target
        currentTime = resume
        do { try activateAudioSession() } catch {
            player.pause()
            player.replaceCurrentItem(with: nil)
            finishWithFailure(error.localizedDescription)
            return
        }
        guard url.isFileURL else {
            finishWithFailure("This offline copy does not have a valid local file. Download it again from movie details.")
            return
        }
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        ])
        mediaOutputPolicy = .native
        player.allowsExternalPlayback = true
        let playerItem = AVPlayerItem(asset: asset)
        observe(playerItem, session: currentSession, initialSeek: resume)
        player.replaceCurrentItem(with: playerItem)
        loadLocalTracks(playerItem, session: currentSession, retainedAudioID: retainedAudioID)
        publishNowPlaying()
        player.defaultRate = playbackSpeed
        if canAdvance { player.playImmediately(atRate: playbackSpeed) }
        scheduleStartupWatchdog(session: currentSession)
    }

    func selectLocalAudio(_ id: String) {
        guard let group = localAudioGroup, let option = nativeAudioOptions[id], let playerItem = player.currentItem else { return }
        playerItem.select(option, in: group)
        selectedLocalAudioID = id
        preferences.preferredAudioLanguage = option.extendedLanguageTag ?? option.locale?.identifier
    }

    func selectLocalSubtitle(_ id: String?) async {
        await selectSubtitle(id: id)
    }

    private func resetLocalTracks() {
        localTrackTask?.cancel()
        localTrackTask = nil
        localAudioGroup = nil
        localLegibleGroup = nil
        nativeAudioOptions = [:]
        nativeSubtitleOptions = [:]
        localAudioTracks = []
        localSubtitleTracks = []
        selectedLocalAudioID = nil
        selectedLocalSubtitleID = nil
        isLoadingLocalTracks = false
    }

    private func loadLocalTracks(_ playerItem: AVPlayerItem, session: UUID, retainedAudioID: String? = nil) {
        isLoadingLocalTracks = true
        localTrackTask = Task { [weak self, weak playerItem] in
            guard let playerItem else { return }
            let audio = try? await playerItem.asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await playerItem.asset.loadMediaSelectionGroup(for: .legible)
            guard let self, self.currentSession == session, !Task.isCancelled else { return }
            self.localAudioGroup = audio
            self.localLegibleGroup = legible
            func descriptors(_ group: AVMediaSelectionGroup?, prefix: String) -> ([LocalPlaybackTrack], [String: AVMediaSelectionOption]) {
                var options: [String: AVMediaSelectionOption] = [:]
                let tracks = (group?.options ?? []).enumerated().map { index, option in
                    let id = "\(prefix)-\(index)"
                    options[id] = option
                    return LocalPlaybackTrack(id: id, title: option.displayName,
                        language: option.extendedLanguageTag ?? option.locale?.identifier,
                        isDefault: option == group?.defaultOption,
                        isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles))
                }
                return (tracks, options)
            }
            (self.localAudioTracks, self.nativeAudioOptions) = descriptors(audio, prefix: "audio")
            (self.localSubtitleTracks, self.nativeSubtitleOptions) = descriptors(legible, prefix: "subtitle")
            if let audio, self.localSource != nil {
                // AVFoundation applies the user's language and accessibility
                // preferences. Read its actual selection instead of mapping a
                // source-server ordinal onto the downloaded file.
                playerItem.selectMediaOptionAutomatically(in: audio)
                if let retainedAudioID, let selected = self.nativeAudioOptions[retainedAudioID] {
                    playerItem.select(selected, in: audio)
                } else if let language = self.preferences.preferredAudioLanguage,
                   let preferred = audio.options.first(where: { PlaybackLanguage.matches($0.extendedLanguageTag ?? $0.locale?.identifier, language) }) {
                    playerItem.select(preferred, in: audio)
                }
                let selected = playerItem.currentMediaSelection.selectedMediaOption(in: audio)
                self.selectedLocalAudioID = self.nativeAudioOptions.first { $0.value == selected }?.key
            }
            if let legible { playerItem.select(nil, in: legible) }
            self.localSubtitleTracks += (self.localSource?.captions ?? []).map {
                LocalPlaybackTrack(id: $0.id.uuidString, title: $0.caption.label, language: $0.caption.language,
                                   isDefault: $0.caption.isDefault, isForced: $0.caption.isForced == true)
            }
            self.isLoadingLocalTracks = false
            if let requested = self.subtitleSelection.requested, requested.delivery == .native {
                if self.subtitleOptions.contains(where: { $0.id == requested.id && $0.selection.label == requested.label }) {
                    await self.selectSubtitle(id: requested.id)
                } else {
                    self.failSubtitle(requested, message: "This playback format does not include that subtitle. Choose another subtitle or return to Original playback.")
                }
            } else if case .active(let selected) = self.subtitleSelection,
                      self.localSource?.captions.contains(where: { $0.id.uuidString == selected.id }) == true {
                self.selectedLocalSubtitleID = selected.id
            }
            guard self.currentSession == session, !Task.isCancelled else { return }
            if self.chapters.isEmpty {
                let groups = (try? await playerItem.asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)) ?? []
                var loaded: [MovieChapter] = []
                for (index, group) in groups.enumerated() {
                    let titleItem = group.items.first { $0.commonKey == .commonKeyTitle }
                    let title = try? await titleItem?.load(.stringValue)
                    loaded.append(MovieChapter(id: index, title: title ?? "Chapter \(index + 1)",
                                               startSeconds: group.timeRange.start.seconds,
                                               endSeconds: CMTimeRangeGetEnd(group.timeRange).seconds))
                }
                guard self.currentSession == session, !Task.isCancelled else { return }
                self.chapters = loaded
            }
        }
    }

    func stop() {
        preparingAssetTask?.cancel()
        preparingAssetTask = nil
        cancelPendingStart()
        saveProgress()
        interruptionResume = nil
        systemPlaybackNotice = nil
        clearSubtitleSelection()
        lastObservedPlaybackTime = nil
        viewingSession?.cancelActive()
        viewingSession = nil
        localSource = nil
        resetLocalTracks()
        movieMetadata = nil
        chapters = []
        qualityNotice = nil
        qualityProfiles = nil
        pausedPlaybackFailure = nil
        pendingSeek?.cancel()
        pendingSeek = nil
        pendingSeekID = UUID()
        transport = PlaybackTransportState()
        activeServerOrigin = nil
        activeAccountUsername = nil
        activeMediaID = nil
        activeDuration = 0
        streamOffset = 0
        lastProgressSave = 0
        isApplyingInitialSeek = false
        captionRequest = UUID()
        currentSession = UUID()
        player.pause()
        player.replaceCurrentItem(with: nil)
        authenticatedAsset?.stop()
        authenticatedAsset = nil
        startupWatchdog?.cancel()
        itemObservations.removeAll()
        item = nil
        currentTitle = nil
        isPresented = false
        isPreparing = false
        errorMessage = nil
        selectedCaptionIndex = nil
        subtitleCues = []
        currentSubtitle = nil
        currentChapterIndex = nil
        currentTime = 0
        duration = 0
        bufferedTime = 0
        isPlaying = false
        isBuffering = false
        hasEnded = false
        system.release()
        lastNowPlayingSecond = nil
    }

    private func observe(_ playerItem: AVPlayerItem, session: UUID, initialSeek: Double? = nil) {
        itemObservations.removeAll()
        let initialSeekID = pendingSeekID
        playerItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak playerItem] status in
                guard let self, self.currentSession == session else { return }
                switch status {
                case .readyToPlay:
                    self.isPreparing = false
                    self.isBuffering = self.canAdvance && self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    self.refreshTransportPhase()
                    let itemDuration = playerItem?.duration.seconds ?? 0
                    if self.activeAttempt == .original, itemDuration.isFinite, itemDuration > 0 {
                        self.duration = itemDuration + self.streamOffset
                        self.activeDuration = self.duration
                    }
                    self.publishNowPlaying()
                    if let initialSeek {
                        let desiredTime = self.pendingSeekID == initialSeekID ? initialSeek : self.currentTime
                        guard desiredTime > 0 else { return }
                        let seekID = self.pendingSeekID
                        self.isApplyingInitialSeek = true
                        self.player.seek(to: CMTime(seconds: desiredTime, preferredTimescale: 600)) { [weak self] _ in
                            Task { @MainActor in
                                guard let self, self.currentSession == session, self.pendingSeekID == seekID else { return }
                                self.isApplyingInitialSeek = false
                                self.progressWatchdog.reset()
                                self.refreshTransportPhase()
                                self.publishNowPlaying()
                            }
                        }
                    }
                case .failed:
                    self.handlePlaybackFailure(
                        playerItem?.error?.localizedDescription ?? "This video could not be played.",
                        session: session
                    )
                default:
                    break
                }
            }
            .store(in: &itemObservations)
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, self.currentSession == session else { return }
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self.handlePlaybackFailure(
                    error?.localizedDescription ?? "Playback stopped unexpectedly.",
                    session: session
                )
            }
            .store(in: &itemObservations)
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.currentSession == session else { return }
                self.emitActivity(.completed(position: self.globalTime, duration: self.activeDuration))
                self.hasEnded = true
                self.intent = .paused
                self.isPlaying = false
                self.isBuffering = false
                self.transport.phase = .ended
                self.startupWatchdog?.cancel()
                self.viewingSession?.cancelActive()
                self.publishNowPlaying()
            }
            .store(in: &itemObservations)
    }

    private func restartAfterEnd() {
        activityViewingID = UUID()
        activityStarted = false
        lastObservedPlaybackTime = nil
        hasEnded = false
        if activeAttempt != .original, let item {
            play(
                item,
                mode: mode,
                quality: selectedQuality,
                audioIndex: selectedAudioIndex,
                startAt: 0,
                continuingAutomaticFallback: automaticFallbackEnabled,
                retainingViewingSession: true,
                preservingIntent: .playing
            )
            return
        }
        currentTime = 0
        let session = currentSession
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor [weak self] in
                guard let self, self.currentSession == session else { return }
                if self.canAdvance { self.player.playImmediately(atRate: self.playbackSpeed) }
                else { self.player.pause() }
                self.publishNowPlaying()
                self.scheduleStartupWatchdog(session: session)
            }
        }
    }

    private func activateAudioSession() throws {
        system.claim()
        if canAdvance { try system.activate() }
    }

    private var canAdvance: Bool { intent == .playing && !isSystemInterrupted }

    private func handleSystemCommand(_ command: PlaybackSystemCommand) {
        guard isPresented, currentTitle != nil else { return }
        switch command {
        case .play: resumePlayback()
        case .pause: pausePlayback()
        case .toggle: togglePlayback()
        case .skip(let seconds): guard duration > 0, seconds.isFinite else { return }; skip(by: seconds)
        case .seek(let seconds): guard duration > 0, seconds.isFinite else { return }; seek(toGlobalTime: seconds)
        }
    }

    private func handleSystemEvent(_ event: PlaybackSystemEvent) {
        switch event {
        case .interruptionBegan:
            if !isSystemInterrupted {
                interruptionResume = isPresented && intent == .playing ? (activityViewingID, userIntentRevision) : nil
            }
            isSystemInterrupted = true
            if isSavingStartOver || isLoadingSavedPosition { interruptedPendingRequest = startRequestID }
            guard isPresented else { return }
            saveProgress()
            currentTime = globalTime
            player.pause()
            startupWatchdog?.cancel()
            progressWatchdog.reset()
            lastObservedPlaybackTime = nil
            isBuffering = false
            systemPlaybackNotice = "Playback is paused by another audio session."
            refreshTransportPhase()
            publishNowPlaying()
        case .interruptionEnded(let shouldResume):
            guard isSystemInterrupted else { return }
            isSystemInterrupted = false
            let candidate = interruptionResume
            interruptionResume = nil
            guard isPresented else { return }
            if shouldResume, let candidate, candidate.viewingID == activityViewingID,
               candidate.intentRevision == userIntentRevision, intent == .playing,
               !isSavingStartOver, !isLoadingSavedPosition {
                systemPlaybackNotice = nil
                resumePlayback(userInitiated: false)
                scheduleStartupWatchdog(session: currentSession)
            } else {
                intent = .paused
                player.pause()
                systemPlaybackNotice = "Playback was interrupted. Tap Play when you are ready."
                refreshTransportPhase()
                publishNowPlaying()
            }
        case .routeDisconnected:
            guard isPresented else { return }
            interruptionResume = nil
            pausePlayback()
            systemPlaybackNotice = "Your audio device disconnected. Tap Play to use the current output."
        case .mediaServicesLost:
            guard isPresented else { return }
            pausePlayback()
            startupWatchdog?.cancel()
            systemPlaybackNotice = "Audio services are temporarily unavailable. Playback will stay paused."
        case .mediaServicesReset:
            rebuildAfterMediaServicesReset()
        }
    }

    private func rebuildAfterMediaServicesReset() {
        let hadPresentedMovie = isPresented
        let pendingRequest = isSavingStartOver || isLoadingSavedPosition
        if pendingRequest { interruptedPendingRequest = startRequestID }
        let position = globalTime
        saveProgress()
        interruptionResume = nil
        userIntentRevision &+= 1
        intent = .paused
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        playerObservation = nil
        externalPlaybackObservation = nil
        itemObservations.removeAll()
        currentSession = UUID()
        player = AVPlayer()
        observePlayerState()
        installTimeObserver()
        if pendingRequest || hadPresentedMovie {
            systemPlaybackNotice = "Audio services restarted. Tap Play to continue from your saved place."
        }
        // Even a held initial Resume owns an AVPlayer created before the
        // reset. Replace that object before its delayed store result attaches
        // media, and require a new explicit Play after restoration.
        guard hadPresentedMovie else { return }
        if let item {
            play(item, mode: mode, quality: selectedQuality, audioIndex: selectedAudioIndex, startAt: position,
                 continuingAutomaticFallback: automaticFallbackEnabled, retainingViewingSession: true, preservingIntent: .paused)
        } else if let source = localSource {
            playLocal(record: source.record, url: source.url, captionSources: source.captions,
                      startAt: position, preservingIntent: .paused, retainingViewingID: true)
        }
        publishNowPlaying()
    }

    private func publishNowPlaying() {
        guard isPresented, let title = currentTitle else { return }
        let elapsed = globalTime
        let validDuration = activeDuration.isFinite && activeDuration > 0 ? activeDuration : nil
        let rate = canAdvance && !isPreparing && !isApplyingInitialSeek && pendingSeek == nil && !hasEnded && errorMessage == nil
            && player.timeControlStatus == .playing ? Double(player.rate) : 0
        system.publish(PlaybackNowPlayingSnapshot(title: title, elapsed: elapsed.isFinite ? max(0, elapsed) : 0,
            duration: validDuration, rate: rate, defaultRate: Double(playbackSpeed),
            canPlay: errorMessage == nil && (!canAdvance || hasEnded),
            canPause: errorMessage == nil && intent == .playing && !hasEnded,
            canSeek: validDuration != nil && errorMessage == nil))
    }

    private var globalTime: Double {
        if isPreparing || isApplyingInitialSeek || pendingSeek != nil || errorMessage != nil || pausedPlaybackFailure != nil { return currentTime }
        let local = player.currentTime().seconds
        return (local.isFinite ? max(0, local) : 0) + streamOffset
    }

    private func canSeekLocally(to localTime: Double) -> Bool {
        guard activeAttempt != .original else { return true }
        guard viewingSession?.activePath != nil else { return false }
        let ranges = player.currentItem?.seekableTimeRanges.compactMap { value -> ClosedRange<Double>? in
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            guard start.isFinite, end.isFinite, end >= start else { return nil }
            return start...end
        } ?? []
        return PlaybackTimeline.contains(localTime, in: ranges)
    }

    private func installTimeObserver() {
        timeObserverPlayer = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let time = self.globalTime
                self.observeActualAdvancement()
                self.currentTime = PlaybackTimeline.clampedTime(
                    time,
                    duration: self.duration > 0 ? self.duration : nil
                )
                if let range = self.player.currentItem?.loadedTimeRanges.last?.timeRangeValue {
                    let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
                    if end.isFinite {
                        self.bufferedTime = PlaybackTimeline.clampedTime(
                            end + self.streamOffset,
                            duration: self.duration > 0 ? self.duration : nil
                        )
                    }
                }
                self.updateSubtitle(at: time)
                self.updateChapter(at: time)
                if time - self.lastProgressSave >= 15 || time < self.lastProgressSave {
                    self.saveProgress()
                    self.lastProgressSave = time
                }
                if time.isFinite, abs(time) < Double(Int.max) {
                    let second = Int(time)
                    if self.lastNowPlayingSecond != second {
                        self.lastNowPlayingSecond = second
                        self.publishNowPlaying()
                    }
                }
            }
        }
    }

    private func updateSubtitle(at time: Double) {
        let text = subtitleCues.filter { $0.contains(time) }.map(\.text).joined(separator: "\n")
        currentSubtitle = text.isEmpty ? nil : text
    }

    private func updateChapter(at time: Double) {
        currentChapterIndex = chapters.first { time >= $0.startSeconds && time < $0.endSeconds }?.id
    }

    private func saveProgress() {
        guard !isSavingStartOver, !isPreparing, !isApplyingInitialSeek, pendingSeek == nil, !hasEnded,
              player.currentItem?.status == .readyToPlay,
              activityStarted else { return }
        emitActivity(.progress(position: globalTime, duration: activeDuration))
    }

    private var activeLibraryKey: MovieLibraryKey? {
        guard let server = activeServerOrigin, let mediaID = activeMediaID else { return nil }
        return MovieLibraryKey(serverIdentity: server, accountUsername: activeAccountUsername, mediaID: mediaID)
    }

    private func activity(for request: PlaybackRequest, viewingID: UUID, event: PlaybackActivity.Event) -> PlaybackActivity {
        let key: MovieLibraryKey
        let source: PlaybackActivity.Source
        switch request.source {
        case .online(_, let connection):
            key = MovieLibraryKey(connection: connection, mediaID: request.movie.mediaID)
            source = .online
        case .offline(let record, _, _):
            key = MovieLibraryKey(serverIdentity: record.serverOrigin, accountUsername: record.accountUsername, mediaID: record.mediaID)
            source = .offline(recordID: record.id)
        }
        return PlaybackActivity(viewingID: viewingID, key: key, movie: request.movie, source: source, event: event)
    }

    private func emitActivity(_ event: PlaybackActivity.Event) {
        guard let key = activeLibraryKey, let movie = movieMetadata else { return }
        let activity = PlaybackActivity(viewingID: activityViewingID, key: key, movie: movie,
            source: localSource.map { .offline(recordID: $0.record.id) } ?? .online, event: event)
        activityStore.record(activity)
        Task { [weak self, activityStore] in
            do { try await activityStore.flush() }
            catch {
                guard let self, self.activityViewingID == activity.viewingID else { return }
                self.requestError = "Your viewing progress could not be saved. \(error.localizedDescription)"
            }
        }
    }

    private func observeActualAdvancement() {
        let time = player.currentTime().seconds
        guard !isSavingStartOver, !isPreparing, !isApplyingInitialSeek, pendingSeek == nil, transport.phase != .seeking,
              canAdvance, player.rate > 0, time.isFinite, !hasEnded, errorMessage == nil else {
            lastObservedPlaybackTime = nil
            return
        }
        defer { lastObservedPlaybackTime = time }
        if !activityStarted, let previous = lastObservedPlaybackTime, time > previous + 0.05 {
            activityStarted = true
            emitActivity(.started(position: time + streamOffset, duration: activeDuration))
        }
    }

    private func cancelPendingStart() {
        durableStartTask?.cancel()
        durableStartTask = nil
        startRequestID = UUID()
        isSavingStartOver = false
        isLoadingSavedPosition = false
    }

    private func scheduleStartupWatchdog(session: UUID) {
        startupWatchdog?.cancel()
        progressWatchdog.reset()
        let interval = watchdogInterval
        startupWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard self?.checkPlaybackProgress(session: session) == true else { return }
            }
        }
    }

    private func checkPlaybackProgress(session: UUID) -> Bool {
        guard currentSession == session, errorMessage == nil, !hasEnded else { return false }
        let stalled = progressWatchdog.sample(
            time: player.currentTime().seconds,
            now: ProcessInfo.processInfo.systemUptime,
            shouldAdvance: canAdvance && !isApplyingInitialSeek && pendingSeek == nil
        )
        if transport.progressed != progressWatchdog.hasProgressed {
            transport.progressed = progressWatchdog.hasProgressed
        }
        if stalled {
            handlePlaybackFailure(
                transport.progressed ? "Playback stopped receiving video. Check your connection and retry."
                    : "The video did not start. Check your connection and retry.",
                session: session
            )
            return false
        }
        return true
    }

    private func handlePlaybackFailure(_ message: String, session: UUID) {
        guard currentSession == session, errorMessage == nil else { return }
        if let rejection = authenticatedAsset?.rejection, rejection.category == .transportSecurity {
            finishWithFailure(rejection.message)
            return
        }
        let position = globalTime
        let retainedIntent = intent
        startupWatchdog?.cancel()
        if item != nil, intent == .paused || isSystemInterrupted {
            // AVFoundation can time out a held playlist even when the user
            // paused. Do not spend fallback attempts or create new producers
            // until the user asks to resume.
            pausedPlaybackFailure = message
            currentTime = position
            player.pause()
            viewingSession?.cancelActive()
            isPreparing = false
            isPlaying = false
            isBuffering = false
            transport.phase = .paused
            return
        }
        guard let item else {
            currentTime = position
            finishWithFailure(message)
            return
        }
        let action = PlaybackRouting.startupAction(
            after: activeAttempt,
            videoMode: selectedQuality == "auto" ? PlaybackCompatibility.videoMode(for: item) : "transcode",
            automaticFallbackEnabled: automaticFallbackEnabled,
            retryCount: startupRetryCount
        )
        switch action {
        case .fallback(let nextAttempt):
            play(
                item,
                mode: nextAttempt == .portable ? .portable : .compatible,
                quality: selectedQuality,
                audioIndex: selectedAudioIndex,
                startAt: position,
                continuingAutomaticFallback: true,
                retainingViewingSession: true,
                preservingIntent: retainedIntent
            )
            preparationMessage = "Trying another playback format…"
        case .retry:
            play(
                item, mode: mode, quality: selectedQuality, audioIndex: selectedAudioIndex,
                startAt: position, continuingAutomaticFallback: automaticFallbackEnabled,
                startupRetryCount: startupRetryCount + 1,
                retainingViewingSession: true, preservingIntent: retainedIntent
            )
        case .fail:
            currentTime = position
            finishWithFailure(message)
        }
    }

    private func finishWithFailure(_ message: String) {
        preparingAssetTask?.cancel()
        preparingAssetTask = nil
        pausedPlaybackFailure = nil
        player.pause()
        viewingSession?.cancelActive()
        authenticatedAsset?.stop()
        startupWatchdog?.cancel()
        isPreparing = false
        isPlaying = false
        isBuffering = false
        errorMessage = message
        transport.phase = .failed(message)
        publishNowPlaying()
    }

    private func refreshTransportPhase() {
        if let errorMessage { transport.phase = .failed(errorMessage) }
        else if hasEnded { transport.phase = .ended }
        else if !isPresented { transport.phase = .idle }
        else if isSystemInterrupted { transport.phase = .paused }
        else if isApplyingInitialSeek || pendingSeek != nil { transport.phase = .seeking }
        else if intent == .paused { transport.phase = .paused }
        else if isPreparing { transport.phase = .preparing }
        else if isPlaying { transport.phase = .playing }
        else { transport.phase = .buffering }
    }

    deinit {
        preparingAssetTask?.cancel()
        captionLoadTask?.cancel()
        durableStartTask?.cancel()
        startupWatchdog?.cancel()
        pendingSeek?.cancel()
        if let timeObserver { timeObserverPlayer?.removeTimeObserver(timeObserver) }
        let system = system
        Task { @MainActor in system.release() }
    }
}
