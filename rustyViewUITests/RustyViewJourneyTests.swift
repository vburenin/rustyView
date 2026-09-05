import Network
import UIKit
import XCTest

final class RustyViewJourneyTests: XCTestCase {
    private var server: SyntheticHTTPServer?
    private var testNamespace = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        testNamespace = UUID().uuidString.lowercased()
        server = try SyntheticHTTPServer()
        try server?.start()
    }

    override func tearDown() {
        XCUIApplication().terminate()
        server?.stop()
        server = nil
        super.tearDown()
    }

    func testBrowseToMovieAndExposeEssentialViewingControls() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = try launchApp()

        let title = app.staticTexts["The Clockwork Orchard"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), "Authenticated library content should replace loading state")

        app.buttons["Browse"].tap()
        XCTAssertTrue(app.buttons["Folders"].waitForExistence(timeout: 2))
        app.buttons["Folders"].tap()
        let folder = app.staticTexts["Invented Shelf"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.tap()
        XCTAssertTrue(app.navigationBars["Invented Shelf"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Parent folder"].exists)
        app.buttons["Parent folder"].tap()
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        app.buttons["Browse"].tap()
        app.buttons["All Movies"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()

        let initialControls = ["Watch", "Audio", "Quality", "Download"].map { app.buttons[$0] }
        for control in initialControls {
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            XCTAssertTrue(control.isHittable, "Essential movie controls must be visible without scrolling")
        }
        XCTAssertTrue(app.staticTexts["3840x2160"].exists)
        XCTAssertTrue(app.staticTexts["HDR10"].exists)
        XCTAssertTrue(app.staticTexts["About"].exists)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Watch"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Audio"].exists)
        XCTAssertTrue(app.buttons["Quality"].exists)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(
            app.buttons["Watch"].waitForExistence(timeout: 8),
            "The primary action must survive the landscape-to-portrait layout transition"
        )

        app.buttons["Audio"].tap()
        let selectedAudio = app.buttons.matching(NSPredicate(format: "label CONTAINS 'French dub'")).firstMatch
        XCTAssertTrue(selectedAudio.waitForExistence(timeout: 2))
        selectedAudio.tap()
        XCTAssertEqual(
            app.buttons["Audio"].value as? String,
            "French dub · AAC · Stereo",
            "The movie page must keep the selected audio track visible after closing the menu"
        )

        app.buttons["Quality"].tap()
        let fullHD = app.buttons.matching(NSPredicate(format: "label CONTAINS '1080p'")).firstMatch
        XCTAssertTrue(fullHD.waitForExistence(timeout: 2))
        fullHD.tap()
        XCTAssertEqual(
            app.buttons["Quality"].value as? String,
            "1080p · 8 Mbps",
            "The movie page must keep the selected quality visible after closing the menu"
        )

        // Return to Auto so quality does not force routing. The non-default audio choice
        // must still bypass the untouched original and use a prepared stream.
        app.buttons["Quality"].tap()
        let automaticQuality = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Auto'"))
            .firstMatch
        XCTAssertTrue(automaticQuality.waitForExistence(timeout: 2))
        automaticQuality.tap()

        app.buttons["Watch"].tap()
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["The Clockwork Orchard"].exists)
        XCTAssertTrue(app.staticTexts["Preparing video…"].waitForNonExistence(timeout: 10))
        let playbackError = app.staticTexts["Playback couldn't continue"]
        XCTAssertFalse(
            playbackError.exists,
            "Player UI: \(app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")); requests: \(server?.requestSummary ?? "server unavailable")"
        )
        XCTAssertEqual(
            server?.mediaRequestCount,
            0,
            "a non-default audio choice must not start the untouched original stream"
        )
        XCTAssertGreaterThan(
            server?.preparedSegmentRequestCount ?? 0,
            0,
            "AVPlayer must recover through the authenticated compatible HLS stream and fetch its real media segment"
        )
        XCTAssertGreaterThan(
            server?.portablePlaylistRequestCount ?? 0,
            0,
            "A copied prepared stream failure must escalate to portable H.264/AAC output"
        )

        XCTAssertGreaterThan(
            server?.unauthorizedMediaRequestCount ?? 0,
            0,
            "The protected media endpoint must issue a real Basic-auth challenge before AVFoundation retries with credentials"
        )

        let pause = app.buttons["Pause"]
        let play = app.buttons["Play"]
        if pause.exists {
            pause.tap()
            XCTAssertTrue(play.waitForExistence(timeout: 2), "Pausing must change the actual transport state")
        } else {
            if !play.exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            XCTAssertTrue(play.waitForExistence(timeout: 2), "The custom player must expose its actual transport state")
            play.tap()
            XCTAssertTrue(pause.waitForExistence(timeout: 3), "Playing must change the actual transport state")
            pause.tap()
            XCTAssertTrue(play.waitForExistence(timeout: 2), "Pausing must change the actual transport state")
        }
        XCTAssertTrue(app.buttons["Rewind 10 seconds"].exists)
        XCTAssertTrue(app.buttons["Forward 10 seconds"].exists)
        XCTAssertTrue(app.otherElements["playback-scrubber"].exists)
        XCTAssertTrue(app.buttons["Audio track"].exists)
        XCTAssertTrue(app.buttons["Subtitles"].exists)
        XCTAssertTrue(app.buttons["Playback speed"].exists)
        for label in ["Rewind 10 seconds", "Play", "Forward 10 seconds", "Audio track", "Subtitles", "Playback speed"] {
            let control = app.buttons[label]
            XCTAssertGreaterThanOrEqual(control.frame.width, 43.5, "\(label) must have a 44-point touch target")
            XCTAssertGreaterThanOrEqual(control.frame.height, 43.5, "\(label) must have a 44-point touch target")
        }

        let timeline = app.descendants(matching: .any)
            .matching(identifier: "player-time-label").firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 2))
        let beforeForward = try elapsedSeconds(from: timeline)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: 0.5)).doubleTap()
        let seekFeedback = app.descendants(matching: .any)
            .matching(identifier: "seek-feedback").firstMatch
        XCTAssertTrue(seekFeedback.waitForExistence(timeout: 2))
        XCTAssertEqual(seekFeedback.label, "Forward 10 seconds")
        let afterForward = try waitForElapsedSeconds(in: timeline, atLeast: beforeForward + 9)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.14, dy: 0.5)).doubleTap()
        XCTAssertTrue(
            waitForElapsedSeconds(in: timeline, atMost: afterForward - 9, timeout: 2),
            "Double-tapping the left half must seek the real player backward by 10 seconds"
        )

        XCTAssertTrue(seekFeedback.waitForNonExistence(timeout: 2))
        let scrubber = app.otherElements["playback-scrubber"]
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).tap()
        let preparedSeek = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                (self?.server?.largestPreparedStartSeconds ?? 0) > 2_000
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [preparedSeek], timeout: 5),
            .completed,
            "Scrubbing beyond a growing EVENT playlist must request a new prepared stream at the global target"
        )
        if !app.buttons["Close player"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 2))
        let playerScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        playerScreenshot.name = "Custom player controls"
        playerScreenshot.lifetime = .keepAlways
        add(playerScreenshot)

        app.buttons["Playback options"].tap()
        XCTAssertTrue(app.navigationBars["Playback Options"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Audio"].exists)
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Subtitles"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Chapters"].waitForExistence(timeout: 2))
        let caption = app.buttons["caption-track-0"]
        XCTAssertTrue(caption.waitForExistence(timeout: 2))
        caption.tap()
        XCTAssertTrue(
            app.staticTexts["Subtitles: Synthetic subtitle."].waitForExistence(timeout: 3),
            "Selecting a server-converted WebVTT track must display its actual cue"
        )
        XCTAssertGreaterThan(server?.captionRequestCount ?? 0, 0)
        app.buttons["Playback options"].tap()
        XCTAssertTrue(app.navigationBars["Playback Options"].waitForExistence(timeout: 3))
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Chapters"].waitForExistence(timeout: 2))
        app.buttons["Done"].tap()
        app.buttons["Close player"].tap()
        XCTAssertTrue(
            app.buttons["Download"].waitForExistence(timeout: 3),
            "Closing playback after a meaningful seek must return to the same movie details"
        )

        app.buttons["Download"].tap()
        XCTAssertTrue(app.buttons["Compatible copy"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Original file"].exists)
        app.buttons["Compatible copy"].tap()

        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Downloads"].firstMatch.tap()
        let activeDownload = app.descendants(matching: .any)["active-download-42001"]
        XCTAssertTrue(
            activeDownload.waitForExistence(timeout: 3),
            "A selected movie must immediately appear in the background download queue"
        )
        let retryReachedServer = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                (self?.server?.compatibleDownloadRequestCount ?? 0) == 2
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [retryReachedServer], timeout: 10),
            .completed,
            "A transient HTTP failure must produce a second real download request"
        )
        XCTAssertGreaterThan(
            app.progressIndicators.count,
            0,
            "The active queue row must expose download progress while bytes are in flight"
        )
        let preparationProgress = app.staticTexts["preparation-progress-42001"]
        XCTAssertTrue(
            preparationProgress.waitForExistence(timeout: 4),
            "A compatible download must expose progress measured in produced media time"
        )
        XCTAssertEqual(preparationProgress.label, "Prepared 23:02 of 1:32:08 · 25%")
        XCUIDevice.shared.press(.home)
        let backgroundTransfer = expectation(description: "background transfer finishes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { backgroundTransfer.fulfill() }
        wait(for: [backgroundTransfer], timeout: 11)
        app.activate()
        XCTAssertTrue(
            app.staticTexts["The Clockwork Orchard"].firstMatch.waitForExistence(timeout: 5),
            "The system-owned transfer must finish while the app is suspended"
        )
        XCTAssertTrue(
            activeDownload.waitForNonExistence(timeout: 8),
            "An in-flight system background download must finish while the app is suspended"
        )
        app.buttons["Library"].firstMatch.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.tap()

        XCTAssertTrue(
            app.staticTexts["Available offline"].waitForExistence(timeout: 10),
            "A successful background HTTP download must become a playable offline record"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["offline-copy-available"].exists,
            "The movie header must make the installed offline copy immediately visible"
        )
        XCTAssertEqual(
            server?.compatibleDownloadRequestCount,
            2,
            "A transient server failure must produce exactly one automatic retry"
        )
        XCTAssertTrue(app.buttons["Watch Offline"].exists)
        XCTAssertTrue(app.buttons["Remove Download"].exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'On device:'")
        ).firstMatch.exists)

        let networkRequestsBeforeOfflinePlayback = server?.requestCount
        app.buttons["Watch Offline"].tap()
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Preparing video…"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Playback couldn't continue"].exists)
        XCTAssertEqual(
            server?.requestCount,
            networkRequestsBeforeOfflinePlayback,
            "Offline playback must not contact the server"
        )

        app.buttons["Close player"].tap()
        server?.stop()
        let requestsBeforeOfflineRelaunch = server?.requestCount
        app.terminate()
        app.launch()
        let downloadsTab = app.buttons["Downloads"].firstMatch
        XCTAssertTrue(downloadsTab.waitForExistence(timeout: 5))
        downloadsTab.tap()
        let persistedDownload = app.staticTexts["The Clockwork Orchard"].firstMatch
        XCTAssertTrue(
            persistedDownload.waitForExistence(timeout: 5),
            "The completed download must survive process termination"
        )
        XCTAssertEqual(
            app.staticTexts["downloaded-quality-42001"].label,
            "Quality: Compatible · Auto · Best"
        )
        XCTAssertEqual(
            app.staticTexts["downloaded-audio-42001"].label,
            "Audio: French dub · AAC · Stereo · Track ID 0"
        )
        XCTAssertTrue(app.staticTexts["Downloaded video storage"].exists)
        let deleteButtons = app.buttons.matching(NSPredicate(format: "label == 'Delete offline copy'"))
        XCTAssertGreaterThan(deleteButtons.count, 0)
        persistedDownload.tap()
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Preparing video…"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Playback couldn't continue"].exists)
        XCTAssertEqual(
            server?.requestCount,
            requestsBeforeOfflineRelaunch,
            "Relaunched offline playback must remain independent of the unavailable server"
        )
        app.buttons["Close player"].tap()
        let deleteButton = deleteButtons.firstMatch
        let deletedRecordIdentifier = deleteButton.identifier
        XCTAssertFalse(deletedRecordIdentifier.isEmpty)
        deleteButton.tap()
        let deleteAlert = app.alerts["Delete offline copy?"]
        XCTAssertTrue(deleteAlert.waitForExistence(timeout: 2))
        deleteAlert.buttons["Delete"].tap()
        XCTAssertTrue(
            app.buttons[deletedRecordIdentifier].waitForNonExistence(timeout: 3),
            "Deleting an offline movie must remove exactly one installed file from the downloaded library"
        )
    }

    private func elapsedSeconds(from element: XCUIElement) throws -> Int {
        let value = try XCTUnwrap(element.value as? String)
        let number = try XCTUnwrap(Int(value.split(separator: " ").first ?? ""))
        return number
    }

    @discardableResult
    private func waitForElapsedSeconds(
        in element: XCUIElement,
        atLeast minimum: Int,
        timeout: TimeInterval = 3
    ) throws -> Int {
        let predicate = NSPredicate { evaluated, _ in
            guard let element = evaluated as? XCUIElement,
                  let value = element.value as? String,
                  let number = Int(value.split(separator: " ").first ?? "") else { return false }
            return number >= minimum
        }
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
        return try elapsedSeconds(from: element)
    }

    private func waitForElapsedSeconds(
        in element: XCUIElement,
        atMost maximum: Int,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate { evaluated, _ in
            guard let element = evaluated as? XCUIElement,
                  let value = element.value as? String,
                  let number = Int(value.split(separator: " ").first ?? "") else { return false }
            return number <= maximum
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    func testLibraryAndDetailsPassAccessibilityAudit() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = try launchApp()
        let title = app.staticTexts["The Clockwork Orchard"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))

        let audits: XCUIAccessibilityAuditType = [
            .contrast,
            .elementDetection,
            .hitRegion,
            .sufficientElementDescription,
            .textClipped,
            .trait,
        ]
        try app.performAccessibilityAudit(for: audits, ignoringVerifiedAuditFalsePositives)

        title.tap()
        XCTAssertTrue(app.buttons["Watch"].waitForExistence(timeout: 5))
        try app.performAccessibilityAudit(for: audits, ignoringVerifiedAuditFalsePositives)
    }

    func testAccessibilityXXXLLayoutKeepsCoreActionsReachable() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = try launchApp(arguments: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        let title = app.staticTexts["The Clockwork Orchard"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Browse"].isHittable)
        XCTAssertTrue(app.buttons["Sort"].isHittable)

        title.tap()
        let watch = app.buttons["Watch"]
        XCTAssertTrue(watch.waitForExistence(timeout: 5))
        if !watch.isHittable { app.swipeUp() }
        XCTAssertTrue(watch.isHittable, "Watch must remain reachable at the largest accessibility text size")
    }

    func testLargerTextUsesTwoColumnsWithoutTitleAndRuntimeOverlap() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = try launchApp(arguments: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryXL",
        ])
        let cards = ["42001", "42002", "42003"].map {
            app.descendants(matching: .any)["library-card-\($0)"]
        }
        for card in cards {
            XCTAssertTrue(card.waitForExistence(timeout: 8), "Every large-text card should render")
        }

        let frames = cards.map(\.frame)
        XCTAssertLessThanOrEqual(
            abs(frames[0].minY - frames[1].minY),
            2,
            "The first two posters should share a row at larger text sizes"
        )
        XCTAssertGreaterThan(
            frames[2].minY,
            frames[0].maxY,
            "The third poster should start a second row instead of squeezing into a third column"
        )
        XCTAssertGreaterThan(
            frames.map(\.width).min() ?? 0,
            145,
            "Two-column cards should provide enough width for enlarged titles and metadata"
        )

        let title = app.staticTexts["The Clockwork Orchard"]
        let runtime = app.staticTexts["1:32:08"].firstMatch
        XCTAssertTrue(title.exists)
        XCTAssertTrue(runtime.exists)
        XCTAssertLessThanOrEqual(
            title.frame.maxY,
            runtime.frame.minY + 1,
            "An enlarged movie title must never draw over its runtime"
        )
    }

    func testCellularDownloadSettingCanDisableAndReenableCellular() throws {
        let app = try launchApp()
        app.buttons["Settings"].firstMatch.tap()
        let networkMenu = app.buttons["download-network-menu"]
        XCTAssertTrue(networkMenu.waitForExistence(timeout: 3))
        networkMenu.tap()
        XCTAssertTrue(app.buttons["Wi-Fi Only"].waitForExistence(timeout: 2))
        app.buttons["Wi-Fi Only"].tap()
        XCTAssertTrue(app.staticTexts["Downloads wait for Wi-Fi and resume automatically when it is available."].exists)

        networkMenu.tap()
        XCTAssertTrue(app.buttons["Wi-Fi & Cellular"].waitForExistence(timeout: 2))
        app.buttons["Wi-Fi & Cellular"].tap()
        XCTAssertTrue(app.staticTexts["Downloads may use Wi-Fi or cellular data."].exists)
    }

    func testOriginalDownloadChoiceQueuesImmediatelyWithoutAnotherConfirmation() throws {
        let app = try launchApp()
        let title = app.staticTexts["The Clockwork Orchard"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.tap()
        XCTAssertTrue(app.buttons["Download"].waitForExistence(timeout: 5))

        app.buttons["Download"].tap()
        XCTAssertTrue(app.buttons["Original file"].waitForExistence(timeout: 2))
        app.buttons["Original file"].tap()

        XCTAssertTrue(
            app.buttons["Cancel Download"].waitForExistence(timeout: 3),
            "Choosing Original file must immediately replace the menu with an active queue state"
        )
        let requestReachedServer = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                (self?.server?.originalDownloadRequestCount ?? 0) == 1
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [requestReachedServer], timeout: 5),
            .completed,
            "The first rendition choice must issue the authenticated download request without a second confirmation"
        )

        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Downloads"].firstMatch.tap()
        let activeDownload = app.descendants(matching: .any)["active-download-42001"]
        XCTAssertTrue(activeDownload.waitForExistence(timeout: 3))
        activeDownload.staticTexts["The Clockwork Orchard"].tap()
        XCTAssertTrue(app.navigationBars["The Clockwork Orchard"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.buttons["Cancel Download"].waitForExistence(timeout: 5),
            "Opening an active movie must show its details without removing it from the queue"
        )
        app.buttons["Cancel Download"].tap()
    }

    func testCompatibleDownloadShowsTimestampBasedPreparationProgress() throws {
        let app = try launchApp()
        let title = app.staticTexts["The Clockwork Orchard"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.tap()
        XCTAssertTrue(app.buttons["Download"].waitForExistence(timeout: 5))
        app.buttons["Audio"].tap()
        let alternateAudio = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'French dub'")
        ).firstMatch
        XCTAssertTrue(alternateAudio.waitForExistence(timeout: 2))
        alternateAudio.tap()
        app.buttons["Quality"].tap()
        let fullHD = app.buttons.matching(NSPredicate(format: "label CONTAINS '1080p'")).firstMatch
        XCTAssertTrue(fullHD.waitForExistence(timeout: 2))
        fullHD.tap()
        app.buttons["Download"].tap()
        XCTAssertTrue(app.buttons["Compatible copy"].waitForExistence(timeout: 2))
        app.buttons["Compatible copy"].tap()

        XCTAssertTrue(app.buttons["Cancel Download"].waitForExistence(timeout: 3))
        XCTAssertEqual(
            app.staticTexts["active-download-quality"].label,
            "Quality: Compatible · 1080p · 8 Mbps"
        )
        XCTAssertEqual(
            app.staticTexts["active-download-audio"].label,
            "Audio: French dub · AAC · Stereo · Track ID 0"
        )
        let statusReachedServer = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                (self?.server?.transcodeStatusRequestCount ?? 0) > 0
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [statusReachedServer], timeout: 4),
            .completed,
            "The active compatible download must poll its generation-scoped transcode status"
        )
        let detailProgress = app.staticTexts["detail-preparation-progress-42001"]
        XCTAssertTrue(
            detailProgress.waitForExistence(timeout: 3),
            "Movie details must replace unknown byte progress with produced media time"
        )
        XCTAssertEqual(detailProgress.label, "Prepared 23:02 of 1:32:08 · 25%")

        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Downloads"].firstMatch.tap()
        let preparationProgress = app.staticTexts["preparation-progress-42001"]
        XCTAssertTrue(preparationProgress.waitForExistence(timeout: 4), server?.requestSummary ?? "")
        XCTAssertEqual(preparationProgress.label, "Prepared 23:02 of 1:32:08 · 25%")
        XCTAssertEqual(
            app.staticTexts["download-quality-42001"].label,
            "Quality: Compatible · 1080p · 8 Mbps"
        )
        XCTAssertEqual(
            app.staticTexts["download-audio-42001"].label,
            "Audio: French dub · AAC · Stereo · Track ID 0"
        )

        app.staticTexts["The Clockwork Orchard"].tap()
        XCTAssertTrue(app.buttons["Cancel Download"].waitForExistence(timeout: 3))
        app.buttons["Cancel Download"].tap()
        let cancellationReachedServer = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                (self?.server?.validTranscodeCancellationCount ?? 0) == 1
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [cancellationReachedServer], timeout: 4),
            .completed,
            "Cancelling a compatible download must stop its exact server-side generation"
        )
    }

    func testPictureInPictureStartsAndStopsRealAVFoundationPlayback() throws {
        let app = try launchApp()
        let title = app.staticTexts["The Clockwork Orchard"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.tap()
        XCTAssertTrue(app.buttons["Watch"].waitForExistence(timeout: 5))

        // Exercise PiP only after the protected compatible HLS fixture is
        // genuinely playing. The alternate track forces that proven route.
        app.buttons["Audio"].tap()
        let alternateAudio = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'French dub'")
        ).firstMatch
        XCTAssertTrue(alternateAudio.waitForExistence(timeout: 2))
        alternateAudio.tap()
        app.buttons["Watch"].tap()
        XCTAssertTrue(app.staticTexts["Preparing video…"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(
            app.staticTexts["Playback couldn't continue"].exists,
            "PiP test requires successful real playback first: \(server?.requestSummary ?? "server unavailable")"
        )
        let pause = app.buttons["Pause"]
        if !pause.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(
            pause.waitForExistence(timeout: 5),
            "PiP must not be tested against a stopped or failed player: \(server?.requestSummary ?? "server unavailable")"
        )

        let start = app.buttons["Start Picture in Picture"]
        if !start.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            guard start.waitForExistence(timeout: 3) else {
                throw XCTSkip("This device does not expose Picture in Picture")
            }
        }
        let pipReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: start
        )
        guard XCTWaiter.wait(for: [pipReady], timeout: 8) == .completed else {
            throw XCTSkip(
                "AVKit reports PiP unavailable while the physical UI test is recording the screen"
            )
        }
        XCTAssertTrue(start.isHittable)
        // PiP removes/relabels this control as part of the same animation that
        // handles the tap. Tapping its coordinate avoids XCTest trying to
        // re-resolve an element that correctly disappeared mid-transition.
        let startFrame = start.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: startFrame.midX, dy: startFrame.midY))
            .tap()

        let stop = app.buttons["Stop Picture in Picture"]
        XCTAssertTrue(
            stop.waitForExistence(timeout: 2),
            "The custom PiP button must start AVFoundation PiP instead of silently dropping the request"
        )
        stop.tap()
        XCTAssertTrue(
            start.waitForExistence(timeout: 5),
            "Stopping PiP must return the custom player to its inactive state"
        )
    }

    func testPosterGridKeepsEveryCardUniformAfterDifferentArtworkSizesLoad() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = try launchApp()
        let cardIDs = ["42001", "42002", "42003"]
        let cards = cardIDs.map { app.descendants(matching: .any)["library-card-\($0)"] }

        for card in cards {
            XCTAssertTrue(card.waitForExistence(timeout: 8), "Every synthetic library card should render")
        }
        XCTAssertTrue(
            app.staticTexts["The Velvet Astrolabe S02E5"].exists,
            "A matching Episode 5 suffix should not repeat the S02E5 metadata in the visible title"
        )
        let artworkLoaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                (self?.server?.artworkRequestCount ?? 0) >= cardIDs.count
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [artworkLoaded], timeout: 5),
            .completed,
            "The test must measure cards after portrait, panoramic, and square JPEGs have loaded"
        )

        let frames = cards.map(\.frame)
        let widths = frames.map(\.width)
        let heights = frames.map(\.height)
        XCTAssertLessThanOrEqual(
            (widths.max() ?? 0) - (widths.min() ?? 0),
            1,
            "Artwork pixel dimensions must not change a grid column's width"
        )
        XCTAssertLessThanOrEqual(
            (heights.max() ?? 0) - (heights.min() ?? 0),
            2,
            "Artwork pixel dimensions must not make one poster card taller than its peers"
        )
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertLessThan(
                heights.max() ?? .greatestFiniteMagnitude,
                290,
                "A phone poster card must not expand into the oversized black panel regression"
            )
            XCTAssertLessThanOrEqual(
                widths.max() ?? .greatestFiniteMagnitude,
                132,
                "Phone posters should stay compact enough to browse three at a time"
            )
            XCTAssertLessThanOrEqual(
                (frames.map(\.minY).max() ?? 0) - (frames.map(\.minY).min() ?? 0),
                2,
                "Three fixture posters should share the first row on a modern iPhone"
            )
        } else {
            XCTAssertLessThan(
                heights.max() ?? .greatestFiniteMagnitude,
                400,
                "A poster card must not expand into the oversized black panel regression"
            )
        }
    }

    private func launchApp(arguments: [String] = []) throws -> XCUIApplication {
        let serverAddress = try XCTUnwrap(server?.serverAddress)
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launchEnvironment = [
            "RUSTYVIEW_TEST_SERVER": serverAddress,
            "RUSTYVIEW_TEST_NAMESPACE": testNamespace,
            "RUSTYVIEW_TEST_USERNAME": "viewer",
            "RUSTYVIEW_TEST_PASSWORD": "test-only-password",
        ]
        app.launch()
        return app
    }

    private func ignoringVerifiedAuditFalsePositives(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        if issue.auditType == .textClipped, issue.element?.elementType == .searchField {
            return true // SwiftUI's system-owned searchable field scales and clips internally.
        }
        if issue.auditType == .contrast, issue.element?.identifier == "media-file-size" {
            return true // Audit screenshot confirms opaque label-black text on a near-white background.
        }
        return false
    }
}

