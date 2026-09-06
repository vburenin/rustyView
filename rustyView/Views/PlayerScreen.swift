import AVKit
import SwiftUI

struct PlayerScreen: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var keyboardFocus: Bool
    @AccessibilityFocusState private var assistiveFocus: PlayerControl?
    @State private var showingDetails = false
    @State private var controlsVisible = true
    @State private var isScrubbing = false
    @State private var scrubberTime = 0.0
    @State private var seekFeedback: SeekDirection?
    @State private var feedbackTask: Task<Void, Never>?
    @State private var autoHideTask: Task<Void, Never>?
    @State private var usingKeyboard = false
    @State private var switchControlEnabled = UIAccessibility.isSwitchControlRunning
    @State private var showingSubtitleOutputWarning = false
    @State private var showingAirPlayExplanation = false
    @StateObject private var pictureInPicture = PlayerPictureInPictureController()

    private var playerSurface: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerVideoView(
                player: app.player.player,
                resizeMode: app.player.resizeMode,
                pictureInPicture: pictureInPicture
            )
            .ignoresSafeArea()

            PlayerGestureLayer(
                onSingleTap: toggleControls,
                onDoubleTapBack: { skip(.backward, revealControls: false) },
                onDoubleTapForward: { skip(.forward, revealControls: false) }
            )
            .ignoresSafeArea()
            .allowsHitTesting(app.player.errorMessage == nil)

            if controlsVisible && app.player.errorMessage == nil {
                controls
                    .transition(.opacity)
            }

            if !controlsVisible, let subtitle = app.player.currentSubtitle {
                subtitleView(subtitle)
            }

            if let seekFeedback {
                SeekFeedbackView(direction: seekFeedback)
                    .frame(maxWidth: .infinity, alignment: seekFeedback.alignment)
                    .padding(.horizontal, 36)
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            if !controlsVisible && app.player.isPreparing {
                ProgressView(app.player.preparationMessage)
                    .tint(.white)
                    .foregroundStyle(.white)
                    .padding()
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            if !controlsVisible && app.player.isBuffering && !app.player.isPreparing {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .padding(18)
                    .background(.black.opacity(0.68), in: Circle())
                    .allowsHitTesting(false)
                    .accessibilityLabel("Buffering video")
                    .accessibilityAddTraits(.updatesFrequently)
            }

            if let message = app.player.errorMessage {
                playbackError(message)
            }
        }
    }

    private var playerTransportView: some View {
        playerSurface
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .focusable()
        .focused($keyboardFocus)
        .focusEffectDisabled()
        .onKeyPress(keys: playerKeyboardKeys, phases: [.down, .repeat]) { press in
            handleKeyPress(press)
        }
        .onAppear {
            scrubberTime = app.player.currentTime
            keyboardFocus = true
            updatePictureInPicturePolicy()
            scheduleAutoHide()
        }
        .onDisappear {
            autoHideTask?.cancel()
            feedbackTask?.cancel()
        }
        .onChange(of: app.player.currentTime) { _, value in
            if !isScrubbing { scrubberTime = value }
        }
        .onChange(of: app.player.isPlaying) { _, playing in
            if playing {
                scheduleAutoHide()
            } else {
                autoHideTask?.cancel()
                withAnimation(controlAnimation) { controlsVisible = true }
            }
        }
        .onChange(of: app.player.isPreparing) { _, preparing in
            if !preparing { scheduleAutoHide() }
        }
    }

    private var playerAccessibilityView: some View {
        playerTransportView
        .onChange(of: voiceOverEnabled) { _, enabled in
            if enabled { controlsVisible = true }
            scheduleAutoHide()
        }
        .onChange(of: dynamicTypeSize) { _, size in
            if size.isAccessibilitySize { controlsVisible = true }
            scheduleAutoHide()
        }
        .onChange(of: assistiveFocus) { _, focus in
            if focus != nil { controlsVisible = true }
            scheduleAutoHide()
        }
        .onChange(of: showingDetails) { _, showing in
            if showing { keyboardFocus = false }
            controlsVisible = true
            scheduleAutoHide()
        }
        .onChange(of: app.player.requiresSubtitleOutputAcknowledgement) { _, _ in
            updatePictureInPicturePolicy()
        }
        .onChange(of: app.player.subtitleSelection) { _, selection in
            controlsVisible = true
            scheduleAutoHide()
            if case .failed(_, let message) = selection {
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
        .onChange(of: app.player.systemPlaybackNotice) { _, notice in
            if let notice {
                controlsVisible = true
                UIAccessibility.post(notification: .announcement, argument: notice)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.switchControlStatusDidChangeNotification)) { _ in
            switchControlEnabled = UIAccessibility.isSwitchControlRunning
            if switchControlEnabled { controlsVisible = true }
            scheduleAutoHide()
        }
    }

    var body: some View {
        playerAccessibilityView
        .sheet(isPresented: $showingDetails, onDismiss: { keyboardFocus = true }) {
            if let item = app.player.item {
                PlaybackOptionsView(item: item, mode: app.player.mode, quality: app.player.selectedQuality)
                    .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
            } else {
                LocalPlaybackOptionsView()
                    .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
            }
        }
        .alert(
            "Picture in Picture unavailable",
            isPresented: pictureInPictureErrorPresented
        ) {
            Button("OK") { pictureInPicture.errorMessage = nil }
        } message: {
            Text(pictureInPicture.errorMessage ?? "Please try again.")
        }
        .alert("Subtitles stay in rustyView", isPresented: $showingSubtitleOutputWarning) {
            Button("Start Without Subtitles") { pictureInPicture.toggle() }
            Button("Keep Watching Here", role: .cancel) {}
        } message: {
            Text("These subtitles won’t appear in Picture in Picture. They’ll return when you reopen the player.")
        }
        .alert("AirPlay", isPresented: $showingAirPlayExplanation) {
            if app.player.mediaOutputPolicy.allowsExternalPlayback,
               app.player.requiresSubtitleOutputAcknowledgement {
                Button("Turn Subtitles Off") { app.player.turnSubtitlesOff() }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.player.mediaOutputPolicy.explanation
                 ?? "Turn subtitles off to use AirPlay video.")
        }
        .alert("Viewing progress needs attention", isPresented: requestErrorPresented) {
            Button("OK") { app.player.requestError = nil }
        } message: { Text(app.player.requestError ?? "Please try again.") }
    }

    private var playerKeyboardKeys: Set<KeyEquivalent> {
        showingDetails ? [] : [.space, .leftArrow, .rightArrow, .escape, "o"]
    }

    private var pictureInPictureErrorPresented: Binding<Bool> {
        Binding(
            get: { pictureInPicture.errorMessage != nil },
            set: { if !$0 { pictureInPicture.errorMessage = nil } }
        )
    }

    private var requestErrorPresented: Binding<Bool> {
        Binding(
            get: { app.player.requestError != nil },
            set: { if !$0 { app.player.requestError = nil } }
        )
    }

    private var controls: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.72), .clear, .black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            ViewThatFits(in: .vertical) {
                controlContent(compact: false)
                ScrollView { controlContent(compact: true) }
                    .accessibilityIdentifier("player-controls-scroll")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
    }

    private func controlContent(compact: Bool) -> some View {
        VStack(spacing: compact ? 12 : 0) {
            topControls
            if app.player.isPreparing {
                ProgressView(app.player.preparationMessage)
                    .tint(.white)
                    .padding(10)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8)
            } else if app.player.isBuffering {
                ProgressView("Buffering video")
                    .tint(.white)
                    .padding(10)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8)
            }
            if let notice = app.player.qualityNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8)
                    .accessibilityIdentifier("player-quality-notice")
            }
            if let notice = app.player.systemPlaybackNotice {
                Text(notice)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("player-system-notice")
            }
            if !compact { Spacer(minLength: 12) }
            centerControls
            if !compact { Spacer(minLength: 12) }
            if let subtitle = app.player.currentSubtitle { subtitleText(subtitle).padding(.vertical, 8) }
            bottomControls
        }
        .frame(maxWidth: .infinity)
    }

    private var topControls: some View {
        VStack(spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize { playerTitle }
            topControlButtons
        }
    }

    private var playerTitle: some View {
        Text(app.player.currentTitle ?? "Now Playing")
            .font(.headline)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.white)
            .accessibilityIdentifier("player-title")
    }

    private var topControlButtons: some View {
        HStack(spacing: 10) {
            PlayerIconButton(
                systemName: "xmark",
                accessibilityLabel: "Close player",
                action: app.player.stop
            )
            .accessibilityFocused($assistiveFocus, equals: .close)

            if !dynamicTypeSize.isAccessibilitySize { playerTitle }

            Spacer(minLength: 4)

            if app.player.mediaOutputPolicy.allowsExternalPlayback && !app.player.requiresSubtitleOutputAcknowledgement {
                AirPlayRoutePicker()
                    .frame(width: 44, height: 44)
                    .accessibilityFocused($assistiveFocus, equals: .airPlay)
            } else {
                PlayerIconButton(systemName: "airplay.video", accessibilityLabel: "AirPlay") {
                    showingAirPlayExplanation = true
                }
                .accessibilityHint("Shows availability for this video and its subtitles")
                .accessibilityFocused($assistiveFocus, equals: .airPlay)
            }

            if AVPictureInPictureController.isPictureInPictureSupported() {
                PlayerIconButton(
                    systemName: pictureInPicture.isActive
                        ? "pip.exit"
                        : "pip.enter",
                    accessibilityLabel: pictureInPicture.isActive
                        ? "Stop Picture in Picture"
                        : "Start Picture in Picture"
                ) {
                    if !pictureInPicture.isActive && app.player.requiresSubtitleOutputAcknowledgement {
                        showingSubtitleOutputWarning = true
                    } else {
                        pictureInPicture.toggle()
                    }
                    noteInteraction()
                }
                .disabled(!pictureInPicture.isPossible && !pictureInPicture.isActive)
                .accessibilityFocused($assistiveFocus, equals: .pictureInPicture)
            }

            PlayerIconButton(systemName: "gearshape", accessibilityLabel: "Playback options") {
                showingDetails = true
                noteInteraction()
            }
            .accessibilityFocused($assistiveFocus, equals: .options)
        }
    }

    private var centerControls: some View {
        HStack(spacing: 34) {
            PlayerIconButton(
                systemName: "gobackward.10",
                accessibilityLabel: "Rewind 10 seconds",
                diameter: 56
            ) {
                skip(.backward, revealControls: true)
            }
            .accessibilityFocused($assistiveFocus, equals: .backward)

            Button {
                app.player.togglePlayback()
                noteInteraction()
            } label: {
                Image(systemName: app.player.transport.actionSymbol)
                    .font(.system(size: 31, weight: .semibold))
                    .offset(x: app.player.transport.actionSymbol == "play.fill" ? 2 : 0)
                    .frame(width: 72, height: 72)
                    .background(.black.opacity(0.62), in: Circle())
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.white)
            .accessibilityLabel(app.player.transport.actionLabel)
            .accessibilityHint("Double tap to toggle playback")
            .accessibilityIdentifier("play-pause-control")
            .accessibilityFocused($assistiveFocus, equals: .playPause)

            PlayerIconButton(
                systemName: "goforward.10",
                accessibilityLabel: "Forward 10 seconds",
                diameter: 56
            ) {
                skip(.forward, revealControls: true)
            }
            .accessibilityFocused($assistiveFocus, equals: .forward)
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 4) {
            SubtitleFeedbackView()
            HStack(spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Text(PlaybackTimeline.displayTime(scrubberTime))
                        Text("/").foregroundStyle(.white.opacity(0.65))
                        Text(PlaybackTimeline.displayTime(app.player.duration))
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PlaybackTimeline.displayTime(scrubberTime))
                        Text("of " + PlaybackTimeline.displayTime(app.player.duration))
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                if !dynamicTypeSize.isAccessibilitySize, let chapter = activeChapterTitle {
                    currentChapterLabel(chapter)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
            .accessibilityElement(children: .combine)
            .accessibilityValue("\(Int(scrubberTime)) seconds elapsed")
            .accessibilityIdentifier("player-time-label")

            if dynamicTypeSize.isAccessibilitySize, let chapter = activeChapterTitle {
                currentChapterLabel(chapter)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            PlayerScrubber(
                value: $scrubberTime,
                duration: app.player.duration,
                bufferedTime: app.player.bufferedTime,
                onEditingChanged: { editing in
                    isScrubbing = editing
                    autoHideTask?.cancel()
                },
                onCommit: { value in
                    app.player.seek(toGlobalTime: value)
                    noteInteraction()
                }
            )
            .accessibilityFocused($assistiveFocus, equals: .position)

            Group {
                if dynamicTypeSize > .large {
                    stackedViewingControls
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            trackControls
                            Spacer(minLength: 12)
                            videoSizeButton
                            speedMenu
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        stackedViewingControls
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func currentChapterLabel(_ chapter: String) -> some View {
        Text(chapter)
            .font(.caption)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.white.opacity(0.85))
            .accessibilityIdentifier("player-current-chapter")
    }

    private var stackedViewingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { trackControls; Spacer(minLength: 0) }
            HStack { videoSizeButton; Spacer(minLength: 12); speedMenu }
        }
    }

    private var trackControls: some View {
        HStack(spacing: 12) {
                if app.player.isOfflinePlayback {
                    Button { showingDetails = true; noteInteraction() } label: {
                        Text("Audio").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Audio track")
                    .accessibilityFocused($assistiveFocus, equals: .audio)
                }
                if let item = app.player.item, !item.audioTracks.isEmpty {
                    audioMenu(item)
                }
                if !app.player.subtitleOptions.isEmpty || app.player.subtitleSelection.requested != nil {
                    captionMenu
                }
        }
    }

    private var videoSizeButton: some View {
        Button {
                    app.player.resizeMode = app.player.resizeMode == .fit ? .fill : .fit
                    noteInteraction()
                } label: {
                    Text(app.player.resizeMode.label)
                        .font(.subheadline.weight(.medium))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .foregroundStyle(.white)
                .accessibilityLabel("Video size: \(app.player.resizeMode.label)")
                .accessibilityHint("Switches between fitting the whole video and filling the screen")
                .accessibilityFocused($assistiveFocus, equals: .videoSize)
    }

    private var speedMenu: some View {
        Menu {
                    speedPicker
                } label: {
                    Text(speedLabel)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .frame(minWidth: 44, minHeight: 44)
                }
                .foregroundStyle(.white)
                .accessibilityLabel("Playback speed")
                .accessibilityValue(speedLabel)
                .accessibilityFocused($assistiveFocus, equals: .speed)
    }

    private func audioMenu(_ item: MediaItem) -> some View {
        Menu {
            Picker("Audio", selection: Binding(
                get: { app.player.selectedAudioIndex ?? item.defaultAudioIndex },
                set: {
                    app.player.selectAudio($0)
                    noteInteraction()
                }
            )) {
                ForEach(item.audioTracks) { track in
                    Text(audioLabel(track, defaultIndex: item.defaultAudioIndex)).tag(track.index)
                }
            }
        } label: {
            Text("Audio")
                .font(.subheadline.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
        }
        .foregroundStyle(.white)
        .accessibilityLabel("Audio track")
        .accessibilityFocused($assistiveFocus, equals: .audio)
    }

    private var captionMenu: some View {
        Menu {
            Button {
                app.player.turnSubtitlesOff()
                noteInteraction()
            } label: {
                if app.player.subtitleSelection == .off {
                    Label("Off", systemImage: "checkmark")
                } else {
                    Text("Off")
                }
            }
            ForEach(app.player.subtitleOptions) { caption in
                Button {
                    Task { await app.player.selectSubtitle(id: caption.id) }
                    noteInteraction()
                } label: {
                    if app.player.subtitleSelection.active?.id == caption.id {
                        Label(caption.selection.label, systemImage: "checkmark")
                    } else {
                        Text(caption.selection.label)
                    }
                }
                .disabled(!caption.isAvailable)
            }
        } label: {
            Image(systemName: app.player.subtitleSelection.active == nil
                  ? "captions.bubble"
                  : "captions.bubble.fill")
                .frame(minWidth: 44, minHeight: 44)
        }
        .foregroundStyle(.white)
        .accessibilityLabel("Subtitles")
        .accessibilityValue(app.player.subtitleSelection.accessibilityValue)
        .accessibilityFocused($assistiveFocus, equals: .subtitles)
    }

    private var speedPicker: some View {
        Picker("Speed", selection: Binding(
            get: { app.player.playbackSpeed },
            set: {
                app.player.setPlaybackSpeed($0)
                noteInteraction()
            }
        )) {
            ForEach(PlaybackSpeedOption.all) { option in
                Text(option.label).tag(option.value)
            }
        }
    }

    private var speedLabel: String {
        PlaybackSpeedOption.label(for: app.player.playbackSpeed)
    }

    private var activeChapterTitle: String? {
        guard let index = app.player.currentChapterIndex else { return nil }
        return app.player.chapters.first(where: { $0.id == index })?.title
    }

    private func subtitleView(_ subtitle: String) -> some View {
        VStack {
            Spacer()
            subtitleText(subtitle).padding(.horizontal, 24).padding(.bottom, 24)
        }
        .allowsHitTesting(false)
    }

    private func subtitleText(_ subtitle: String) -> some View {
        Text(subtitle)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 7))
                .shadow(radius: 2)
                .accessibilityLabel("Subtitles: \(subtitle)")
    }

    private func playbackError(_ message: String) -> some View {
        ScrollView {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle)
            Text("Playback couldn't continue").font(.headline)
            Text(message).font(.subheadline).multilineTextAlignment(.center)
            Text("At \(PlaybackTimeline.displayTime(app.player.currentTime))")
                .font(.subheadline.monospacedDigit())
                .accessibilityIdentifier("player-error-position")
                .accessibilityValue("\(Int(app.player.currentTime)) seconds")
            Button { app.player.retryCurrentPlayback() } label: {
                Text("Retry").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
                .accessibilityLabel("Retry Current Playback")
                .buttonStyle(.borderedProminent)
                .tint(Color("ActionFill"))
                .keyboardShortcut(.defaultAction)
                .accessibilityFocused($assistiveFocus, equals: .retry)
            if let retryLabel = app.player.retryLabel {
                Button { app.player.retryCompatible() } label: {
                    Text(retryLabel).frame(minHeight: 44).contentShape(Rectangle())
                }
                    .buttonStyle(.bordered)
                    .accessibilityFocused($assistiveFocus, equals: .compatibleRetry)
            }
            Button { app.player.stop() } label: {
                Text("Close").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
                .buttonStyle(.bordered)
                .accessibilityFocused($assistiveFocus, equals: .errorClose)
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 18))
        .padding()
        }
    }

    private func toggleControls() {
        usingKeyboard = false
        guard !voiceOverEnabled, !switchControlEnabled, assistiveFocus == nil else {
            controlsVisible = true
            return
        }
        withAnimation(controlAnimation) { controlsVisible.toggle() }
        if controlsVisible { scheduleAutoHide() } else { autoHideTask?.cancel() }
    }

    private func noteInteraction() {
        if !controlsVisible {
            withAnimation(controlAnimation) { controlsVisible = true }
        }
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        guard !dynamicTypeSize.isAccessibilitySize, !voiceOverEnabled, !switchControlEnabled,
              assistiveFocus == nil, !usingKeyboard,
              !showingDetails, !subtitleNeedsAttention, app.player.systemPlaybackNotice == nil,
              app.player.isPlaying, !isScrubbing, app.player.errorMessage == nil else { return }
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, app.player.isPlaying, !isScrubbing, !showingDetails,
                  !dynamicTypeSize.isAccessibilitySize, !usingKeyboard, !voiceOverEnabled,
                  !switchControlEnabled, assistiveFocus == nil,
                  !subtitleNeedsAttention, app.player.systemPlaybackNotice == nil else { return }
            withAnimation(controlAnimation) { controlsVisible = false }
        }
    }

    private func skip(_ direction: SeekDirection, revealControls: Bool) {
        app.player.skip(by: direction.seconds)
        if revealControls { noteInteraction() }
        feedbackTask?.cancel()
        withAnimation(controlAnimation) { seekFeedback = direction }
        UIAccessibility.post(notification: .announcement, argument: direction.accessibilityLabel)
        feedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            withAnimation(controlAnimation) { seekFeedback = nil }
        }
    }

    private var controlAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.15) }

    private var subtitleNeedsAttention: Bool {
        switch app.player.subtitleSelection {
        case .loading, .failed: true
        case .off, .active: false
        }
    }

    private func updatePictureInPicturePolicy() {
        let needsAcknowledgement = app.player.requiresSubtitleOutputAcknowledgement
        pictureInPicture.setAllowsAutomaticStart(!needsAcknowledgement)
        if needsAcknowledgement && pictureInPicture.isActive { pictureInPicture.stop() }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty else { return .ignored }
        if showingDetails {
            if press.key == .escape, press.phase == .down {
                showingDetails = false
                return .handled
            }
            return .ignored
        }
        if press.phase == .repeat && press.key != .leftArrow && press.key != .rightArrow { return .handled }
        usingKeyboard = true
        controlsVisible = true
        switch press.key {
        case .escape: app.player.stop()
        case .space:
            guard app.player.errorMessage == nil else { return .ignored }
            app.player.togglePlayback()
        case .leftArrow:
            guard app.player.errorMessage == nil else { return .ignored }
            skip(.backward, revealControls: true)
        case .rightArrow:
            guard app.player.errorMessage == nil else { return .ignored }
            skip(.forward, revealControls: true)
        case "o": showingDetails = true
        default: return .ignored
        }
        scheduleAutoHide()
        return .handled
    }

    private func audioLabel(_ track: AudioTrack, defaultIndex: Int?) -> String {
        let title = track.title ?? track.language?.uppercased() ?? "Track \(track.index + 1)"
        let defaultText = track.index == defaultIndex ? " · Default" : ""
        return "\(title) · \(track.codec.uppercased()) · \(track.channels) ch\(defaultText)"
    }
}

