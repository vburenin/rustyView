import AVKit
import SwiftUI

struct PlayerScreen: View {
    @EnvironmentObject private var app: AppModel
    @State private var showingDetails = false
    @State private var controlsVisible = true
    @State private var isScrubbing = false
    @State private var scrubberTime = 0.0
    @State private var seekFeedback: SeekDirection?
    @State private var feedbackTask: Task<Void, Never>?
    @State private var autoHideTask: Task<Void, Never>?
    @StateObject private var pictureInPicture = PlayerPictureInPictureController()

    var body: some View {
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

            if controlsVisible {
                controls
                    .transition(.opacity)
            }

            if let subtitle = app.player.currentSubtitle {
                subtitleView(subtitle)
            }

            if let seekFeedback {
                SeekFeedbackView(direction: seekFeedback)
                    .frame(maxWidth: .infinity, alignment: seekFeedback.alignment)
                    .padding(.horizontal, 36)
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            if app.player.isPreparing {
                ProgressView("Preparing video…")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .padding()
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityAddTraits(.updatesFrequently)
            }

            if app.player.isBuffering && !app.player.isPreparing {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .padding(18)
                    .background(.black.opacity(0.68), in: Circle())
                    .accessibilityLabel("Buffering video")
                    .accessibilityAddTraits(.updatesFrequently)
            }

            if let message = app.player.errorMessage {
                playbackError(message)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear {
            scrubberTime = app.player.currentTime
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
                withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true }
            }
        }
        .onChange(of: app.player.isPreparing) { _, preparing in
            if !preparing { scheduleAutoHide() }
        }
        .sheet(isPresented: $showingDetails) {
            if let item = app.player.item {
                PlaybackOptionsView(item: item)
                    .presentationDetents([.medium, .large])
            } else {
                LocalPlaybackOptionsView()
                    .presentationDetents([.height(260)])
            }
        }
        .alert(
            "Picture in Picture unavailable",
            isPresented: Binding(
                get: { pictureInPicture.errorMessage != nil },
                set: { if !$0 { pictureInPicture.errorMessage = nil } }
            )
        ) {
            Button("OK") { pictureInPicture.errorMessage = nil }
        } message: {
            Text(pictureInPicture.errorMessage ?? "Please try again.")
        }
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

            VStack(spacing: 0) {
                topControls
                Spacer(minLength: 20)
                centerControls
                Spacer(minLength: 20)
                bottomControls
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
    }

    private var topControls: some View {
        HStack(spacing: 10) {
            PlayerIconButton(
                systemName: "xmark",
                accessibilityLabel: "Close player",
                action: app.player.stop
            )

            Text(app.player.currentTitle ?? "Now Playing")
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.white)
                .accessibilityIdentifier("player-title")

            Spacer(minLength: 4)

            AirPlayRoutePicker()
                .frame(width: 44, height: 44)

            if AVPictureInPictureController.isPictureInPictureSupported() {
                PlayerIconButton(
                    systemName: pictureInPicture.isActive
                        ? "pip.exit"
                        : "pip.enter",
                    accessibilityLabel: pictureInPicture.isActive
                        ? "Stop Picture in Picture"
                        : "Start Picture in Picture"
                ) {
                    pictureInPicture.toggle()
                    noteInteraction()
                }
                .disabled(!pictureInPicture.isPossible && !pictureInPicture.isActive)
            }

            PlayerIconButton(systemName: "gearshape", accessibilityLabel: "Playback options") {
                showingDetails = true
                noteInteraction()
            }
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

            Button {
                app.player.togglePlayback()
                noteInteraction()
            } label: {
                Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 31, weight: .semibold))
                    .offset(x: app.player.isPlaying ? 0 : 2)
                    .frame(width: 72, height: 72)
                    .background(.black.opacity(0.62), in: Circle())
            }
            .foregroundStyle(.white)
            .contentShape(Circle())
            .accessibilityLabel(app.player.isPlaying ? "Pause" : "Play")
            .accessibilityHint("Double tap to toggle playback")
            .accessibilityIdentifier("play-pause-control")

            PlayerIconButton(
                systemName: "goforward.10",
                accessibilityLabel: "Forward 10 seconds",
                diameter: 56
            ) {
                skip(.forward, revealControls: true)
            }
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Text(PlaybackTimeline.displayTime(scrubberTime))
                Text("/").foregroundStyle(.white.opacity(0.65))
                Text(PlaybackTimeline.displayTime(app.player.duration))
                Spacer()
                if let chapter = activeChapterTitle {
                    Text(chapter)
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
            .accessibilityElement(children: .combine)
            .accessibilityValue("\(Int(scrubberTime)) seconds elapsed")
            .accessibilityIdentifier("player-time-label")

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

            HStack(spacing: 12) {
                if let item = app.player.item, !item.audioTracks.isEmpty {
                    audioMenu(item)
                }
                if let item = app.player.item, !item.captions.isEmpty {
                    captionMenu(item)
                }

                Spacer()

                Button {
                    app.player.resizeMode = app.player.resizeMode == .fit ? .fill : .fit
                    noteInteraction()
                } label: {
                    Label(app.player.resizeMode.label, systemImage: app.player.resizeMode.icon)
                        .font(.subheadline.weight(.medium))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .foregroundStyle(.white)
                .accessibilityLabel("Video size: \(app.player.resizeMode.label)")
                .accessibilityHint("Switches between fitting the whole video and filling the screen")

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
            }
        }
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
            Label("Audio", systemImage: "waveform")
                .font(.subheadline.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
        }
        .foregroundStyle(.white)
        .accessibilityLabel("Audio track")
    }

