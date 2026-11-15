import SwiftUI

/// Siri Remote player over the shared PlaybackModel. AVFoundation decodes and
/// renders; the model owns the movie's global timeline, so prepared streams
/// that restart at a scrub target still show and seek in whole-movie time.
///
/// Controls hidden: left/right skip 10 seconds, holding left/right reveals the
/// progress bar and scrubs, select or up/down reveal the controls, Play/Pause
/// toggles, Menu closes. Controls visible: the progress bar scrubs with
/// left/right, repeating and accelerating while a direction is held, and
/// select jumps; Menu cancels a scrub or hides the controls.
struct TVPlayerView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controlsVisible = true
    @State private var autoHideTask: Task<Void, Never>?
    @State private var options: TVPlayerOptionsPage?
    @State private var scrubTime: Double?
    @State private var scrubStepper = TVScrubStepper()
    @State private var holdTask: Task<Void, Never>?
    @State private var seekFeedback: Double?
    @State private var feedbackTask: Task<Void, Never>?
    @FocusState private var focus: TVPlayerFocus?

    private var player: PlaybackModel { app.player }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerVideoView(player: player.player, resizeMode: player.resizeMode, pictureInPicture: nil)
                .ignoresSafeArea()
                .accessibilityHidden(true)
                .background {
                    TVDisplayCriteriaBridge(player: player.player, sourceFrameRate: player.item?.frameRate)
                        .accessibilityHidden(true)
                }

            if let message = player.errorMessage {
                errorPanel(message)
            } else {
                if !controlsVisible { hiddenSurface }
                subtitleLayer
                if controlsVisible {
                    controlsOverlay.transition(.opacity)
                } else {
                    statusIndicators
                }
            }
        }
        .onPlayPauseCommand(perform: handlePlayPause)
        .onExitCommand(perform: handleMenu)
        .background {
            TVDirectionalPressObserver(onChange: directionHoldChanged)
                .accessibilityHidden(true)
        }
        .sheet(item: $options, onDismiss: { scheduleAutoHide() }) { page in
            TVPlayerOptionsSheet(page: page)
        }
        .alert("Viewing progress needs attention", isPresented: Binding(
            get: { player.requestError != nil }, set: { if !$0 { player.requestError = nil } }
        )) {
            Button("OK") { player.requestError = nil }
        } message: { Text(player.requestError ?? "Please try again.") }
        .onAppear {
            focus = .playPause
            scheduleAutoHide()
        }
        .onDisappear {
            autoHideTask?.cancel()
            feedbackTask?.cancel()
            holdTask?.cancel()
        }
        .onChange(of: player.transport.intent) { _, intent in
            if intent == .paused { showControls(focusing: nil) } else { scheduleAutoHide() }
        }
        .onChange(of: player.isPlaying) { _, playing in if playing { scheduleAutoHide() } }
        .onChange(of: player.hasEnded) { _, ended in if ended { showControls(focusing: .playPause) } }
        .onChange(of: focus) { _, value in
            if value != .scrubber, scrubTime != nil { cancelScrub() }
            if value != .surface { scheduleAutoHide() }
        }
        .onChange(of: player.subtitleSelection) { _, selection in
            switch selection {
            case .loading, .failed: showControls(focusing: nil)
            case .off, .active: scheduleAutoHide()
            }
        }
        .onChange(of: player.systemPlaybackNotice) { _, notice in if notice != nil { showControls(focusing: nil) } }
        .onChange(of: player.errorMessage) { _, message in
            if message != nil {
                holdTask?.cancel()
                scrubTime = nil
                focus = .retry
            } else {
                showControls(focusing: .playPause)
            }
        }
        .onChange(of: voiceOverEnabled) { _, enabled in if enabled { showControls(focusing: nil) } }
    }

    // MARK: Surfaces

    /// While controls are hidden this transparent control owns focus so the
    /// remote's clicks and edge presses are never lost.
    private var hiddenSurface: some View {
        Button { showControls(focusing: .playPause) } label: {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(TVBareButtonStyle())
        .ignoresSafeArea()
        .focused($focus, equals: .surface)
        .onMoveCommand { direction in
            switch direction {
            case .left: skip(-10)
            case .right: skip(10)
            default: showControls(focusing: .scrubber)
            }
        }
        .accessibilityLabel(player.currentTitle ?? "Now Playing")
        .accessibilityHint("Shows playback controls")
        .accessibilityIdentifier("player-surface")
    }

    private var subtitleLayer: some View {
        VStack {
            Spacer()
            if let subtitle = player.currentSubtitle {
                Text(subtitle)
                    .font(.system(size: 46, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 3)
                    .frame(maxWidth: 1500)
                    .accessibilityLabel("Subtitles: \(subtitle)")
            }
        }
        .padding(.bottom, controlsVisible ? 330 : 70)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var statusIndicators: some View {
        if player.isPreparing {
            ProgressView(player.preparationMessage)
                .padding(32)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 24))
                .accessibilityAddTraits(.updatesFrequently)
        } else if player.isBuffering {
            ProgressView()
                .padding(32)
                .background(.black.opacity(0.7), in: Circle())
                .accessibilityLabel("Buffering video")
        }
        if let seekFeedback {
            VStack(spacing: 10) {
                Image(systemName: seekFeedback < 0 ? "gobackward.10" : "goforward.10").font(.system(size: 56))
                Text(PlaybackTimeline.displayTime(player.currentTime)).font(.callout.monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(32)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 28))
            .frame(maxWidth: .infinity, alignment: seekFeedback < 0 ? .leading : .trailing)
            .padding(.horizontal, 100)
            .transition(.opacity)
            .accessibilityHidden(true)
        }
    }

    private var controlsOverlay: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.75), .clear, .clear, .black.opacity(0.9)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 28) {
                header
                Spacer(minLength: 0)
                if player.isPreparing {
                    ProgressView(player.preparationMessage)
                } else if player.isBuffering {
                    ProgressView("Buffering video")
                }
                TVSubtitleFeedback()
                scrubber
                transportButtons.focusSection()
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 60)
        }
        .defaultFocus($focus, .playPause)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(player.currentTitle ?? "Now Playing").font(.title3.bold()).lineLimit(2)
                .accessibilityIdentifier("player-title")
            if let chapter = activeChapterTitle {
                Text(chapter).font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("player-current-chapter")
            }
            ForEach(notices, id: \.self) { notice in
                Text(notice).font(.caption)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            }
            if let notice = player.progressSaveNotice {
                HStack(spacing: 24) {
                    Text(notice).font(.caption)
                    Button(player.isRetryingProgressSave ? "Retrying…" : "Retry Saving Progress") {
                        Task { await player.retrySavingProgress() }
                    }
                    .disabled(player.isRetryingProgressSave)
                }
                .accessibilityIdentifier("player-progress-save-notice")
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var notices: [String] {
        [player.qualityNotice, player.streamFormatNotice, player.systemPlaybackNotice].compactMap { $0 }
    }

    private var scrubber: some View {
        let position = scrubTime ?? player.currentTime
        let duration = player.duration
        return Button(action: scrubberSelected) {
            VStack(spacing: 14) {
                TVScrubberBar(position: position, duration: duration, buffered: player.bufferedTime,
                              isFocused: focus == .scrubber, isScrubbing: scrubTime != nil)
                HStack {
                    Text(PlaybackTimeline.displayTime(position))
                    Spacer()
                    if scrubTime != nil {
                        Text("Select to jump · Menu to cancel").foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text("-" + PlaybackTimeline.displayTime(max(0, duration - position)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
            }
        }
        .buttonStyle(TVBareButtonStyle())
        .focused($focus, equals: .scrubber)
        .onMoveCommand(perform: scrub)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(PlaybackTimeline.displayTime(position)) of \(PlaybackTimeline.displayTime(duration))")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 10.0 : -10.0
            player.seek(toGlobalTime: PlaybackTimeline.skipTarget(currentTime: player.currentTime, seconds: delta,
                                                                 duration: duration))
        }
        .accessibilityIdentifier("playback-scrubber")
        .disabled(duration <= 0)
    }

    private var transportButtons: some View {
        HStack(spacing: 28) {
            iconButton("gobackward.10", label: "Rewind 10 seconds", focus: .back) { skip(-10) }
            iconButton(player.transport.actionSymbol, label: player.transport.actionLabel, focus: .playPause) {
                player.togglePlayback()
            }
            .accessibilityIdentifier("play-pause-control")
            iconButton("goforward.10", label: "Forward 10 seconds", focus: .forward) { skip(10) }
            Spacer(minLength: 40)
            if !player.subtitleOptions.isEmpty || player.subtitleSelection.requested != nil {
                iconButton(player.subtitleSelection.active == nil ? "captions.bubble" : "captions.bubble.fill",
                           label: "Subtitles", focus: .subtitles) { options = .subtitles }
                    .accessibilityValue(player.subtitleSelection.accessibilityValue)
            }
            if let item = player.item, !item.audioTracks.isEmpty {
                iconButton("waveform", label: "Audio", focus: .audio) { options = .audio }
            }
            if !player.chapters.isEmpty {
                iconButton("list.bullet", label: "Chapters", focus: .chapters) { options = .chapters }
            }
            iconButton("gearshape", label: "Playback Options", focus: .options) { options = .settings }
                .accessibilityIdentifier("player-options")
            iconButton("xmark", label: "Close Player", focus: .close) { player.stop() }
        }
    }

    private func iconButton(_ symbol: String, label: String, focus target: TVPlayerFocus,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3).frame(width: 64, height: 48)
        }
        .focused($focus, equals: target)
        .accessibilityLabel(label)
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(spacing: 28) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 64)).accessibilityHidden(true)
            Text("Playback couldn’t continue").font(.title3.bold())
            Text(message).multilineTextAlignment(.center).frame(maxWidth: 1100)
            Text("At \(PlaybackTimeline.displayTime(player.currentTime))").font(.callout.monospacedDigit())
                .accessibilityIdentifier("player-error-position")
            HStack(spacing: 32) {
                Button("Retry") { player.retryCurrentPlayback() }
                    .focused($focus, equals: .retry)
                    .accessibilityLabel("Retry Current Playback")
                if let retryLabel = player.retryLabel {
                    Button(retryLabel) { player.retryCompatible() }
                }
                Button("Close") { player.stop() }
            }
        }
        .foregroundStyle(.white)
        .padding(60)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 32))
        .defaultFocus($focus, .retry)
    }

    private var activeChapterTitle: String? {
        guard let index = player.currentChapterIndex else { return nil }
        return player.chapters.first { $0.id == index }?.title
    }

    // MARK: Remote handling

    private func handlePlayPause() {
        guard player.errorMessage == nil else { return }
        if let target = scrubTime {
            commitScrub(target)
            if player.transport.intent == .playing { return }
        }
        player.togglePlayback()
    }

    private func handleMenu() {
        if scrubTime != nil {
            cancelScrub()
        } else if controlsVisible && player.errorMessage == nil && !voiceOverEnabled {
            hideControls()
        } else {
            player.stop()
        }
    }

    private func scrubberSelected() {
        if let target = scrubTime { commitScrub(target) } else { player.togglePlayback() }
    }

    private func scrub(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: scrub(sign: -1)
        case .right: scrub(sign: 1)
        default: return
        }
    }

    private func scrub(sign: Int) {
        guard player.duration > 0 else { return }
        let base = scrubTime ?? player.currentTime
        scrubTime = PlaybackTimeline.clampedTime(base + scrubStepper.step(sign), duration: player.duration)
        autoHideTask?.cancel()
    }

    /// A held left/right keeps scrubbing after the press's own single step.
    /// The move command already handled the press itself (a step on the
    /// progress bar, a ten-second skip with controls hidden); repeats start
    /// once the press outlasts a click and stop on release, leaving the
    /// preview for Select to jump or Menu to cancel.
    private func directionHoldChanged(_ direction: Int?) {
        holdTask?.cancel()
        holdTask = nil
        guard let direction, player.errorMessage == nil, player.duration > 0,
              focus == .scrubber || focus == .surface else { return }
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: TVScrubStepper.holdDelay)
            guard !Task.isCancelled else { return }
            if focus == .surface { showControls(focusing: .scrubber) }
            while !Task.isCancelled, player.errorMessage == nil {
                switch focus {
                case .scrubber: scrub(sign: direction)
                case .surface: break // the revealed controls are taking focus
                default: return
                }
                try? await Task.sleep(for: TVScrubStepper.holdInterval)
            }
        }
    }

    private func commitScrub(_ target: Double) {
        scrubTime = nil
        scrubStepper.reset()
        player.seek(toGlobalTime: target)
        scheduleAutoHide()
    }

    private func cancelScrub() {
        scrubTime = nil
        scrubStepper.reset()
        scheduleAutoHide()
    }

    private func skip(_ seconds: Double) {
        guard player.errorMessage == nil, player.duration > 0 else { return }
        _ = player.skip(by: seconds)
        if controlsVisible {
            scheduleAutoHide()
            return
        }
        feedbackTask?.cancel()
        withAnimation(controlAnimation) { seekFeedback = seconds }
        feedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled else { return }
            withAnimation(controlAnimation) { seekFeedback = nil }
        }
    }

    // MARK: Visibility

    private func showControls(focusing target: TVPlayerFocus?) {
        if !controlsVisible {
            withAnimation(controlAnimation) { controlsVisible = true }
            let destination = target ?? .playPause
            // Focus moves once the overlay exists in the hierarchy.
            Task { @MainActor in focus = destination }
        } else if let target {
            focus = target
        }
        scheduleAutoHide()
    }

    private func hideControls() {
        autoHideTask?.cancel()
        scrubTime = nil
        scrubStepper.reset()
        withAnimation(controlAnimation) { controlsVisible = false }
        Task { @MainActor in focus = .surface }
    }

    private var mayAutoHide: Bool {
        controlsVisible && !voiceOverEnabled && options == nil && scrubTime == nil
            && player.errorMessage == nil && player.transport.intent == .playing && player.isPlaying
            && !player.hasEnded && player.systemPlaybackNotice == nil && player.progressSaveNotice == nil
            && !subtitleNeedsAttention
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        guard mayAutoHide else { return }
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, mayAutoHide else { return }
            hideControls()
        }
    }

    private var subtitleNeedsAttention: Bool {
        switch player.subtitleSelection {
        case .loading, .failed: true
        case .off, .active: false
        }
    }

    private var controlAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.2) }
}