private enum PlayerControl: Hashable {
    case close, airPlay, pictureInPicture, options, backward, playPause, forward, position
    case audio, subtitles, videoSize, speed, retry, compatibleRetry, errorClose
}

private enum SeekDirection {
    case backward
    case forward

    var seconds: Double { self == .forward ? 10 : -10 }
    var icon: String { self == .forward ? "goforward.10" : "gobackward.10" }
    var accessibilityLabel: String { self == .forward ? "Forward 10 seconds" : "Rewind 10 seconds" }
    var alignment: Alignment { self == .forward ? .trailing : .leading }
}

private struct SeekFeedbackView: View {
    let direction: SeekDirection

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: direction.icon).font(.system(size: 32, weight: .semibold))
            Text("10 seconds").font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .frame(width: 112, height: 92)
        .background(.black.opacity(0.68), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(direction.accessibilityLabel)
        .accessibilityIdentifier("seek-feedback")
    }
}

private struct PlayerGestureLayer: View {
    let onSingleTap: () -> Void
    let onDoubleTapBack: () -> Void
    let onDoubleTapForward: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            tapZone(doubleTapAction: onDoubleTapBack)
            tapZone(doubleTapAction: onDoubleTapForward)
        }
        .accessibilityHidden(true)
    }

    private func tapZone(doubleTapAction: @escaping () -> Void) -> some View {
        Color.black.opacity(0.001)
            .contentShape(Rectangle())
            .gesture(
                TapGesture(count: 2)
                    .exclusively(before: TapGesture(count: 1))
                    .onEnded { result in
                        switch result {
                        case .first: doubleTapAction()
                        case .second: onSingleTap()
                        }
                    }
            )
    }
}