private final class SyntheticHTTPServer {
    private let listener: NWListener
    private let mediaData: Data
    private let preparedSegmentData: Data
    private let artwork: [String: Data]
    private let queue = DispatchQueue(label: "rustyView-ui-http")
    private let ready = DispatchSemaphore(value: 0)
    private let countLock = NSLock()
    private var storedMediaRequestCount = 0
    private var storedPreparedSegmentRequestCount = 0
    private var storedPortablePlaylistRequestCount = 0
    private var storedCompatibleDownloadRequestCount = 0
    private var storedOriginalDownloadRequestCount = 0
    private var storedTranscodeStatusRequestCount = 0
    private var storedValidTranscodeCancellationCount = 0
    private var storedCaptionRequestCount = 0
    private var storedArtworkRequestCount = 0
    private var storedUnauthorizedMediaRequestCount = 0
    private var storedPreparedStartSeconds: [Int] = []
    private var storedRequests: [String] = []
    private var startError: Error?

    var mediaRequestCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return storedMediaRequestCount
    }

    var requestSummary: String {
        countLock.lock()
        defer { countLock.unlock() }
        return storedRequests.joined(separator: ", ")
    }

    var preparedSegmentRequestCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return storedPreparedSegmentRequestCount
    }

    var compatibleDownloadRequestCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return storedCompatibleDownloadRequestCount
    }

    var originalDownloadRequestCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return storedOriginalDownloadRequestCount
    }

    var transcodeStatusRequestCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return storedTranscodeStatusRequestCount
    }

    var validTranscodeCancellationCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return storedValidTranscodeCancellationCount
    }

    var portablePlaylistRequestCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return storedPortablePlaylistRequestCount
    }

    var captionRequestCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return storedCaptionRequestCount
    }

    var artworkRequestCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return storedArtworkRequestCount
    }

    var unauthorizedMediaRequestCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return storedUnauthorizedMediaRequestCount
    }

    var largestPreparedStartSeconds: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return storedPreparedStartSeconds.max() ?? 0
    }

    var requestCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return storedRequests.count
    }

    var serverAddress: String? {
        listener.port.map { "http://127.0.0.1:\($0.rawValue)" }
    }

    init() throws {
        guard let mediaURL = Bundle(for: SyntheticHTTPServer.self).url(
            forResource: "synthetic-playback",
            withExtension: "mp4"
        ) else {
            throw NSError(domain: "SyntheticHTTPServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Synthetic playback fixture is missing"])
        }
        guard let segmentURL = Bundle(for: SyntheticHTTPServer.self).url(
            forResource: "synthetic-playback",
            withExtension: "ts"
        ) else {
            throw NSError(domain: "SyntheticHTTPServer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Synthetic HLS segment fixture is missing"])
        }
        mediaData = try Data(contentsOf: mediaURL)
        preparedSegmentData = try Data(contentsOf: segmentURL)
        artwork = [
            "/AlbumArt/42001.jpg": try Self.jpeg(size: CGSize(width: 360, height: 540), color: .systemOrange),
            "/AlbumArt/42002.jpg": try Self.jpeg(size: CGSize(width: 2_400, height: 320), color: .systemIndigo),
            "/AlbumArt/42003.jpg": try Self.jpeg(size: CGSize(width: 720, height: 720), color: .systemTeal),
        ]
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() throws {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.ready.signal()
            case .failed(let error):
                self?.startError = error
                self?.ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success else {
            throw NSError(domain: "SyntheticHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Listener did not become ready"])
        }
        if let startError { throw startError }
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard error == nil, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            self?.respond(to: request, over: connection)
        }
    }

    private func respond(to request: String, over connection: NWConnection) {
        let firstLine = request.split(separator: "\n").first.map(String.init) ?? ""
        let method = firstLine.split(separator: " ").first.map(String.init) ?? "GET"
        let target = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let authorized = request.contains("Authorization: Basic dmlld2VyOnRlc3Qtb25seS1wYXNzd29yZA==")
        let range = request.split(separator: "\n").first { $0.lowercased().hasPrefix("range:") }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "no-range"
        countLock.lock()
        storedRequests.append("\(method) \(target) auth=\(authorized) \(range)")
        countLock.unlock()
        if !authorized {
            if target.hasPrefix("/web/media/") {
                countLock.lock()
                storedUnauthorizedMediaRequestCount += 1
                countLock.unlock()
            }
            send(
                Data(#"{"schema_version":2,"error":{"code":"unauthorized","message":"Sign in.","recoverable":true,"action":null}}"#.utf8),
                status: 401,
                contentType: "application/json",
                method: method,
                extraHeaders: ["WWW-Authenticate": #"Basic realm="Synthetic media""#],
                connection: connection
            )
            return
        } else if target.hasPrefix("/api/web/library") {
            let payload: String
            if target.contains("view=folders") {
                payload = target.contains("folder=folder-7") ? Self.folderChildJSON : Self.folderRootJSON
            } else {
                payload = Self.libraryJSON
            }
            send(Data(payload.utf8), contentType: "application/json", method: method, connection: connection)
            return
        } else if target.hasPrefix("/api/web/item/42001") {
            send(Data(Self.itemJSON.utf8), contentType: "application/json", method: method, connection: connection)
            return
        } else if target.hasPrefix("/api/web/transcode/42001") {
            let requestID = Self.queryValue(named: "request", in: target) ?? "0"
            let sessionID = Self.queryValue(named: "session", in: target) ?? "0"
            countLock.lock()
            if method == "DELETE", requestID != "0", requestID == sessionID {
                storedValidTranscodeCancellationCount += 1
            } else if method == "GET" {
                storedTranscodeStatusRequestCount += 1
            }
            countLock.unlock()
            let state = method == "DELETE" ? "cancelled" : "producing"
            let payload = """
            {"schema_version":2,"item_id":"42001","request_id":\(requestID),"state":"\(state)","retry_after_seconds":null,"produced_seconds":1382}
            """
            send(Data(payload.utf8), contentType: "application/json", method: method, connection: connection)
            return
        } else if target.hasPrefix("/web/download/42001") {
            countLock.lock()
            storedOriginalDownloadRequestCount += 1
            countLock.unlock()
            sendMedia(request: request, method: method, slowly: true, delay: 20, connection: connection)
            return
        } else if target.hasPrefix("/web/media/42001.mp4") {
            var shouldFailTransiently = false
            countLock.lock()
            if target.contains("mode=compatible") {
                storedCompatibleDownloadRequestCount += 1
                shouldFailTransiently = target.contains("audio=0")
                    && storedCompatibleDownloadRequestCount == 1
            } else {
                storedMediaRequestCount += 1
            }
            countLock.unlock()
            if shouldFailTransiently {
                send(
                    Data(#"{"schema_version":2,"error":{"code":"temporarily_unavailable","message":"Synthetic retry case.","recoverable":true,"action":null}}"#.utf8),
                    status: 503,
                    contentType: "application/json",
                    method: method,
                    connection: connection
                )
                return
            }
            sendMedia(
                request: request,
                method: method,
                slowly: target.contains("mode=compatible"),
                delay: target.contains("quality=full_hd") || target.contains("audio=1") ? 30 : 8,
                connection: connection
            )
            return
        } else if target.hasPrefix("/web/media/42001.m3u8") {
            guard target.contains("video_mode=transcode"),
                  target.contains("video_output=h264_sdr"),
                  target.contains("audio=0") else {
                send(
                    Data(#"{"schema_version":2,"error":{"code":"synthetic_copy_failure","message":"Synthetic copied stream failed.","recoverable":true,"action":null}}"#.utf8),
                    status: 404,
                    contentType: "application/json",
                    method: method,
                    connection: connection
                )
                return
            }
            countLock.lock()
            storedPortablePlaylistRequestCount += 1
            if let start = Self.queryValue(named: "start", in: target).flatMap(Int.init) {
                storedPreparedStartSeconds.append(start)
            }
            countLock.unlock()
            let playlist = """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:25
            #EXT-X-MEDIA-SEQUENCE:0
            #EXT-X-PLAYLIST-TYPE:EVENT
            #EXTINF:25.000000,
            synthetic-playback.ts

            """
            send(Data(playlist.utf8), contentType: "application/vnd.apple.mpegurl", method: method, connection: connection)
            return
        } else if target.hasPrefix("/web/media/synthetic-playback.ts") {
            countLock.lock()
            storedPreparedSegmentRequestCount += 1
            countLock.unlock()
            send(preparedSegmentData, contentType: "video/mp2t", method: method, connection: connection)
            return
        } else if target.hasPrefix("/Captions/42001/0.vtt") {
            countLock.lock()
            storedCaptionRequestCount += 1
            countLock.unlock()
            let captions = "WEBVTT\n\n00:00:00.000 --> 02:00:00.000\nSynthetic subtitle.\n"
            send(Data(captions.utf8), contentType: "text/vtt", method: method, connection: connection)
            return
        } else if let image = artwork[target] {
            countLock.lock()
            storedArtworkRequestCount += 1
            countLock.unlock()
            send(image, contentType: "image/jpeg", method: method, connection: connection)
            return
        } else {
            send(
                Data(#"{"schema_version":2,"error":{"code":"missing","message":"Missing synthetic route.","recoverable":false,"action":null}}"#.utf8),
                status: 404,
                contentType: "application/json",
                method: method,
                connection: connection
            )
        }
    }

    private static func jpeg(size: CGSize, color: UIColor) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(
                x: size.width * 0.2,
                y: size.height * 0.2,
                width: size.width * 0.6,
                height: size.height * 0.6
            ))
        }
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            throw NSError(
                domain: "SyntheticHTTPServer",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Could not encode synthetic artwork"]
            )
        }
        return data
    }

    private static func queryValue(named name: String, in target: String) -> String? {
        URLComponents(string: "http://synthetic.invalid\(target)")?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    private func sendMedia(
        request: String,
        method: String,
        slowly: Bool,
        delay: TimeInterval = 8,
        connection: NWConnection
    ) {
        let rangeLine = request.split(separator: "\n").first {
            $0.lowercased().hasPrefix("range:")
        }
        var start = 0
        var end = mediaData.count - 1
        var status = 200
        if let rangeLine,
           let value = rangeLine.split(separator: "=", maxSplits: 1).last,
           let firstRange = value.split(separator: ",").first {
            let bounds = firstRange.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let startText = bounds[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if let requestedStart = Int(startText) { start = min(max(0, requestedStart), mediaData.count - 1) }
            if bounds.count > 1 {
                let endText = bounds[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if let requestedEnd = Int(endText) { end = min(max(start, requestedEnd), mediaData.count - 1) }
            }
            status = 206
        }
        let body = mediaData.subdata(in: start..<(end + 1))
        var extra = ["Accept-Ranges": "bytes"]
        if status == 206 { extra["Content-Range"] = "bytes \(start)-\(end)/\(mediaData.count)" }
        if slowly, method != "HEAD" {
            sendInTwoChunks(
                body,
                status: status,
                contentType: "video/mp4",
                extraHeaders: extra,
                delay: delay,
                connection: connection
            )
        } else {
            send(body, status: status, contentType: "video/mp4", method: method, extraHeaders: extra, connection: connection)
        }
    }

    private func sendInTwoChunks(
        _ body: Data,
        status: Int,
        contentType: String,
        extraHeaders: [String: String],
        delay: TimeInterval,
        connection: NWConnection
    ) {
        let reason = status == 206 ? "Partial Content" : "OK"
        var header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in extraHeaders { header += "\(name): \(value)\r\n" }
        header += "\r\n"
        let split = max(1, body.count / 3)
        var first = Data(header.utf8)
        first.append(body.prefix(split))
        connection.send(content: first, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else {
                connection.cancel()
                return
            }
            self.queue.asyncAfter(deadline: .now() + delay) {
                connection.send(
                    content: body.suffix(from: split),
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            }
        })
    }

    private func send(
        _ body: Data,
        status: Int = 200,
        contentType: String,
        method: String,
        extraHeaders: [String: String] = [:],
        connection: NWConnection
    ) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 206: reason = "Partial Content"
        case 401: reason = "Unauthorized"
        case 503: reason = "Service Unavailable"
        default: reason = "Not Found"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in extraHeaders { header += "\(name): \(value)\r\n" }
        header += "\r\n"
        var bytes = Data(header.utf8)
        if method != "HEAD" { bytes.append(body) }
        connection.send(
            content: bytes,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private static let audioTracks = #"""
    [
      {"index":0,"codec":"aac","content_type":"audio/mp4","channels":2,"language":"fra","title":"French dub","default":false},
      {"index":1,"codec":"dts","content_type":null,"channels":6,"language":"eng","title":"Original English","default":true}
    ]
    """#

    private static let chapters = #"""
    [
      {"index":0,"title":"Orchard Gate Opens","start_seconds":0,"end_seconds":1800},
      {"index":1,"title":"Clockwork Grove","start_seconds":1800,"end_seconds":5528}
    ]
    """#

    private static let mediaFields = #"""
    "id":"42001","title":"The Clockwork Orchard 2160p HDR10 BDRemux","file_name":"synthetic-one.mkv",
    "kind":"video","mime":"video/x-matroska","ext":"mkv","duration":"1:32:08",
    "duration_seconds":5528,"resolution":"3840x2160","width":3840,"height":2160,
    "about":"An entirely invented story used to verify the app interface.","plot":"Synthetic plot.",
    "genre":"Science Fiction","size_bytes":8200000000,"container":"matroska","video_codec":"hevc",
    "video_profile":"Main 10","bit_depth":10,"frame_rate":"24000/1001","video_repair_required":false,
    "audio_codec":"dts,aac","audio_layout":"5.1","codec_string":"hvc1,mp4a.40.2","hdr":"hdr10",
    "default_audio_index":1,"captions":[{"index":0,"label":"English","language":"eng","default":false,"source_format":"srt","browser_supported":true,"url":"/Captions/42001/0.vtt"}],"art_url":"/AlbumArt/42001.jpg","download_url":"/web/download/42001",
    "source_url":"/web/media/42001.mp4?mode=direct","fallback_url":"/web/media/42001.mp4","transcode_likely":false
    """#

    private static let libraryJSON = """
    {"schema_version":2,"generation":1,"server_name":"Synthetic Media Server","root_folder_id":"0",
    "capabilities":{"transcoding":true,"captions":true,"quality_profiles":[
      {"id":"auto","label":"Auto · Best","max_width":3840,"max_height":2160,"expected_bandwidth_kbps":12000,"automatic_fallback":false},
      {"id":"full_hd","label":"1080p · 8 Mbps","max_width":1920,"max_height":1080,"expected_bandwidth_kbps":8448,"automatic_fallback":false}
    ]},"library_state":"ready","view":"library","folder":null,"breadcrumbs":[],"offset":0,"limit":60,
    "total":3,"has_more":false,"query":"","sort":"title","entries":[
      {"entry_type":"media",\(mediaFields)},
      {"entry_type":"media",\(secondMediaFields)},
      {"entry_type":"media",\(thirdMediaFields)}
    ]}
    """

    private static let folderRootJSON = """
    {"schema_version":2,"generation":1,"server_name":"Synthetic Media Server","root_folder_id":"0",
    "capabilities":{"transcoding":true,"captions":true,"quality_profiles":[
      {"id":"auto","label":"Auto · Best","max_width":3840,"max_height":2160,"expected_bandwidth_kbps":12000,"automatic_fallback":false},
      {"id":"full_hd","label":"1080p · 8 Mbps","max_width":1920,"max_height":1080,"expected_bandwidth_kbps":8448,"automatic_fallback":false}
    ]},"library_state":"ready","view":"folders","folder":{"id":"0","title":"Media"},
    "breadcrumbs":[{"id":"0","title":"Media"}],"offset":0,"limit":60,"total":1,"has_more":false,
    "query":"","sort":"title","entries":[{"entry_type":"folder","id":"folder-7","title":"Invented Shelf","child_count":1}]}
    """

    private static let folderChildJSON = """
    {"schema_version":2,"generation":1,"server_name":"Synthetic Media Server","root_folder_id":"0",
    "capabilities":{"transcoding":true,"captions":true,"quality_profiles":[
      {"id":"auto","label":"Auto · Best","max_width":3840,"max_height":2160,"expected_bandwidth_kbps":12000,"automatic_fallback":false},
      {"id":"full_hd","label":"1080p · 8 Mbps","max_width":1920,"max_height":1080,"expected_bandwidth_kbps":8448,"automatic_fallback":false}
    ]},"library_state":"ready","view":"folders","folder":{"id":"folder-7","title":"Invented Shelf"},
    "breadcrumbs":[{"id":"0","title":"Media"},{"id":"folder-7","title":"Invented Shelf"}],
    "offset":0,"limit":60,"total":1,"has_more":false,"query":"","sort":"title",
    "entries":[{"entry_type":"media",\(mediaFields)}]}
    """

    private static let itemJSON = """
    {"schema_version":2,"id":"42001","item":{\(mediaFields),"audio_tracks":\(audioTracks),"chapters":\(chapters)},
    "audio_tracks":\(audioTracks),"chapters":\(chapters)}
    """

    private static let secondMediaFields = mediaFields
        .replacingOccurrences(of: "42001", with: "42002")
        .replacingOccurrences(
            of: "The Clockwork Orchard",
            with: "The Velvet Astrolabe S02E5 - Episode 5"
        )

    private static let thirdMediaFields = mediaFields
        .replacingOccurrences(of: "42001", with: "42003")
        .replacingOccurrences(of: "The Clockwork Orchard", with: "The Silver Orrery")
}