    private func captionMenu(_ item: MediaItem) -> some View {
        Menu {
            Button {
                Task { await app.player.selectCaption(nil) }
                noteInteraction()
            } label: {
                if app.player.selectedCaptionIndex == nil {
                    Label("Off", systemImage: "checkmark")
                } else {
                    Text("Off")
                }
            }
            ForEach(item.captions) { caption in
                Button {
                    Task { await app.player.selectCaption(caption.index) }
                    noteInteraction()
                } label: {
                    if app.player.selectedCaptionIndex == caption.index {
                        Label(caption.label, systemImage: "checkmark")
                    } else {
                        Text(caption.label)
                    }
                }
                .disabled(!caption.isPlayableOnDevice)
            }
        } label: {
            Image(systemName: app.player.selectedCaptionIndex == nil
                  ? "captions.bubble"
                  : "captions.bubble.fill")
                .frame(width: 44, height: 44)
        }
        .foregroundStyle(.white)
        .accessibilityLabel("Subtitles")
        .accessibilityValue(app.player.selectedCaptionIndex == nil ? "Off" : "On")
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
        guard let item = app.player.item, let index = app.player.currentChapterIndex else { return nil }
        return item.chapters.first(where: { $0.index == index })?.title
    }

    private func subtitleView(_ subtitle: String) -> some View {
        VStack {
            Spacer()
            Text(subtitle)
                .font(.body.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 7))
                .shadow(radius: 2)
                .padding(.horizontal, 24)
                .padding(.bottom, controlsVisible ? 132 : 24)
                .animation(.easeOut(duration: 0.15), value: controlsVisible)
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Subtitles: \(subtitle)")
    }

    private func playbackError(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle)
            Text("Playback couldn't continue").font(.headline)
            Text(message).font(.subheadline).multilineTextAlignment(.center)
            if let retryLabel = app.player.retryLabel {
                Button(retryLabel) { app.player.retryCompatible() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("AccessibleAccent"))
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 18))
        .padding()
    }

    private func toggleControls() {
        withAnimation(.easeOut(duration: 0.15)) { controlsVisible.toggle() }
        if controlsVisible { scheduleAutoHide() } else { autoHideTask?.cancel() }
    }

    private func noteInteraction() {
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true }
        }
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        guard app.player.isPlaying, !isScrubbing, app.player.errorMessage == nil else { return }
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, app.player.isPlaying, !isScrubbing else { return }
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
        }
    }

    private func skip(_ direction: SeekDirection, revealControls: Bool) {
        app.player.skip(by: direction.seconds)
        if revealControls { noteInteraction() }
        feedbackTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) { seekFeedback = direction }
        UIAccessibility.post(notification: .announcement, argument: direction.accessibilityLabel)
        feedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.15)) { seekFeedback = nil }
        }
    }

    private func audioLabel(_ track: AudioTrack, defaultIndex: Int?) -> String {
        let title = track.title ?? track.language?.uppercased() ?? "Track \(track.index + 1)"
        let defaultText = track.index == defaultIndex ? " · Default" : ""
        return "\(title) · \(track.codec.uppercased()) · \(track.channels) ch\(defaultText)"
    }
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
        }
        .foregroundStyle(.white)
        .contentShape(Circle())
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
            }
            .navigationTitle("Playback Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
    let item: MediaItem

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
                    Picker("Mode", selection: Binding(
                        get: { app.player.mode },
                        set: { app.player.mode = $0 }
                    )) {
                        ForEach(PlaybackMode.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Quality", selection: Binding(
                        get: { app.player.selectedQuality },
                        set: { app.player.selectedQuality = $0 }
                    )) {
                        ForEach(app.library.capabilities?.qualityProfiles ?? []) { profile in
                            Text(profile.label).tag(profile.id)
                        }
                    }
                    Button("Apply Streaming Changes") {
                        app.player.play(
                            item,
                            mode: app.player.mode,
                            quality: app.player.selectedQuality,
                            audioIndex: app.player.selectedAudioIndex
                        )
                        dismiss()
                    }
                }
                if !item.audioTracks.isEmpty { audioSection }
                if !item.captions.isEmpty { subtitleSection }
                if !item.chapters.isEmpty { chapterSection }
            }
            .navigationTitle("Playback Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
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
        Section("Subtitles") {
            Button {
                Task {
                    await app.player.selectCaption(nil)
                    dismiss()
                }
            } label: {
                optionRow("Off", selected: app.player.selectedCaptionIndex == nil)
            }
            .foregroundStyle(.primary)
            ForEach(item.captions) { caption in
                Button {
                    Task {
                        await app.player.selectCaption(caption.index)
                        if app.player.subtitleError == nil { dismiss() }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(caption.label)
                            Text(caption.isPlayableOnDevice ? caption.sourceFormat.uppercased() : "Unavailable on this device")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if app.player.selectedCaptionIndex == caption.index {
                            Image(systemName: "checkmark").foregroundStyle(Color("AccessibleAccent"))
                        }
                    }
                }
                .foregroundStyle(.primary)
                .disabled(!caption.isPlayableOnDevice)
                .accessibilityIdentifier("caption-track-\(caption.index)")
            }
            if let error = app.player.subtitleError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var chapterSection: some View {
        Section("Chapters") {
            ForEach(item.chapters) { chapter in
                Button {
                    app.player.seek(toGlobalTime: chapter.startSeconds)
                    dismiss()
                } label: {
                    HStack {
                        Text(chapter.title)
                        Spacer()
                        Text(PlaybackTimeline.displayTime(chapter.startSeconds)).foregroundStyle(.secondary)
                        if app.player.currentChapterIndex == chapter.index {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(Color("AccessibleAccent"))
                                .accessibilityLabel("Current chapter")
                        }
                    }
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