private struct PlayerIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    var diameter: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: diameter >= 56 ? 24 : 17, weight: .semibold))
                .frame(width: diameter, height: diameter)
                .background(.black.opacity(0.55), in: Circle())
                .contentShape(Rectangle())
        }
        .foregroundStyle(.white)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct PlayerScrubber: View {
    @Binding var value: Double
    let duration: Double
    let bufferedTime: Double
    let onEditingChanged: (Bool) -> Void
    let onCommit: (Double) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let played = PlaybackTimeline.progress(value, duration: duration)
            let buffered = PlaybackTimeline.progress(bufferedTime, duration: duration)

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28)).frame(height: 3)
                Capsule().fill(.white.opacity(0.55)).frame(width: width * buffered, height: 3)
                Capsule().fill(Color("AccessibleAccent")).frame(width: width * played, height: 4)
                Circle()
                    .fill(Color("AccessibleAccent"))
                    .frame(width: dragging ? 18 : 14, height: dragging ? 18 : 14)
                    .offset(x: min(width - (dragging ? 18 : 14), max(0, width * played - 7)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard duration > 0 else { return }
                        if !dragging {
                            dragging = true
                            onEditingChanged(true)
                        }
                        value = PlaybackTimeline.clampedTime(
                            Double(gesture.location.x / width) * duration,
                            duration: duration
                        )
                    }
                    .onEnded { _ in
                        guard dragging else { return }
                        dragging = false
                        onEditingChanged(false)
                        onCommit(value)
                    }
            )
        }
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(PlaybackTimeline.displayTime(value)) of \(PlaybackTimeline.displayTime(duration))")
        .accessibilityHint("Swipe up or down to move by 10 seconds")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 10.0 : -10.0
            value = PlaybackTimeline.skipTarget(currentTime: value, seconds: delta, duration: duration)
            onCommit(value)
        }
        .accessibilityIdentifier("playback-scrubber")
    }
}