enum TVPlayerFocus: Hashable {
    case surface, scrubber, back, playPause, forward, subtitles, audio, chapters, options, close, retry
}

/// Successive presses in one direction, or a held direction's repeats,
/// accelerate long-distance scrubbing.
struct TVScrubStepper {
    /// A press held this long becomes a hold rather than a click.
    static let holdDelay = Duration.milliseconds(450)
    /// Repeat cadence while held; well inside the 0.6-second repeat window.
    static let holdInterval = Duration.milliseconds(200)

    private var lastDirection = 0
    private var lastStep = Date.distantPast
    private var repeats = 0

    mutating func step(_ direction: Int, now: Date = Date()) -> Double {
        if direction == lastDirection, now.timeIntervalSince(lastStep) < 0.6 { repeats += 1 } else { repeats = 0 }
        lastDirection = direction
        lastStep = now
        let seconds: Double
        switch repeats {
        case 0..<3: seconds = 10
        case 3..<6: seconds = 30
        case 6..<10: seconds = 60
        default: seconds = 120
        }
        return Double(direction) * seconds
    }

    mutating func reset() {
        lastDirection = 0
        repeats = 0
        lastStep = .distantPast
    }
}

/// Focusable without the system platter; the content draws its own state.
struct TVBareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

private struct TVScrubberBar: View {
    let position: Double
    let duration: Double
    let buffered: Double
    let isFocused: Bool
    let isScrubbing: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let played = PlaybackTimeline.progress(position, duration: duration)
            let loaded = PlaybackTimeline.progress(buffered, duration: duration)
            let height: CGFloat = isFocused ? 14 : 8
            let knob: CGFloat = isScrubbing ? 34 : 26
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: height)
                Capsule().fill(.white.opacity(0.45)).frame(width: width * loaded, height: height)
                Capsule().fill(isFocused ? Color.white : Color("AccessibleAccent"))
                    .frame(width: width * played, height: height)
                if isFocused {
                    Circle().fill(.white).frame(width: knob, height: knob)
                        .shadow(radius: 6)
                        .offset(x: min(width - knob, max(0, width * played - knob / 2)))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 40)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
