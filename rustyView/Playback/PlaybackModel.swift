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
    let player = AVPlayer()
    @Published private(set) var item: MediaItem?
    @Published private(set) var currentTitle: String?
    @Published private(set) var isPresented = false
    @Published private(set) var isPreparing = false
    @Published var errorMessage: String?
    @Published var selectedAudioIndex: Int?
    @Published var selectedQuality = "auto"
    @Published var mode = PlaybackMode.automatic
    @Published private(set) var selectedCaptionIndex: Int?
    @Published private(set) var currentSubtitle: String?
    @Published private(set) var currentChapterIndex: Int?
    @Published var subtitleError: String?
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var bufferedTime = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var hasEnded = false
    @Published var playbackSpeed: Float = 1
    @Published var resizeMode = VideoResizeMode.fit

    private let client: RustyDLNAClient
    private let progressStore: PlaybackProgressStore
    private var currentSession = UUID()
    private var itemObservations: Set<AnyCancellable> = []
    private var lifetimeObservations: Set<AnyCancellable> = []
    private var timeObserver: Any?
    private var subtitleCues: [SubtitleCue] = []
    private var streamOffset = 0.0
    private var lastProgressSave = 0.0
    private var activeServerOrigin: String?
    private var activeMediaID: String?
    private var activeDuration = 0.0
    private var activeAttempt = PlaybackAttempt.original
    private var automaticFallbackEnabled = false
    private var authenticatedAsset: AuthenticatedMediaAsset?
    private var startupWatchdog: Task<Void, Never>?
    private var startupRetryCount = 0

    init(client: RustyDLNAClient, progressStore: PlaybackProgressStore = PlaybackProgressStore()) {
        self.client = client
        self.progressStore = progressStore
        configureAudioSession()
        configureRemoteCommands()
        installTimeObserver()
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.isPlaying = status == .playing
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate && !self.isPreparing
            }
            .store(in: &lifetimeObservations)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveProgress() }
            .store(in: &lifetimeObservations)
    }

    func play(
        _ item: MediaItem,
        mode: PlaybackMode = .automatic,
        quality: String = "auto",
        audioIndex: Int? = nil,
        startAt explicitStart: Double? = nil,
        continuingAutomaticFallback: Bool = false,
        startupRetryCount: Int = 0
    ) {
        startupWatchdog?.cancel()
        let sameItem = self.item?.id == item.id
        currentSession = UUID()
        let session = currentSession
        self.item = item
        currentTitle = item.displayTitle
        self.mode = mode
        automaticFallbackEnabled = mode == .automatic || continuingAutomaticFallback
        self.startupRetryCount = startupRetryCount
        selectedQuality = quality
        selectedAudioIndex = audioIndex ?? item.defaultAudioIndex
        errorMessage = nil
        isPreparing = true
        isPresented = true
        activeServerOrigin = client.connection?.baseURL.absoluteString
        activeMediaID = item.id
        activeDuration = Double(item.durationSeconds ?? 0)
        duration = activeDuration
        currentTime = 0
        bufferedTime = 0
        hasEnded = false
        if !sameItem {
            selectedCaptionIndex = nil
            subtitleCues = []
            currentSubtitle = nil
            subtitleError = nil
        }

        let savedPosition = activeServerOrigin.flatMap {
            progressStore.resumePosition(serverOrigin: $0, mediaID: item.id)
        }
        let startPosition = max(0, explicitStart ?? savedPosition ?? 0)
        currentChapterIndex = PlaybackTimeline.activeChapterIndex(
            in: item.chapters,
            at: startPosition
        )

        do {
            try activateAudioSession()
            let path: String
            let attempt = PlaybackRouting.attempt(
                mode: mode,
                quality: quality,
                transcodeLikely: item.transcodeLikely,
                selectedAudioIndex: selectedAudioIndex,
                defaultAudioIndex: item.defaultAudioIndex
            )
            activeAttempt = attempt
            if attempt != .original {
                path = client.compatiblePath(
                    for: item,
                    quality: quality,
                    audioIndex: selectedAudioIndex,
                    startSeconds: Int(startPosition),
                    forceVideoTranscode: attempt == .portable
                )
            } else {
                path = item.sourceURL + (item.sourceURL.contains("?") ? "&" : "?") + "reason=native_ios"
            }
            let usesCompatibleStream = attempt != .original
            streamOffset = usesCompatibleStream ? Double(Int(startPosition)) : 0
            let authenticatedAsset = try client.asset(serverPath: path)
            self.authenticatedAsset = authenticatedAsset
            let playerItem = AVPlayerItem(asset: authenticatedAsset.asset)
            observe(
                playerItem,
                session: session,
                initialSeek: usesCompatibleStream ? nil : startPosition
            )
            player.replaceCurrentItem(with: playerItem)
            updateNowPlaying(item: item)
            player.defaultRate = playbackSpeed
            player.playImmediately(atRate: playbackSpeed)
            scheduleStartupWatchdog(session: session)
        } catch {
            isPreparing = false
            errorMessage = error.localizedDescription
        }
    }

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
            startAt: globalTime
        )
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
        let wasPlaying = player.rate > 0
        saveProgress()
        selectedAudioIndex = index
        let selectedMode: PlaybackMode = activeAttempt == .portable ? .portable : .compatible
        play(
            item,
            mode: selectedMode,
            quality: selectedQuality,
            audioIndex: index,
            startAt: position,
            continuingAutomaticFallback: true
        )
        if !wasPlaying { player.pause() }
    }

    func togglePlayback() {
        if isPlaying || player.rate > 0 {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    private func pausePlayback() {
        player.pause()
        saveProgress()
    }

    private func resumePlayback() {
        if hasEnded {
            restartAfterEnd()
        } else {
            do {
                try activateAudioSession()
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            player.playImmediately(atRate: playbackSpeed)
        }
    }

    func setPlaybackSpeed(_ speed: Float) {
        guard speed.isFinite, speed >= 0.25, speed <= 2 else { return }
        playbackSpeed = speed
        player.defaultRate = speed
        if isPlaying || player.rate > 0 {
            player.rate = speed
        }
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
        let target = PlaybackTimeline.clampedTime(target, duration: duration > 0 ? duration : nil)
        hasEnded = false
        currentTime = target
        let wasPlaying = player.rate > 0
        if let localTime = PlaybackTimeline.localTime(
            forGlobalTime: target,
            streamOffset: streamOffset
        ), canSeekLocally(to: localTime) {
            player.seek(
                to: CMTime(seconds: localTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            updateSubtitle(at: max(0, target))
            updateChapter(at: max(0, target))
            return
        }
        guard let item else { return }
        play(
            item,
            mode: mode,
            quality: selectedQuality,
            audioIndex: selectedAudioIndex,
            startAt: max(0, target),
            continuingAutomaticFallback: automaticFallbackEnabled
        )
        if !wasPlaying { player.pause() }
    }

    func selectCaption(_ index: Int?) async {
        selectedCaptionIndex = index
        subtitleCues = []
        currentSubtitle = nil
        subtitleError = nil
        guard let index else { return }
        guard let caption = item?.captions.first(where: { $0.index == index }),
              caption.isPlayableOnDevice,
              let path = caption.url else {
            selectedCaptionIndex = nil
            subtitleError = "This subtitle track cannot be converted for this device."
            return
        }
        do {
            subtitleCues = try WebVTTParser.parse(try await client.data(serverPath: path))
            updateSubtitle(at: globalTime)
        } catch is CancellationError {
            return
        } catch {
            subtitleError = error.localizedDescription
            selectedCaptionIndex = nil
        }
    }

    func resumePosition(for item: MediaItem) -> Double? {
        guard let origin = client.connection?.baseURL.absoluteString else { return nil }
        return progressStore.resumePosition(serverOrigin: origin, mediaID: item.id)
    }

    func playLocal(record: DownloadRecord, url: URL) {
        currentSession = UUID()
        item = nil
        mode = .original
        errorMessage = nil
        isPreparing = true
        isPresented = true
        streamOffset = 0
        currentChapterIndex = nil
        activeServerOrigin = record.serverOrigin
        activeMediaID = record.mediaID
        activeDuration = Double(record.durationSeconds ?? 0)
        duration = activeDuration
        currentTime = 0
        bufferedTime = 0
        hasEnded = false
        currentTitle = record.displayTitle
        let resume = progressStore.resumePosition(
            serverOrigin: record.serverOrigin,
            mediaID: record.mediaID
        )
        let playerItem = AVPlayerItem(url: url)
        observe(playerItem, session: currentSession, initialSeek: resume)
        player.replaceCurrentItem(with: playerItem)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: record.displayTitle]
        player.defaultRate = playbackSpeed
        player.playImmediately(atRate: playbackSpeed)
    }

    func stop() {
        saveProgress()
        currentSession = UUID()
        player.pause()
        player.replaceCurrentItem(with: nil)
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func observe(_ playerItem: AVPlayerItem, session: UUID, initialSeek: Double? = nil) {
        itemObservations.removeAll()
        playerItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak playerItem] status in
                guard let self, self.currentSession == session else { return }
                switch status {
                case .readyToPlay:
                    self.startupWatchdog?.cancel()
                    self.isPreparing = false
                    self.isBuffering = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    let itemDuration = playerItem?.duration.seconds ?? 0
                    if self.duration <= 0, itemDuration.isFinite, itemDuration > 0 {
                        self.duration = itemDuration + self.streamOffset
                    }
                    if let initialSeek, initialSeek > 0 {
                        self.player.seek(to: CMTime(seconds: initialSeek, preferredTimescale: 600))
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
                guard let self, self.currentSession == session,
                      let origin = self.activeServerOrigin,
                      let mediaID = self.activeMediaID else { return }
                self.hasEnded = true
                self.isPlaying = false
                self.progressStore.clear(serverOrigin: origin, mediaID: mediaID)
            }
            .store(in: &itemObservations)
    }

    private func restartAfterEnd() {
        hasEnded = false
        if streamOffset > 0, let item {
            play(
                item,
                mode: mode,
                quality: selectedQuality,
                audioIndex: selectedAudioIndex,
                startAt: 0,
                continuingAutomaticFallback: automaticFallbackEnabled
            )
            return
        }
        currentTime = 0
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.player.playImmediately(atRate: self.playbackSpeed)
            }
        }
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        } catch {
            // Playback will surface a concrete failure if the audio session is unavailable.
        }
    }

    private func activateAudioSession() throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try AVAudioSession.sharedInstance().setActive(true)
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.resumePlayback() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.pausePlayback() }
            return .success
        }
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.skip(by: 10) }
            return .success
        }
        commands.skipBackwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.skip(by: -10) }
            return .success
        }
    }

    private func updateNowPlaying(item: MediaItem) {
        var info: [String: Any] = [MPMediaItemPropertyTitle: item.displayTitle]
        if let duration = item.durationSeconds { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private var globalTime: Double {
        let local = player.currentTime().seconds
        return (local.isFinite ? max(0, local) : 0) + streamOffset
    }

    private func canSeekLocally(to localTime: Double) -> Bool {
        guard activeAttempt != .original else { return true }
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
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let time = self.globalTime
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
            }
        }
    }

    private func updateSubtitle(at time: Double) {
        currentSubtitle = subtitleCues.first(where: { $0.contains(time) })?.text
    }

    private func updateChapter(at time: Double) {
        currentChapterIndex = PlaybackTimeline.activeChapterIndex(
            in: item?.chapters ?? [],
            at: time
        )
    }

    private func saveProgress() {
        guard let origin = activeServerOrigin, let mediaID = activeMediaID else { return }
        progressStore.update(
            serverOrigin: origin,
            mediaID: mediaID,
            position: globalTime,
            duration: activeDuration
        )
    }

    private func scheduleStartupWatchdog(session: UUID) {
        startupWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self,
                  self.currentSession == session,
                  self.isPreparing,
                  let item = self.item else { return }
            let action = PlaybackRouting.startupAction(
                after: self.activeAttempt,
                videoMode: PlaybackCompatibility.videoMode(for: item),
                automaticFallbackEnabled: self.automaticFallbackEnabled,
                retryCount: self.startupRetryCount
            )
            switch action {
            case .fallback:
                self.handlePlaybackFailure(
                    "The video took too long to start.",
                    session: session
                )
            case .retry:
                self.play(
                    item,
                    mode: self.mode,
                    quality: self.selectedQuality,
                    audioIndex: self.selectedAudioIndex,
                    startAt: self.globalTime,
                    continuingAutomaticFallback: self.automaticFallbackEnabled,
                    startupRetryCount: self.startupRetryCount + 1
                )
            case .fail:
                self.player.pause()
                self.isPreparing = false
                self.errorMessage = "The server prepared the video, but playback did not start. Try again or choose Maximum Compatibility in playback options."
            }
        }
    }

    private func handlePlaybackFailure(_ message: String, session: UUID) {
        guard currentSession == session else { return }
        startupWatchdog?.cancel()
        isPreparing = false
        if automaticFallbackEnabled,
           let item,
           let nextAttempt = PlaybackRouting.nextFallback(
               after: activeAttempt,
               videoMode: PlaybackCompatibility.videoMode(for: item)
           ) {
            let position = globalTime
            errorMessage = nextAttempt == .portable
                ? "Trying maximum compatibility…"
                : "Trying a compatible stream…"
            play(
                item,
                mode: nextAttempt == .portable ? .portable : .compatible,
                quality: selectedQuality,
                audioIndex: selectedAudioIndex,
                startAt: position,
                continuingAutomaticFallback: true
            )
        } else {
            errorMessage = message
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }
}