private struct PlaybackSpeedOption: Identifiable {
    let value: Float
    var id: Float { value }
    var label: String { Self.label(for: value) }

    static let all = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2].map {
        PlaybackSpeedOption(value: Float($0))
    }

    static func label(for value: Float) -> String {
        value == 1 ? "1×" : String(format: "%g×", value)
    }
}

private struct LocalPlaybackOptionsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                speedAndSizeSection
                Section("Audio") {
                    if app.player.isLoadingLocalTracks { ProgressView("Reading audio tracks…") }
                    ForEach(app.player.localAudioTracks) { track in
                        Button { app.player.selectLocalAudio(track.id) } label: {
                            trackRow(track, selected: app.player.selectedLocalAudioID == track.id)
                        }
                        .accessibilityIdentifier("local-audio-\(track.id)")
                        .accessibilityValue(app.player.selectedLocalAudioID == track.id ? "Selected" : "Not selected")
                    }
                    if let description = app.player.offlineAudioDescription {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                }
                SubtitleOptionsSection(isOffline: true, dismissOnSelection: dismiss.callAsFunction)
                if !app.player.chapters.isEmpty {
                    Section("Chapters") {
                        ForEach(app.player.chapters) { chapter in
                            Button {
                                app.player.seek(toGlobalTime: chapter.startSeconds)
                                dismiss()
                            } label: {
                                PlaybackChapterLabel(title: chapter.title, start: chapter.startSeconds,
                                    isCurrent: chapter.id == app.player.currentChapterIndex)
                            }
                            .accessibilityIdentifier("local-chapter-\(chapter.id)")
                        }
                    }
                }
            }
            .navigationTitle("Playback Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .background(OptionsKeyboardDismissal(onDismiss: dismiss.callAsFunction).frame(width: 0, height: 0))
    }

    private func trackRow(_ track: LocalPlaybackTrack, selected: Bool) -> some View {
        HStack {
            Text(track.title + (track.isForced ? " · Forced" : "") + (track.isDefault ? " · Default" : ""))
            Spacer()
            if selected { Image(systemName: "checkmark") }
        }
    }

    private var speedAndSizeSection: some View {
        Section("Viewing") {
            Picker("Speed", selection: Binding(
                get: { app.player.playbackSpeed },
                set: { app.player.setPlaybackSpeed($0) }
            )) {
                ForEach(PlaybackSpeedOption.all) { Text($0.label).tag($0.value) }
            }
            Picker("Video Size", selection: Binding(
                get: { app.player.resizeMode },
                set: { app.player.resizeMode = $0 }
            )) {
                ForEach(VideoResizeMode.allCases) { Text($0.label).tag($0) }
            }
        }
    }
}

private struct PlaybackOptionsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: MediaItem
    @State private var draft: StreamingSettingsDraft

    init(item: MediaItem, mode: PlaybackMode, quality: String) {
        self.item = item
        _draft = State(initialValue: StreamingSettingsDraft(mode: mode, quality: quality))
    }

    private var profiles: [QualityProfile] {
        app.player.qualityProfiles ?? app.library.capabilities?.qualityProfiles ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Viewing") {
                    Picker("Speed", selection: Binding(
                        get: { app.player.playbackSpeed },
                        set: { app.player.setPlaybackSpeed($0) }
                    )) {
                        ForEach(PlaybackSpeedOption.all) { Text($0.label).tag($0.value) }
                    }
                    Picker("Video Size", selection: Binding(
                        get: { app.player.resizeMode },
                        set: { app.player.resizeMode = $0 }
                    )) {
                        ForEach(VideoResizeMode.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("Streaming") {
                    if let notice = app.player.qualityNotice {
                        Text(notice)
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("stream-quality-notice")
                    }
                    Menu {
                        Picker("Mode", selection: Binding(
                            get: { draft.mode },
                            set: { draft.selectMode($0) }
                        )) {
                            ForEach(PlaybackMode.allCases) { Text($0.label).tag($0) }
                        }
                    } label: {
                        streamingPreferenceLabel("Mode", value: draft.mode.label)
                    }
                    .accessibilityIdentifier("stream-mode")
                    .accessibilityLabel("Mode")
                    .accessibilityValue(draft.mode.label)
                    Menu {
                        Picker("Quality", selection: Binding(
                            get: { draft.quality },
                            set: { draft.selectQuality($0) }
                        )) {
                            if !profiles.contains(where: { $0.id == "auto" }) { Text("Auto").tag("auto") }
                            ForEach(profiles) { profile in
                                Text(profile.label).tag(profile.id)
                            }
                        }
                    } label: {
                        streamingPreferenceLabel("Quality", value: selectedQualityLabel)
                    }
                    .accessibilityIdentifier("stream-quality")
                    .accessibilityLabel("Quality")
                    .accessibilityValue(selectedQualityLabel)
                    Button("Apply Streaming Changes") {
                        if app.player.applyStreamingChanges(draft, profiles: profiles) { dismiss() }
                    }
                    .disabled(!draft.isValid(in: profiles))
                }
                if !item.audioTracks.isEmpty { audioSection }
                if !app.player.subtitleOptions.isEmpty { subtitleSection }
                if !item.chapters.isEmpty { chapterSection }
            }
            .navigationTitle("Playback Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .background(OptionsKeyboardDismissal(onDismiss: dismiss.callAsFunction).frame(width: 0, height: 0))
    }

    private var selectedQualityLabel: String {
        profiles.first(where: { $0.id == draft.quality })?.label ?? "Auto"
    }

    private func streamingPreferenceLabel(_ title: String, value: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text(title).foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value).foregroundStyle(Color.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var audioSection: some View {
        Section("Audio") {
            ForEach(item.audioTracks) { track in
                Button {
                    app.player.selectAudio(track.index)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(track.title ?? track.language?.uppercased() ?? "Track \(track.index + 1)")
                            Text("\(track.codec.uppercased()) · \(track.channels) channels\(track.index == item.defaultAudioIndex ? " · Default" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if track.index == app.player.selectedAudioIndex {
                            Image(systemName: "checkmark").foregroundStyle(Color("AccessibleAccent"))
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
    }

    private var subtitleSection: some View {
        SubtitleOptionsSection(isOffline: false, dismissOnSelection: dismiss.callAsFunction)
    }

    private var chapterSection: some View {
        Section("Chapters") {
            ForEach(item.chapters) { chapter in
                Button {
                    app.player.seek(toGlobalTime: chapter.startSeconds)
                    dismiss()
                } label: {
                    PlaybackChapterLabel(title: chapter.title, start: chapter.startSeconds,
                        isCurrent: app.player.currentChapterIndex == chapter.index)
                }
                .foregroundStyle(.primary)
            }
        }
    }

    private func optionRow(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(Color("AccessibleAccent")) }
        }
    }
}

private struct PlaybackChapterLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let start: Double
    let isCurrent: Bool

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout())
        layout {
            Text(title).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            metadata.font(dynamicTypeSize.isAccessibilitySize ? .caption : nil)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var metadata: some View {
        HStack(spacing: 8) {
            Text(PlaybackTimeline.displayTime(start)).foregroundStyle(.secondary)
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(Color("AccessibleAccent"))
                    .accessibilityLabel("Current chapter")
            }
        }
    }
}

/// A sheet has a separate responder chain from the presenting SwiftUI player.
/// Acquire it after presentation so Escape does not depend on a List row's focus.
private struct OptionsKeyboardDismissal: UIViewControllerRepresentable {
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> OptionsKeyboardController {
        let controller = OptionsKeyboardController()
        controller.onDismiss = onDismiss
        return controller
    }

    func updateUIViewController(_ controller: OptionsKeyboardController, context: Context) {
        controller.onDismiss = onDismiss
    }

    static func dismantleUIViewController(_ controller: OptionsKeyboardController, coordinator: Void) {
        controller.releaseKeyboard()
        controller.onDismiss = nil
    }
}

private final class OptionsKeyboardController: UIViewController {
    var onDismiss: (() -> Void)?
    private var ownsKeyboard = false

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let command = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeOptions(_:)))
        command.discoverabilityTitle = "Close Playback Options"
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(closeOptions(_:)) {
            return ownsKeyboard && view.window != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if action == #selector(closeOptions(_:)) {
            return ownsKeyboard && view.window != nil ? self : nil
        }
        return super.target(forAction: action, withSender: sender)
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.accessibilityElementsHidden = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ownsKeyboard = true
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        releaseKeyboard()
        super.viewWillDisappear(animated)
    }

    func releaseKeyboard() {
        ownsKeyboard = false
        resignFirstResponder()
    }

    @objc private func closeOptions(_ command: UIKeyCommand) {
        guard ownsKeyboard, view.window != nil else { return }
        releaseKeyboard()
        onDismiss?()
    }
}
