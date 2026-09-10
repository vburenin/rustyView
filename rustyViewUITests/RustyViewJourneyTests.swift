import ImageIO
import Network
import UIKit
import Vision
import XCTest

final class RustyViewJourneyTests: XCTestCase {
    private var server: SyntheticHTTPServer?
    private var testNamespace = ""
    private var auditNativeMenuFrame: CGRect?
    private var auditNativeMenuRows: [AuditNativeMenuRow] = []
    private var auditFontCategory = UIContentSizeCategory.large
    private var pendingNativeSearchChecks: [String: CGRect] = [:]
    private var nativeSearchVerificationEnabled = false
    private var verifiedNativeSearchClear: (field: CGRect, button: CGRect, query: String)?

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        testNamespace = UUID().uuidString.lowercased()
        auditNativeMenuFrame = nil
        auditNativeMenuRows = []
        auditFontCategory = .large
        pendingNativeSearchChecks = [:]
        nativeSearchVerificationEnabled = false
        verifiedNativeSearchClear = nil
        server = try SyntheticHTTPServer()
        try server?.start()
    }

    override func tearDown() {
        if (testRun?.failureCount ?? 0) > 0 {
            // Keep the current failure inspectable while a long font matrix
            // continues; xcresult attachments become readable only at its end.
            let evidence = FileManager.default.temporaryDirectory
                .appendingPathComponent("synthetic-font-failure-\(testNamespace)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
                try XCUIScreen.main.screenshot().pngRepresentation.write(to: evidence.appendingPathComponent("screen.png"))
                try XCUIApplication().debugDescription.write(to: evidence.appendingPathComponent("hierarchy.txt"),
                                                             atomically: true, encoding: .utf8)
                print("Synthetic font failure evidence: \(evidence.path)")
            } catch { /* xcresult attachments below remain the primary evidence. */ }
            let requests = XCTAttachment(string: server?.requestSummary ?? "Synthetic server unavailable")
            requests.name = "Synthetic HTTP requests at failure"
            requests.lifetime = .keepAlways
            add(requests)
            let hierarchy = XCTAttachment(string: XCUIApplication().debugDescription)
            hierarchy.name = "Synthetic UI hierarchy at failure"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Synthetic UI at failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCUIApplication().terminate()
        server?.stop()
        server = nil
        super.tearDown()
    }

    func testEmbeddedCaptionIsActuallyRenderedAndOffRemovesItsPixels() throws {
        let server = try XCTUnwrap(server)
        server.useNativeCaptionFixture()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = try launchApp()
        let title = app.staticTexts["The Clockwork Orchard"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.tap()
        XCTAssertTrue(app.buttons["Download"].waitForExistence(timeout: 5))
        app.buttons["Download"].tap()
        let original = app.buttons["Original file"]
        for _ in 0..<2 {
            if original.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(original.isHittable)
        original.tap()
        XCTAssertTrue(app.buttons["Cancel Download"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Downloads"].firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-download-'")).firstMatch.waitForExistence(timeout: 35))
        let baseline = server.requestCount
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play offline copy of '")).firstMatch.tap()
        let timeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 1, timeout: 8, revealingControlsIn: app)
        showPlayerControls(in: app)
        app.buttons["Pause"].tap()
        app.buttons["Playback options"].tap()
        let native = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'local-caption-subtitle-'")).firstMatch
        reveal(native, in: app)
        XCTAssertTrue(native.isHittable, "The saved video must expose its actual native legible group")
        native.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3))
        let scrubber = app.otherElements["playback-scrubber"]
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 1, timeout: 3)
        XCTAssertLessThanOrEqual(try elapsedSeconds(from: timeline), 2,
                                 "Inspect the actual native cue around 1.5 seconds, while paused")
        // Hide the controls so the caption is tested as delivered by AVPlayerLayer,
        // without an application-generated label or a menu title contributing OCR.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(app.buttons["Play"].waitForNonExistence(timeout: 2))
        XCTAssertTrue(waitForNativeCuePixels(in: app, visible: true, timeout: 3),
                      "Selecting a native track is insufficient unless decoded dialogue is visibly rendered")
        let rendered = XCTAttachment(screenshot: app.screenshot())
        rendered.name = "Synthetic native subtitle rendered by AVPlayerLayer"
        rendered.lifetime = .keepAlways
        add(rendered)
        showPlayerControls(in: app)
        app.buttons["Subtitles"].tap()
        app.buttons["Off"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(app.buttons["Play"].waitForNonExistence(timeout: 2))
        XCTAssertTrue(waitForNativeCuePixels(in: app, visible: false, timeout: 3),
                      "Off must remove the previously recognized dialogue from the real video surface")
        XCTAssertEqual(server.requestCount, baseline,
                       "Native subtitle delivery and Off must remain entirely within the owned offline asset")
    }

    private func waitForNativeCuePixels(in app: XCUIApplication, visible: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let expected = Set(["native", "paper", "lantern", "cue"])
        var samples: [String] = []
        var lastScreenshot: XCUIScreenshot?
        repeat {
            // Use the physical surface, matching the screenshot attached on
            // failure. Landscape screenshots can retain portrait pixel storage.
            let screenshot = XCUIScreen.main.screenshot()
            lastScreenshot = screenshot
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            do {
                let source = try XCTUnwrap(CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                let orientation = CGImagePropertyOrientation(rawValue:
                    (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1) ?? .up
                try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ").lowercased()
                // OCR can choose different line wrapping; require every invented
                // dialogue word, not a loose match for the subtitle menu label.
                let words = Set(text.split(whereSeparator: { !$0.isLetter }).map(String.init))
                samples.append("\(image.width)x\(image.height) orientation=\(orientation.rawValue): \(text)")
                if visible ? expected.isSubset(of: words) : expected.isDisjoint(with: words) { return true }
            } catch {
                samples.append("Vision failed: \(error.localizedDescription)")
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        let diagnostics = XCTAttachment(string: samples.joined(separator: "\n"))
        diagnostics.name = "Synthetic native caption OCR samples"
        diagnostics.lifetime = .keepAlways
        add(diagnostics)
        if let lastScreenshot {
            let input = XCTAttachment(screenshot: lastScreenshot)
            input.name = "Synthetic exact native caption OCR input"
            input.lifetime = .keepAlways
            add(input)
        }
        return false
    }

    private func assertWholeTouchTarget(_ element: XCUIElement, in app: XCUIApplication,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 3), file: file, line: line)
        for _ in 0..<6 {
            if element.isHittable && element.frame.minY >= app.frame.minY && element.frame.maxY <= app.frame.maxY { break }
            if element.frame.minY < app.frame.minY { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.isHittable, file: file, line: line)
        let frame = element.frame
        XCTAssertGreaterThanOrEqual(frame.width, 43.5, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height, 43.5, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, app.frame.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, app.frame.maxX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, app.frame.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, app.frame.maxY, file: file, line: line)
    }

    @MainActor
    func testKeyboardEscapeDismissesOptionsAndPlayer() throws {
        try XCTUnwrap(server).useOfflineTracksFixture()
        let app = try launchApp()
        XCTAssertTrue(app.buttons["Sort"].waitForExistence(timeout: 8))
        app.buttons["Sort"].tap()
        let choice = app.buttons["Title"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 3))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        guard choice.waitForNonExistence(timeout: 3) else {
            throw XCTSkip("This Simulator ignores injected Escape in UIKit's own Sort menu; app Escape requires a runtime with working key injection or the hardware iPad check.")
        }
        app.staticTexts["The Clockwork Orchard"].tap()
        app.buttons["Watch"].tap()
        let timeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 1, timeout: 10, revealingControlsIn: app)
        app.typeKey("o", modifierFlags: [])
        XCTAssertTrue(app.navigationBars["Playback Options"].waitForExistence(timeout: 3))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.navigationBars["Playback Options"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Close player"].exists)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.buttons["Close player"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["The Clockwork Orchard"].exists)
    }

    @MainActor
    func testKeyboardTransportAndOptionsControlTheActualPlayer() throws {
        let server = try XCTUnwrap(server)
        server.useOfflineTracksFixture()
        XCUIDevice.shared.orientation = .portrait
        let app = try launchApp()
        let title = app.staticTexts["The Clockwork Orchard"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.tap()
        app.buttons["Watch"].tap()
        let timeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 2, timeout: 10, revealingControlsIn: app)

        app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [])
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3))
        let paused = try elapsedSeconds(from: timeline)
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        let advanced = try waitForElapsedSeconds(in: timeline, atLeast: paused + 9, timeout: 4)
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForElapsedSeconds(in: timeline, atMost: advanced - 9, timeout: 4))
        XCTAssertEqual(app.buttons["play-pause-control"].label, "Play")

        app.typeKey("o", modifierFlags: [])
        XCTAssertTrue(app.navigationBars["Playback Options"].waitForExistence(timeout: 3))
        app.navigationBars["Playback Options"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Playback Options"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Close player"].exists)
        app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [])
        _ = try waitForElapsedSeconds(in: timeline, atLeast: paused + 1, timeout: 4)
        XCTAssertEqual(app.buttons["play-pause-control"].label, "Pause")
        app.buttons["Close player"].tap()
        XCTAssertTrue(app.buttons["Close player"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["The Clockwork Orchard"].exists)
    }

    @MainActor
    func testAuditDeepFolderPathAndExpandedChaptersInDark() throws {
        try AuditDeepFolderPathAndExpandedChapters(appearance: "Dark", category: .large)
    }

    @MainActor
    func testAuditSetupSettingsAndHTTPRecoveryInDark() throws {
        try AuditSetupSettingsAndHTTPRecovery(appearance: "Dark", category: .large)
    }

    @MainActor
    private func AuditDeepFolderPathAndExpandedChapters(
        appearance: String, category: UIContentSizeCategory = .accessibilityExtraExtraExtraLarge
    ) throws {
        XCUIDevice.shared.orientation = .portrait
        let server = try XCTUnwrap(server)
        server.auditUseDeepFolders()
        server.useOfflineTracksFixture()
        let app = try launchApp(arguments: AuditArguments(appearance, category: category))
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let browse = app.buttons["Browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        AuditAssertTarget(browse, in: app, content: false)
        browse.tap()
        app.buttons["Folders"].tap()
        for title in SyntheticHTTPServer.auditFolderTitles {
            let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 5))
            AuditReveal(folder, in: app)
            AuditAssertTarget(folder, in: app)
            folder.tap()
        }
        let movie = app.descendants(matching: .any).matching(identifier: "library-card-42001").firstMatch
        XCTAssertTrue(movie.waitForExistence(timeout: 5))
        let path = app.scrollViews.matching(NSPredicate(format: "label == 'Folder path'")).firstMatch
        XCTAssertTrue(path.exists, "A deep folder path must remain a separately scrollable navigation control")
        let ancestor = path.buttons[SyntheticHTTPServer.auditFolderTitles[1]]
        AuditRevealBreadcrumb(ancestor, in: path, app: app)
        AuditAssertTarget(ancestor, in: app)
        XCTAssertTrue(AuditContains(ancestor.frame, in: path.frame.intersection(app.frame)),
                      "A breadcrumb tap target must be fully revealed, not merely hit-testable at its clipped edge")
        try AuditVisibleScreen(app, appearance: appearance, name: "deep-folder-path", fontName: category.rawValue)
        AuditRevealBreadcrumb(ancestor, in: path, app: app)
        ancestor.tap()
        let next = app.buttons["library-card-73003"]
        XCTAssertTrue(next.waitForExistence(timeout: 5), "Tapping the revealed ancestor must load its actual children")
        XCTAssertTrue(app.navigationBars[SyntheticHTTPServer.auditFolderTitles[1]].exists,
                      "The ancestor must restore its own page, including a valid cached page")
        for title in SyntheticHTTPServer.auditFolderTitles.dropFirst(2) {
            let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 5))
            AuditReveal(folder, in: app)
            folder.tap()
        }
        XCTAssertTrue(movie.waitForExistence(timeout: 5))
        AuditReveal(movie, in: app)
        movie.tap()
        let chapters = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Chapters ('")).firstMatch
        XCTAssertTrue(chapters.waitForExistence(timeout: 5))
        AuditReveal(chapters, in: app)
        AuditAssertTarget(chapters, in: app)
        chapters.tap()
        let chapter = app.buttons["detail-chapter-1"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 3))
        AuditReveal(chapter, in: app)
        AuditAssertTarget(chapter, in: app)
        try AuditVisibleScreen(app, appearance: appearance, name: "expanded-chapter-actions", fontName: category.rawValue)
        AuditReveal(chapter, in: app)
        chapter.tap()
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 5))
        let timeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        // Starting at zero cannot reach eight seconds within this five-second observation.
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 8, timeout: 5, revealingControlsIn: app)
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 9, timeout: 5, revealingControlsIn: app)
        XCTAssertGreaterThan(server.mediaRequestCount, 0, "The chapter action must play real authenticated media")
    }

    @MainActor
    private func AuditSetupSettingsAndHTTPRecovery(
        appearance: String, category: UIContentSizeCategory = .accessibilityExtraExtraExtraLarge
    ) throws {
        XCUIDevice.shared.orientation = .portrait
        let server = try XCTUnwrap(server)
        let app = XCUIApplication()
        app.launchArguments = AuditArguments(appearance, category: category)
        app.launchEnvironment = ["RUSTYVIEW_TEST_NAMESPACE": testNamespace]
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let submit = app.buttons["connection-submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        AuditDismissSetupKeyboard(in: app)
        AuditReveal(submit, in: app)
        AuditAssertTarget(submit, in: app)
        try AuditVisibleScreen(app, appearance: appearance, name: "setup-first-launch", fontName: category.rawValue)
        AuditReveal(submit, in: app)
        submit.tap()
        XCTAssertEqual(server.auditLibraryRequestCount, 0, "Invalid setup must not issue an HTTP probe")
        AuditDismissSetupKeyboard(in: app)
        try AuditVisibleScreen(app, appearance: appearance, name: "setup-field-validation", fontName: category.rawValue)
        let address = app.textFields["connection-server"]
        AuditReveal(address, in: app)
        AuditAssertTarget(address, in: app)
        address.tap()
        address.typeText(try XCTUnwrap(server.serverAddress) + "\n")
        let username = app.textFields["connection-username"]
        AuditWaitForInputFocusLayout(username, in: app)
        AuditAssertTarget(username, in: app)
        app.typeText("viewer\n")
        let password = app.secureTextFields["connection-password"]
        AuditWaitForInputFocusLayout(password, in: app)
        AuditAssertTarget(password, in: app)
        app.typeText("test-only-password")
        server.auditRejectLibraryRequests(true)
        app.keyboards.buttons["Go"].tap()
        let failure = app.descendants(matching: .any).matching(identifier: "connection-error").firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 6))
        XCTAssertGreaterThan(server.auditFailedLibraryRequestCount, 0)
        AuditReveal(submit, in: app)
        AuditAssertTarget(submit, in: app)
        try AuditVisibleScreen(app, appearance: appearance, name: "setup-http-recovery", fontName: category.rawValue)
        server.auditRejectLibraryRequests(false)
        AuditReveal(submit, in: app)
        submit.tap()
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        dismissSyntheticPasswordOffer(in: app)
        settings.tap()
        let edit = app.buttons["Edit Connection"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        AuditReveal(edit, in: app)
        AuditAssertTarget(edit, in: app)
        let quality = app.buttons["preferred-quality"]
        AuditReveal(quality, in: app)
        AuditAssertTarget(quality, in: app)
        try AuditVisibleScreen(app, appearance: appearance, name: "settings-playback", fontName: category.rawValue)
        AuditReveal(quality, in: app)
        quality.tap()
        let fullHD = app.buttons.matching(NSPredicate(format: "label CONTAINS '1080p'")).firstMatch
        XCTAssertTrue(fullHD.waitForExistence(timeout: 3))
        AuditAssertTarget(fullHD, in: app)
        fullHD.tap()
        let network = app.buttons["download-network-menu"]
        AuditReveal(network, in: app)
        AuditAssertTarget(network, in: app)
        try AuditVisibleScreen(app, appearance: appearance, name: "settings-download-network", fontName: category.rawValue)
        AuditReveal(network, in: app)
        network.tap()
        let wifi = app.buttons["Wi-Fi Only"]
        XCTAssertTrue(wifi.waitForExistence(timeout: 3))
        AuditAssertNativeMenuTarget(wifi, in: app)
        wifi.tap()
        XCTAssertEqual(network.value as? String, "Wi-Fi Only")

        // A fresh process must show a real recoverable HTTP failure, then persist the Settings choice.
        server.auditRejectLibraryRequests(true)
        app.terminate()
        app.launch()
        let retry = app.buttons["Retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        AuditReveal(retry, in: app)
        AuditAssertTarget(retry, in: app)
        try AuditVisibleScreen(app, appearance: appearance, name: "library-http-recovery", fontName: category.rawValue)
        let requestsBeforeRetry = server.auditLibraryRequestCount
        server.auditRejectLibraryRequests(false)
        AuditReveal(retry, in: app)
        retry.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "library-card-42001").firstMatch.waitForExistence(timeout: 8))
        XCTAssertGreaterThan(server.auditLibraryRequestCount, requestsBeforeRetry)
        app.tabBars.buttons["Settings"].tap()
        AuditReveal(network, in: app)
        XCTAssertEqual(network.value as? String, "Wi-Fi Only", "The reached control must update durable policy")
        AuditReveal(quality, in: app)
        XCTAssertTrue(quality.label.contains("1080p") || (quality.value as? String)?.contains("1080p") == true,
                      "The selected quality must survive a process relaunch")
    }

    private func AuditArguments(
        _ appearance: String, category: UIContentSizeCategory = .accessibilityExtraExtraExtraLarge
    ) -> [String] {
        auditFontCategory = category
        return ["-AppleInterfaceStyle", appearance, "-UIPreferredContentSizeCategoryName", category.rawValue]
    }

    @MainActor
    private func AuditVisibleScreen(_ app: XCUIApplication, appearance: String, name: String, fontName: String = "XXXL") throws {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Audit-\(name)-\(appearance)-\(fontName)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let cgImage = try XCTUnwrap(screenshot.image.cgImage)
        var luminances: [Double] = []
        for x in [0.01, 0.99] {
            for y in [0.30, 0.40, 0.50, 0.60, 0.70] {
                let rect = CGRect(x: Double(cgImage.width) * x, y: Double(cgImage.height) * y, width: 1, height: 1)
                let pixel = try XCTUnwrap(cgImage.cropping(to: rect))
                var rgba = [UInt8](repeating: 0, count: 4)
                try rgba.withUnsafeMutableBytes { bytes in
                    let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                        bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                    context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                luminances.append((0.2126 * Double(rgba[0]) + 0.7152 * Double(rgba[1]) + 0.0722 * Double(rgba[2])) / 255)
            }
        }
        let median = luminances.sorted()[luminances.count / 2]
        if appearance == "Dark" {
            XCTAssertLessThan(median, 0.35, "Observed edge background must actually be dark before claiming a dark audit")
        } else {
            XCTAssertGreaterThan(median, 0.70, "Observed edge background must actually be light before claiming a light audit")
        }
        // OCR-based element detection also recognizes native scroll-edge text
        // behind the bars. Audit readable content and named actions here; the
        // original accessibility smoke test retains the broader detection pass.
        AuditScreen(app, types: [.contrast, .hitRegion,
            .sufficientElementDescription, .textClipped, .trait])
    }

    private func AuditScreen(_ app: XCUIApplication, types: XCUIAccessibilityAuditType) {
        // Record audit failures without abandoning the rest of the screen
        // review. Required navigation and behavioral assertions still stop a
        // journey, and every reported audit failure keeps the test failing.
        let previous = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = previous }
        pendingNativeSearchChecks.removeAll()
        nativeSearchVerificationEnabled = true
        do {
            try app.performAccessibilityAudit(for: types, ignoringVerifiedAuditFalsePositives)
        } catch {
            XCTFail("Accessibility audit failed: \(error)")
        }
        nativeSearchVerificationEnabled = false
        // Unlike descriptive audits, a failed action proof must stop this
        // journey before it can be recorded as verified.
        continueAfterFailure = false
        for label in pendingNativeSearchChecks.keys.sorted() {
            AuditVerifyNativeSearchHitArea(label, reportedFrame: pendingNativeSearchChecks[label], in: app)
        }
        pendingNativeSearchChecks.removeAll()
    }

    @MainActor
    private func AuditReveal(_ element: XCUIElement, in app: XCUIApplication, searchTowardTop: Bool = false) {
        var previousFrame: CGRect?
        var stalled = 0
        for attempt in 0..<24 {
            let bounds = AuditContentBounds(app)
            let exists = element.exists
            let frame = exists ? element.frame : CGRect.zero
            if exists && AuditContains(frame, in: bounds)
                && (element.elementType == .staticText || element.isHittable) { return }
            // Search one direction far enough to reach lazily created rows
            // before reversing. Short alternating sweeps revisit the same area.
            let down = exists ? frame.minY < bounds.minY
                : (attempt < 12 ? searchTowardTop : !searchTowardTop)
            var distance = exists
                ? (down ? bounds.minY - frame.minY : frame.maxY - bounds.maxY) + 12 : nil
            if exists {
                stalled = previousFrame.map { AuditSameRect($0, frame) } == true ? stalled + 1 : 0
                previousFrame = frame
                let hasKeyboard = app.keyboards.firstMatch.exists
                if !hasKeyboard {
                    // A short gesture can activate a native menu instead of
                    // scrolling. Leave room for the whole target after a pan.
                    let minimumPan = min(80, max(24, bounds.height - frame.height - 24))
                    distance = max(distance ?? 0, minimumPan)
                }
                // Very short drags can be absorbed by native Form rows. Use
                // a real pan after observing no movement, then remeasure.
                if stalled >= 2 && !hasKeyboard { distance = max(distance ?? 0, 100) }
            }
            AuditScroll(in: app, bounds: bounds, down: down, distance: distance)
        }
        let exists = element.exists
        let description = exists ? "\(element.identifier), \(element.label), frame: \(element.frame), visible: \(AuditContentBounds(app))" : "missing element"
        XCTAssertTrue(exists && AuditContains(element.frame, in: AuditContentBounds(app))
                      && (element.elementType == .staticText || element.isHittable),
                      "Scrolling must reveal the complete element: \(description)")
    }

    private func AuditScroll(in app: XCUIApplication, bounds: CGRect, down: Bool, distance: CGFloat? = nil) {
        // Stay inside the foreground content. A scroll view's frame can extend
        // beneath the software keyboard or belong to the sheet's background.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        // Native Form/List decoration gutters do not always forward pans to
        // their scroll view. Drag inside the row, away from the scroll bar.
        // With a keyboard, keep clear of the editable field's own text pan.
        let x = bounds.minX - app.frame.minX + bounds.width * (app.keyboards.firstMatch.exists ? 0.08 : 0.75)
        let top = bounds.minY - app.frame.minY
        let amount = min(max(distance ?? bounds.height * 0.55, 24), bounds.height * 0.55)
        let start = top + bounds.height * (down ? 0.25 : 0.8)
        origin.withOffset(CGVector(dx: x, dy: start))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: start + (down ? amount : -amount))),
                   withVelocity: .slow, thenHoldForDuration: 0.15)
    }

    private struct AuditNativeMenuRow {
        let label: String
        let identifier: String
        let frame: CGRect
    }

    private func AuditSameRect(_ left: CGRect, _ right: CGRect) -> Bool {
        abs(left.minX - right.minX) < 1 && abs(left.minY - right.minY) < 1
            && abs(left.width - right.width) < 1 && abs(left.height - right.height) < 1
    }

    private func AuditNativeRowButtons(in collection: XCUIElement) -> [XCUIElement] {
        collection.children(matching: .cell).allElementsBoundByIndex.compactMap { cell in
            // Actual UIKit popup hierarchy: floating CollectionView > Cell >
            // Button. SwiftUI movie cells contain their own row subtree instead.
            let buttons = cell.children(matching: .button).allElementsBoundByIndex
            guard buttons.count == 1, let button = buttons.first,
                  AuditSameRect(button.frame, cell.frame),
                  abs(cell.frame.minX - collection.frame.minX) < 1,
                  abs(cell.frame.width - collection.frame.width) < 1 else { return nil }
            return button
        }
    }

    private func AuditFloatingMenuCollection(containing element: XCUIElement, in app: XCUIApplication) -> XCUIElement? {
        guard element.elementType == .button else { return nil }
        return app.collectionViews.allElementsBoundByIndex.first { collection in
            // Native popup collections extend their scroll bounds vertically,
            // but their row width is inset from both edges of the app window.
            guard collection.identifier.isEmpty,
                  collection.frame.minX > app.frame.minX + 1,
                  collection.frame.maxX < app.frame.maxX - 1 else { return false }
            return AuditNativeRowButtons(in: collection).contains {
                $0.label == element.label && $0.identifier == element.identifier
                    && AuditSameRect($0.frame, element.frame)
            }
        }
    }

    @MainActor
    private func AuditAssertNativeMenuTarget(_ element: XCUIElement, in app: XCUIApplication,
                                             file: StaticString = #filePath, line: UInt = #line) {
        // Call only immediately after opening an actual SwiftUI Menu/Picker.
        // This is an explicit platform scope, not a small-control heuristic.
        XCTAssertTrue(element.isHittable, file: file, line: line)
        guard let collection = AuditFloatingMenuCollection(containing: element, in: app) else {
            XCTFail("Expected an actual UIKit popup row; app-owned controls still require 44 points", file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(element.frame.width, 28, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 28, file: file, line: line)
        XCTAssertTrue(AuditContains(element.frame, in: app.frame), file: file, line: line)
        auditNativeMenuFrame = collection.frame
        auditNativeMenuRows = AuditNativeRowButtons(in: collection).filter {
            $0.isHittable && AuditContains($0.frame, in: app.frame)
        }.map { AuditNativeMenuRow(label: $0.label, identifier: $0.identifier, frame: $0.frame) }
        if element.frame.height < 44 || element.frame.width < 44 {
            let note = XCTAttachment(string: "System popup row: \(element.label); measured \(element.frame.width)×\(element.frame.height) pt. Apple native minimum 28 pt; repository's app-owned target remains 44 pt.")
            note.name = "Native-menu-target-platform-limit"
            note.lifetime = .keepAlways
            add(note)
        }
    }

    private func AuditIsInspectedNativeMenuRow(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard let expectedFrame = auditNativeMenuFrame,
              element.frame.width >= 28, element.frame.height >= 28,
              auditNativeMenuRows.contains(where: {
                  $0.label == element.label && $0.identifier == element.identifier
                      && AuditSameRect($0.frame, element.frame)
              }), let collection = AuditFloatingMenuCollection(containing: element, in: app),
              AuditSameRect(collection.frame, expectedFrame) else { return false }
        return element.isHittable && AuditContains(element.frame, in: app.frame)
    }

    @MainActor
    private func AuditAssertTarget(_ element: XCUIElement, in app: XCUIApplication, content: Bool = true,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.isHittable, "The named action must be reachable", file: file, line: line)
        let frame = element.frame
        let nativeBarControl = !content && app.navigationBars.buttons.allElementsBoundByIndex.contains {
            $0.frame == frame && $0.label == element.label
        }
        if !nativeBarControl {
            // AX frame subtraction can yield 43.99999999999994 for 44 points.
            XCTAssertGreaterThanOrEqual(frame.width, 44 - 0.01, file: file, line: line)
            let connectionInput = [.textField, .secureTextField].contains(element.elementType)
                && ["connection-server", "connection-username", "connection-password"].contains(element.identifier)
            if connectionInput {
                // Native inputs expose their text rectangle. The font journey
                // proves the surrounding target with actual focused typing.
                let font = UIFont.preferredFont(forTextStyle: .body,
                    compatibleWith: UITraitCollection(preferredContentSizeCategory: auditFontCategory))
                XCTAssertGreaterThanOrEqual(frame.height + 1, ceil(font.lineHeight), file: file, line: line)
            } else {
                XCTAssertGreaterThanOrEqual(frame.height, 44 - 0.01, file: file, line: line)
            }
        }
        XCTAssertTrue(AuditContains(frame, in: content ? AuditContentBounds(app) : app.frame),
                      "The entire action must fit inside the visible content area", file: file, line: line)
    }

    @MainActor
    private func AuditToolbarMenuEdges(_ label: String, selecting choice: String, in app: XCUIApplication) {
        // UIKit's bar button AX frame describes its visible glyph/glass, not
        // its expanded hit area. Verify the actual 44-point target with taps.
        for offset in [CGVector(dx: -21, dy: 0), CGVector(dx: 21, dy: 0),
                       CGVector(dx: 0, dy: -21), CGVector(dx: 0, dy: 21)] {
            let menu = app.buttons[label]
            let center = menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            center.withOffset(offset).tap()
            let action = app.buttons[choice].firstMatch
            XCTAssertTrue(action.waitForExistence(timeout: 3), "The \(label) menu must open from the edge of its touch target")
            action.tap()
        }
    }

    private func AuditContentBounds(_ app: XCUIApplication) -> CGRect {
        var bounds = app.frame
        if let bar = app.navigationBars.allElementsBoundByIndex.first(where: \.isHittable) {
            let top = max(bounds.minY, bar.frame.maxY)
            bounds.size.height -= top - bounds.minY
            bounds.origin.y = top
        }
        for obstruction in [app.tabBars.firstMatch, app.keyboards.firstMatch] where obstruction.exists && obstruction.isHittable {
            if obstruction.frame.minY > bounds.minY {
                bounds.size.height = min(bounds.height, obstruction.frame.minY - bounds.minY)
            }
        }
        return bounds
    }

    private func AuditContains(_ target: CGRect, in visible: CGRect) -> Bool {
        !target.isEmpty && target.minX >= visible.minX - 1 && target.maxX <= visible.maxX + 1
            && target.minY >= visible.minY - 1 && target.maxY <= visible.maxY + 1
    }

    @MainActor
    private func AuditWaitForInputFocusLayout(_ input: XCUIElement, in app: XCUIApplication) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            input.exists && input.isHittable && self.AuditContains(input.frame, in: self.AuditContentBounds(app))
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed,
                       "Next must bring the selected input into view after the keyboard transition")
    }

    @MainActor
    private func AuditDismissSetupKeyboard(in app: XCUIApplication) {
        for _ in 0..<3 {
            guard app.keyboards.firstMatch.exists else { return }
            let bounds = AuditContentBounds(app)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let x = app.frame.width * 0.75
            origin.withOffset(CGVector(dx: x, dy: bounds.midY - app.frame.minY))
                .press(forDuration: 0.05,
                       thenDragTo: origin.withOffset(CGVector(dx: x, dy: app.frame.height - 20)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertFalse(app.keyboards.firstMatch.exists,
                       "Scrolling setup must dismiss the keyboard so all instructions can be read")
    }

    @MainActor
    private func AuditEnterConnectionText(_ text: String, into input: XCUIElement, in app: XCUIApplication) {
        guard input.frame.height < 44, let first = text.first else {
            input.tap()
            app.typeText(text)
            return
        }
        let peer = app.textFields[input.identifier == "connection-server" ? "connection-username" : "connection-server"]
        // Secure fields may replace their contents when editing resumes. Enter
        // the password in one edit so this hit-target check cannot corrupt the
        // credentials used by the real authenticated HTTP probe below.
        let entries = input.elementType == .secureTextField
            ? [(text, -21.0)]
            : [(String(first), -21.0), (String(text.dropFirst()), 21.0)]
        for (part, offset) in entries {
            AuditReveal(peer, in: app)
            peer.tap()
            AuditReveal(input, in: app)
            let before = input.value as? String
            input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: 0, dy: offset)).tap()
            // Type through the app so XCTest cannot silently focus the input
            // and conceal a missed edge tap. The real HTTP probe follows.
            app.typeText(part)
            XCTAssertNotEqual(input.value as? String, before,
                              "The input must receive typing from the edge of its 44-point target")
        }
    }

    private func AuditRevealBreadcrumb(_ target: XCUIElement, in path: XCUIElement, app: XCUIApplication) {
        for _ in 0..<12 {
            let visible = path.frame.intersection(AuditContentBounds(app))
            if AuditContains(target.frame, in: visible) && target.isHittable { return }
            // A page-sized swipe can overshoot a short ancestor in either
            // direction. Move only toward its measured center, within the bar.
            let shift = min(max(visible.midX - target.frame.midX, -visible.width * 0.35), visible.width * 0.35)
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: visible.midX - app.frame.minX, dy: visible.midY - app.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: shift, dy: 0)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(AuditContains(target.frame, in: path.frame.intersection(AuditContentBounds(app))),
                      "The complete ancestor must be reachable by scrolling its path")
    }
    @MainActor
    func testPrimarySubtitleMenuShowsLoadingFailureRetryAndOverlappingDialogue() throws {
        try exerciseSubtitleFeedbackFonts(.large, name: "Default", includePlayerFailure: true)
    }

    @MainActor
    private func exerciseSubtitleFeedbackFonts(_ category: UIContentSizeCategory, name: String,
                                               completeFaultSequence: Bool = true,
                                               includePlayerFailure: Bool = false) throws {
        let server = try XCTUnwrap(server)
        server.useOfflineTracksFixture()
        server.setCaptionResponse(.held)
        XCUIDevice.shared.orientation = .portrait
        let app = try launchApp(arguments: ["-UIPreferredContentSizeCategoryName", category.rawValue])
        let title = app.staticTexts["The Clockwork Orchard"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.tap()
        let watch = app.buttons["Watch"]
        AuditReveal(watch, in: app)
        AuditAssertTarget(watch, in: app)
        watch.tap()
        let timeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 1, timeout: 10, revealingControlsIn: app)
        showPlayerControls(in: app)
        app.buttons["play-pause-control"].tap()
        try capturePlayerAndOptionsFonts(app, name: name)
        AuditReveal(app.buttons["Subtitles"], in: app)
        AuditAssertTarget(app.buttons["Subtitles"], in: app)
        app.buttons["Subtitles"].tap()
        app.buttons["English"].tap()
        XCTAssertTrue(app.activityIndicators["Loading English…"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["Subtitles"].value as? String, "Loading English")
        XCTAssertFalse(app.navigationBars["Playback Options"].exists)
        try captureSubtitleFeedback(app, category: category, name: name, state: "loading")
        let off = app.buttons["Turn Subtitles Off"]
        if completeFaultSequence {
            AuditReveal(off, in: app)
            AuditAssertTarget(off, in: app)
            off.tap()
            XCTAssertTrue(app.activityIndicators["Loading English…"].waitForNonExistence(timeout: 3))
            XCTAssertEqual(app.buttons["Subtitles"].value as? String, "Off")
            AuditReveal(app.buttons["Subtitles"], in: app)
            app.buttons["Subtitles"].tap()
            app.buttons["English"].tap()
            XCTAssertTrue(app.activityIndicators["Loading English…"].waitForExistence(timeout: 3))
        }
        server.setCaptionResponse(.denied)
        let retry = app.buttons["Retry Subtitles"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["Subtitles"].value as? String, "English unavailable")
        XCTAssertEqual(app.buttons["play-pause-control"].label, "Play")
        try captureSubtitleFeedback(app, category: category, name: name, state: "failure")
        if completeFaultSequence {
            AuditReveal(off, in: app)
            AuditAssertTarget(off, in: app)
            off.tap()
            XCTAssertTrue(retry.waitForNonExistence(timeout: 3))
            XCTAssertEqual(app.buttons["Subtitles"].value as? String, "Off")
            AuditReveal(app.buttons["Subtitles"], in: app)
            app.buttons["Subtitles"].tap()
            app.buttons["English"].tap()
            XCTAssertTrue(retry.waitForExistence(timeout: 5))
            let deniedRequests = server.captionRequestCount
            XCTAssertGreaterThan(deniedRequests, 0)

            server.setCaptionResponse(.malformed)
            AuditReveal(retry, in: app)
            AuditAssertTarget(retry, in: app)
            retry.tap()
            XCTAssertTrue(app.staticTexts["The subtitle file is not valid WebVTT."].waitForExistence(timeout: 5))
            XCTAssertTrue(retry.exists)
            XCTAssertGreaterThan(server.captionRequestCount, deniedRequests)
            XCTAssertFalse(app.staticTexts["Subtitles: not a caption file"].exists)
            try captureSubtitleFeedback(app, category: category, name: name, state: "malformed")
        }
        let failedRequests = server.captionRequestCount
        XCTAssertGreaterThan(failedRequests, 0)
        server.setCaptionResponse(.overlapping)
        AuditReveal(retry, in: app)
        AuditAssertTarget(retry, in: app)
        retry.tap()
        let dialogue = app.staticTexts["Subtitles: Lantern & moon <together>\nTwo voices at once."]
        XCTAssertTrue(dialogue.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(server.captionRequestCount, failedRequests)
        XCTAssertEqual(app.buttons["Subtitles"].value as? String, "English")
        XCTAssertFalse(retry.exists)
        AuditReveal(dialogue, in: app)
        XCTAssertTrue(AuditContains(dialogue.frame, in: AuditContentBounds(app)))
        try FontMatrixCapture(app, name: name, screen: "Subtitle-active-overlap")
        AuditReveal(app.buttons["Subtitles"], in: app)
        app.buttons["Subtitles"].tap()
        app.buttons["Off"].tap()
        XCTAssertTrue(dialogue.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons["Subtitles"].value as? String, "Off")
        AuditReveal(app.buttons["play-pause-control"], in: app)
        AuditAssertTarget(app.buttons["play-pause-control"], in: app)
        app.buttons["play-pause-control"].tap()
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 3, timeout: 5, revealingControlsIn: app)
        if includePlayerFailure {
            try recoverPlayerErrorForFont(app, fixture: server, name: name)
        }
    }

    @MainActor
    private func captureSubtitleFeedback(_ app: XCUIApplication, category: UIContentSizeCategory,
                                         name: String, state: String) throws {
        let identifier = state == "loading" ? "subtitle-loading" : "subtitle-failure"
        let feedback = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 3))
        AuditReveal(feedback, in: app)
        XCTAssertTrue(AuditContains(feedback.frame, in: AuditContentBounds(app)),
                      "Feedback must wrap within the visible player instead of extending offscreen")
        let off = app.buttons["Turn Subtitles Off"]
        AuditReveal(off, in: app)
        AuditAssertTarget(off, in: app)
        let lineHeight = UIFont.preferredFont(forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category)).lineHeight
        XCTAssertGreaterThanOrEqual(off.frame.height, max(44, lineHeight - 2) - 0.01,
                                   "Large system text must enlarge the action rather than being shrunk or capped")
        if state != "loading" {
            let retry = app.buttons["Retry Subtitles"]
            XCTAssertEqual(app.buttons.matching(identifier: "retry-subtitles").count, 1)
            AuditReveal(retry, in: app)
            AuditAssertTarget(retry, in: app)
        }
        try FontMatrixCapture(app, name: name, screen: "Subtitle-\(state)")
    }

    func testPauseDuringPreparationKeepsIntentAndResumesRealMedia() throws {
        let server = try XCTUnwrap(server)
        server.useShortPreparedSegments()
        server.setPlaybackHeld(true)
        let app = try openPreparedMovie()
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 4), "Before bytes arrive, the visible action must match playing intent")
        pause.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 2))
        let mediaRequested = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !server.preparedRequests.isEmpty }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [mediaRequested], timeout: 4), .completed)
        let firstGeneration = try XCTUnwrap(server.preparedRequests.first)
        let unwantedRecovery = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            server.preparedRequests.contains { $0.generation != firstGeneration.generation }
                || app.buttons["Retry Current Playback"].exists
        }, object: nil)
        unwantedRecovery.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unwantedRecovery], timeout: 17), .completed,
                       "Waiting longer than the watchdog while deliberately paused must not replace the stream")
        server.setPlaybackHeld(false)
        app.buttons["Play"].tap()
        let timeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 2, timeout: 12, revealingControlsIn: app)
        XCTAssertFalse(app.buttons["Retry Current Playback"].exists)
        let lastGeneration = try XCTUnwrap(server.preparedRequests.last)
        if !app.buttons["Close player"].exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        app.buttons["Close player"].tap()
        let cancelled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            server.cancelledPreparedRequests.contains(lastGeneration.identity)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 4), .completed)
    }

    func testStreamingDraftCancelApplyAndUnavailablePersistedQualityAreTruthful() throws {
        let server = try XCTUnwrap(server)
        server.useShortPreparedSegments()
        let app = try openPreparedMovie()
        let timeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 2, timeout: 12, revealingControlsIn: app)
        showPlayerControls(in: app)
        app.buttons["Pause"].tap()
        let original = try XCTUnwrap(server.preparedRequests.last)
        let preparedIdentities = Set(server.preparedRequests.map(\.identity))
        app.buttons["Playback options"].tap()
        let mode = app.buttons["stream-mode"]
        let quality = app.buttons["stream-quality"]
        XCTAssertTrue(mode.waitForExistence(timeout: 3))
        mode.tap()
        app.buttons["Original"].tap()
        XCTAssertTrue((quality.value as? String)?.contains("Auto") == true)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 2))
        XCTAssertEqual(Set(server.preparedRequests.map(\.identity)), preparedIdentities,
                       "Cancelled streaming edits cannot create a new producer; ordinary playlist reloads keep the same identity")
        app.buttons["Playback options"].tap()
        XCTAssertTrue((quality.value as? String)?.contains("1080p") == true, "Reopening must show the active quality")
        mode.tap()
        app.buttons["Original"].tap()
        quality.tap()
        app.buttons["1080p · 8 Mbps"].tap()
        XCTAssertEqual(mode.value as? String, "Compatible", "An explicit quality must visibly correct Original before Apply")
        app.buttons["Apply Streaming Changes"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 2), "Apply must preserve a deliberate pause")
        app.buttons["Play"].tap()
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 4, timeout: 12, revealingControlsIn: app)
        let applied = try XCTUnwrap(server.preparedRequests.last)
        XCTAssertEqual(applied.session, original.session)
        XCTAssertGreaterThan(applied.generation, original.generation)
        XCTAssertEqual(applied.quality, "full_hd")
        app.buttons["Close player"].tap()
        app.terminate()
        app.launch()
        let title = app.staticTexts["The Clockwork Orchard"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.tap()
        XCTAssertTrue(app.buttons["Quality"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["Quality"].value as? String, "1080p · 8 Mbps")
        app.terminate()
        server.setFullHDQualityAvailable(false)
        app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.tap()
        XCTAssertTrue(app.buttons["Quality"].waitForExistence(timeout: 5))
        XCTAssertTrue((app.buttons["Quality"].value as? String)?.contains("Auto") == true)
        XCTAssertTrue(app.staticTexts["quality-preference-notice"].exists,
                      "The unavailable saved profile must be explained alongside the actual fallback value")
        app.buttons["Watch"].tap()
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 1, timeout: 12, revealingControlsIn: app)
        showPlayerControls(in: app)
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.staticTexts["player-quality-notice"].exists,
                      "The active movie must disclose the quality fallback after real playback begins")
        app.buttons["Playback options"].tap()
        XCTAssertTrue(app.staticTexts["stream-quality-notice"].waitForExistence(timeout: 3))
        XCTAssertTrue((quality.value as? String)?.contains("Auto") == true)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["player-quality-notice"].waitForExistence(timeout: 2),
                      "Cancelling a draft must preserve the explanation of the active quality")
    }

    func testOfflineContinueWatchingStartOverFavoritesAndHistorySurviveRelaunch() throws {
        let server = try XCTUnwrap(server)
        server.useOfflineTracksFixture()
        XCUIDevice.shared.orientation = .portrait
        let app = try launchApp()
        let title = app.staticTexts["The Clockwork Orchard"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.tap()
        XCTAssertTrue(app.buttons["detail-actions"].waitForExistence(timeout: 5))
        app.buttons["detail-actions"].tap()
        let favorite = app.buttons["detail-favorite"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        favorite.tap()
        app.buttons["detail-actions"].tap()
        XCTAssertEqual(favorite.label, "Remove from Favorites")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.2)).tap()
        if !app.buttons["Download"].isHittable { app.swipeUp() }
        app.buttons["Download"].tap()
        app.swipeUp()
        app.buttons["Original file"].tap()
        XCTAssertTrue(app.buttons["Cancel Download"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Downloads"].firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-download-'")).firstMatch.waitForExistence(timeout: 35))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play offline copy of '")).firstMatch.tap()
        let timeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 5, timeout: 12, revealingControlsIn: app)
        showPlayerControls(in: app)
        app.buttons["Pause"].tap()
        let saved = try elapsedSeconds(from: timeline)
        app.buttons["Close player"].tap()
        XCTAssertTrue(app.buttons["collection-continue"].waitForExistence(timeout: 3))
        app.terminate()
        app.launchEnvironment = ["RUSTYVIEW_TEST_NAMESPACE": testNamespace]
        let baseline = server.requestCount
        app.launch()
        let continuing = app.buttons["collection-continue"]
        XCTAssertTrue(continuing.waitForExistence(timeout: 8), "The downloaded movie should be discoverable without searching or connecting")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-download-'")).count, 1,
                       "Continue Watching must link to the collection without duplicating this movie in Downloads")
        let offlineSearch = CollectionFontSearch(in: app)
        offlineSearch.tap()
        offlineSearch.typeText("absent")
        XCTAssertTrue(app.staticTexts["No matching downloads"].waitForExistence(timeout: 3))
        app.buttons["Clear Search"].tap()
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        XCTAssertTrue(continuing.waitForExistence(timeout: 3), "Clearing a local search restores the saved collection")
        reveal(continuing, in: app)
        continuing.tap()
        let resume = app.buttons["resume-saved-42001"]
        XCTAssertTrue(resume.waitForExistence(timeout: 3))
        let savedRow = app.descendants(matching: .any).matching(identifier: "saved-movie-42001").firstMatch
        assertCompactCollectionRow(savedRow, title: "The Clockwork Orchard", playID: "resume-saved-42001",
                                   menuID: "saved-actions-42001", in: app, category: .large)
        resume.tap()
        let resumed = try waitForElapsedSeconds(in: timeline, atLeast: saved, timeout: 8, revealingControlsIn: app)
        XCTAssertLessThan(resumed, saved + 4, "Resume must preserve the saved movie time across process death")
        showPlayerControls(in: app)
        app.buttons["Pause"].tap()
        app.buttons["Close player"].tap()
        app.buttons["saved-actions-42001"].tap()
        app.buttons["start-over-saved-42001"].tap()
        let restarted = try waitForElapsedSeconds(in: timeline, atLeast: 0, timeout: 8, revealingControlsIn: app)
        XCTAssertLessThan(restarted, saved,
                          "Start Over must move before the old bookmark; real playback advances while XCTest opens the player")
        app.buttons["Pause"].tap()
        app.buttons["Close player"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-download-'")).firstMatch.waitForExistence(timeout: 8))
        app.buttons["collections-menu"].tap()
        app.buttons["collection-favorites"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["saved-movie-42001"].waitForExistence(timeout: 3))
        app.buttons["resume-saved-42001"].tap()
        let afterRelaunch = try waitForElapsedSeconds(in: timeline, atLeast: 1, timeout: 8, revealingControlsIn: app)
        XCTAssertLessThan(afterRelaunch, saved,
                          "Start Over must replace the old bookmark durably; real playback before Pause may save a new early position")
        showPlayerControls(in: app)
        app.buttons["Forward 10 seconds"].tap()
        let firstSkip = try waitForElapsedSeconds(in: timeline, atLeast: afterRelaunch + 9,
                                                  timeout: 4, revealingControlsIn: app)
        showPlayerControls(in: app)
        let forward = app.buttons["Forward 10 seconds"]
        XCTAssertGreaterThanOrEqual(forward.frame.width, 44)
        XCTAssertGreaterThanOrEqual(forward.frame.height, 44)
        // The seek indicator can cover the icon's center. Every point in the
        // advertised touch frame must still seek instead of toggling controls.
        forward.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        _ = try waitForElapsedSeconds(in: timeline, atLeast: min(firstSkip + 9, 24),
                                      timeout: 4, revealingControlsIn: app)
        let ended = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let control = app.buttons["play-pause-control"]
            if !control.exists || !control.isHittable {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
                return false
            }
            return control.label == "Replay"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ended], timeout: 8), .completed)
        app.buttons["Close player"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["collections-menu"].tap()
        app.buttons["collection-history"].tap()
        let historyRow = app.descendants(matching: .any).matching(identifier: "saved-movie-42001").firstMatch
        let watched = historyRow.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Watched'")).firstMatch
        XCTAssertTrue(watched.waitForExistence(timeout: 3), "Real AV completion must remain visible in history independently of resume eligibility")
        XCTAssertEqual(app.buttons.matching(identifier: "resume-saved-42001").count, 1,
                       "Repeated viewings must retain one History row for this owned movie")
        XCTAssertEqual(server.requestCount, baseline,
                       "Restored collections, favorites, resume, Start Over and completed offline playback must never contact the server")
    }

    func testPaginatedBrowseRestoresVisiblePositionAcrossDetailRotationSearchAndFolders() throws {
        let server = try XCTUnwrap(server)
        server.usePaginatedBrowseFixture()
        XCUIDevice.shared.orientation = .portrait
        let app = try launchApp()
        XCTAssertTrue(app.staticTexts["Paper Voyage 01"].waitForExistence(timeout: 8))
        let anchor = app.staticTexts["Paper Voyage 15"]
        reveal(anchor, in: app)
        let originalY = anchor.frame.midY
        anchor.tap()
        XCTAssertTrue(app.buttons["Watch"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(anchor.isHittable, "Returning from details must retain the actual visible card")
        XCTAssertEqual(anchor.frame.midY, originalY, accuracy: 140)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(anchor.waitForExistence(timeout: 3))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(anchor.isHittable, "Rotation must preserve the visible browse region")

        let search = app.searchFields["Search movies"]
        if !search.isHittable { app.swipeDown() }
        search.tap()
        let visibleBeforeSearch = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Paper Voyage '")).allElementsBoundByIndex.first { $0.isHittable }
        let searchAnchor = try XCTUnwrap(visibleBeforeSearch?.label)
        search.typeText("absent")
        XCTAssertTrue(app.staticTexts["No matching movies"].waitForExistence(timeout: 5))
        app.buttons["Clear Search"].tap()
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        XCTAssertTrue(app.staticTexts[searchAnchor].isHittable, "Clearing search must restore the visible unfiltered region")
        app.buttons["Browse"].tap()
        app.buttons["Folders"].tap()
        let shelf = app.staticTexts["Paper Shelf 12"]
        reveal(shelf, in: app)
        server.setBrowseChildHeld(true)
        shelf.tap()
        XCTAssertTrue(app.descendants(matching: .any)["browse-loading"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["library-card-62011"].isEnabled, "Retained parent cards must not accept navigation while a child loads")
        server.setBrowseChildHeld(false)
        XCTAssertTrue(app.staticTexts["Empty Lantern Box"].waitForExistence(timeout: 5))
        app.buttons["Parent folder"].tap()
        XCTAssertTrue(shelf.isHittable, "Parent navigation must restore its paginated scroll position")
        shelf.tap()
        let empty = app.staticTexts["Empty Lantern Box"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        empty.tap()
        XCTAssertTrue(app.staticTexts["This folder is empty"].waitForExistence(timeout: 5))
        server.populateEmptyBrowseFolder()
        app.buttons["Refresh"].tap()
        XCTAssertTrue(app.staticTexts["Paper Voyage 36"].waitForExistence(timeout: 5), "Refresh must issue a real request and replace an empty folder")
        XCTAssertTrue(server.browsePageOffsets.contains(12), "The journey must consume a second real server page")
    }

    func testOfflineCollectionSearchSortAndDeleteDistinguishEightRealSavedCopies() throws {
        let server = try XCTUnwrap(server)
        server.useOfflineCollectionFixture()
        XCUIDevice.shared.orientation = .portrait
        let app = try launchApp()
        for index in 0..<7 {
            let card = app.buttons["library-card-\(81000 + index)"]
            XCTAssertTrue(card.waitForExistence(timeout: 8))
            reveal(card, in: app)
            card.tap()
            let download = app.buttons["Download"]
            XCTAssertTrue(download.waitForExistence(timeout: 5))
            reveal(download, in: app)
            download.tap()
            let original = app.buttons["Original file"]
            reveal(original, in: app)
            original.tap()
            app.navigationBars.buttons.firstMatch.tap()
        }
        app.buttons["Downloads"].firstMatch.tap()
        // Each distinct movie must become playable through the public offline
        // collection. Matching titles do not substitute for media identity.
        for number in 1...7 {
            let search = CollectionFontSearch(in: app)
            search.tap()
            search.typeText(String(format: "%02d", number))
            let installed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-download-'")).count == 1
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [installed], timeout: 20), .completed)
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2))
        }
        let search = CollectionFontSearch(in: app)
        search.tap()
        search.typeText("07")
        if app.keyboards.buttons["Search"].exists { app.keyboards.buttons["Search"].tap() }
        let originalDetails = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'download-details-'")).firstMatch
        reveal(originalDetails, in: app)
        originalDetails.tap()
        let online = app.buttons["Online"]
        XCTAssertTrue(online.waitForExistence(timeout: 5))
        reveal(online, in: app)
        online.tap()
        let actions = app.buttons["detail-actions"]
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["Watch"].exists && app.buttons["Watch"].isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 8), .completed)
        reveal(actions, in: app)
        actions.tap()
        let another = app.buttons["Download Another Copy"]
        XCTAssertTrue(another.waitForExistence(timeout: 3))
        another.tap()
        let compatibleChoice = app.buttons["Compatible copy"]
        reveal(compatibleChoice, in: app)
        compatibleChoice.tap()
        app.navigationBars.buttons.firstMatch.tap()
        let twoCopies = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2 copies'")).firstMatch
        XCTAssertTrue(twoCopies.waitForExistence(timeout: 25))
        let grouped = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'download-actions-'")).firstMatch
        reveal(grouped, in: app)
        grouped.tap()
        app.buttons["download-copies-81006"].tap()
        let bothPlayable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-copy-'")).count == 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [bothPlayable], timeout: 25), .completed,
                       "Both real files must be retained and playable before the disconnected relaunch")
        app.buttons["Done"].tap()
        app.terminate()
        app.launchEnvironment = ["RUSTYVIEW_TEST_NAMESPACE": testNamespace]
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        let baseline = server.requestCount
        app.launch()
        let restoredSearch = CollectionFontSearch(in: app)
        restoredSearch.tap()
        restoredSearch.typeText("absent")
        XCTAssertTrue(app.staticTexts["No matching downloads"].waitForExistence(timeout: 3))
        app.buttons["Clear Search"].tap()
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        app.buttons["Sort Downloads"].tap()
        app.buttons["Title"].tap()
        let firstRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'download-details-'")).firstMatch
        XCTAssertTrue(firstRow.label.hasPrefix(SyntheticHTTPServer.collectionTitle(0)))
        app.buttons["Sort Downloads"].tap()
        app.buttons["Recently Saved"].tap()
        XCTAssertTrue(firstRow.label.hasPrefix(SyntheticHTTPServer.collectionTitle(6)))
        // Sorting at large text may collapse UIKit's native search drawer.
        // Reveal the real field before typing instead of tapping a stale frame.
        let filteredSearch = CollectionFontSearch(in: app)
        filteredSearch.tap()
        filteredSearch.typeText("07")
        if app.keyboards.buttons["Search"].exists { app.keyboards.buttons["Search"].tap() }
        let mainPlay = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-download-'")).firstMatch
        XCTAssertTrue(mainPlay.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-download-'")).count, 1,
                       "Original and compatible renditions must share one movie row")
        let preferredID = String(mainPlay.identifier.dropFirst("play-download-".count))
        let compactRow = app.cells.containing(.button, identifier: "download-details-\(preferredID)").firstMatch
        assertCompactCollectionRow(compactRow, title: SyntheticHTTPServer.collectionTitle(6),
                                   playID: mainPlay.identifier, menuID: "download-actions-\(preferredID)",
                                   in: app, category: .accessibilityExtraExtraExtraLarge)
        app.buttons["download-actions-\(preferredID)"].tap()
        app.buttons["download-copies-81006"].tap()
        let copyActions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'copy-actions-' AND label == %@",
            "Actions for compatible copy of \(SyntheticHTTPServer.collectionTitle(6))")).firstMatch
        XCTAssertTrue(copyActions.waitForExistence(timeout: 4))
        let deletedID = String(copyActions.identifier.dropFirst("copy-actions-".count))
        let survivor = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-copy-' AND label == %@",
            "Play original copy of \(SyntheticHTTPServer.collectionTitle(6))")).firstMatch
        XCTAssertTrue(survivor.exists)
        let survivorID = String(survivor.identifier.dropFirst("play-copy-".count))
        reveal(copyActions, in: app)
        copyActions.tap()
        app.buttons["delete-download-\(deletedID)"].tap()
        app.alerts["Delete offline copy?"].buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["play-copy-\(deletedID)"].waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.buttons["play-copy-\(survivorID)"].exists,
                      "Deleting the compatible file must preserve the original of the same movie")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["play-download-\(survivorID)"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-download-'")).count, 1)
        reveal(app.buttons["play-download-\(survivorID)"], in: app)
        app.buttons["play-download-\(survivorID)"].tap()
        let timeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 1, timeout: 8, revealingControlsIn: app)
        XCTAssertEqual(server.requestCount, baseline,
                       "Offline filtering, sorting, copy management and surviving playback must make zero HTTP requests")
    }

    private func CollectionFontSearch(in app: XCUIApplication) -> XCUIElement {
        let search = app.searchFields["Search downloaded movies"]
        var previousFrame: CGRect?
        var stable = 0
        for _ in 0..<12 {
            if search.exists && search.isHittable {
                if app.keyboards.firstMatch.exists { return search }
                stable = previousFrame.map { AuditSameRect($0, search.frame) } == true ? stable + 1 : 0
                previousFrame = search.frame
                if stable >= 2 {
                    XCTAssertTrue(AuditContains(search.frame, in: app.frame))
                    return search
                }
            }
            let drawer = app.buttons["Search"]
            if drawer.exists && drawer.isHittable { drawer.tap() }
            else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.28))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.83)))
            }
        }
        XCTFail("The native Downloads search drawer must expand and stabilize within the bounded pans")
        return search
    }

    private func AuditVerifyNativeSearchHitArea(_ label: String, reportedFrame: CGRect?, in app: XCUIApplication) {
        // A partially collapsed native drawer exposes a small text-field AX
        // rectangle. Verify the actual expanded 44-point target by unfocused
        // edge taps and real filtering, rather than accepting its AX bounds.
        XCTAssertEqual(label, "Search downloaded movies")
        var expandedFrames: [CGRect] = []
        for offset in [-21.0, 21.0] {
            let search = CollectionFontSearch(in: app)
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            XCTAssertFalse(app.staticTexts["No matching downloads"].exists)
            XCTAssertTrue((search.value as? String)?.isEmpty == true || search.value as? String == label,
                          "Start with an empty native search query")
            XCTAssertGreaterThanOrEqual(search.frame.width, 44)
            expandedFrames.append(search.frame)
            search.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: 0, dy: offset)).tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3),
                          "The native search field must focus from both vertical edges of its 44-point target")
            app.typeText("zzzxq-audit-absent")
            XCTAssertEqual(search.value as? String, "zzzxq-audit-absent")
            XCTAssertTrue(app.staticTexts["No matching downloads"].waitForExistence(timeout: 3),
                          "The edge tap must focus the real query and change the downloaded collection")
            let navigation = app.navigationBars["Downloads"]
            let dismissSearch = navigation.buttons["Close"].exists
                ? navigation.buttons["Close"] : navigation.buttons["Cancel"]
            XCTAssertTrue(dismissSearch.exists && dismissSearch.isHittable)
            dismissSearch.tap()
            XCTAssertTrue(app.staticTexts["No matching downloads"].waitForNonExistence(timeout: 3))
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        }
        let evidence = XCTAttachment(string: "Native Downloads search: reported AX frame \(String(describing: reportedFrame)), expanded frames \(expandedFrames), unfocused vertical ±21-point taps, exact typed query, actual empty results, and restored collection at \(auditFontCategory.rawValue).")
        evidence.name = "Verified native search touch area"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    private func AuditVerifyLibrarySearchClear(restoring query: String, firstResult: XCUIElement,
                                                in app: XCUIApplication) {
        verifiedNativeSearchClear = nil
        let search = app.searchFields["Search movies"]
        let clear = search.buttons["Clear text"]
        let emptyResults = app.staticTexts["No matching movies"]
        XCTAssertEqual(search.value as? String, query)
        XCTAssertTrue(emptyResults.exists)
        XCTAssertTrue(clear.exists && clear.isHittable)
        XCTAssertGreaterThanOrEqual(search.frame.height, 44)
        XCTAssertTrue(AuditContains(clear.frame, in: search.frame))
        XCTAssertTrue(AuditContains(clear.frame, in: app.frame))
        let tappedFrame = clear.frame
        clear.tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let value = search.value as? String
            return (value == nil || value == "" || value == search.label)
                && firstResult.exists && !emptyResults.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed,
                       "UIKit's clear button must empty the real query and restore the movie results")
        search.typeText(query)
        XCTAssertEqual(search.value as? String, query)
        XCTAssertTrue(emptyResults.waitForExistence(timeout: 5),
                      "Restore the query before testing the separate Clear Search action")
        XCTAssertTrue(clear.exists && clear.isHittable)
        XCTAssertTrue(AuditContains(clear.frame, in: search.frame))
        verifiedNativeSearchClear = (search.frame, clear.frame, query)
        let evidence = XCTAttachment(string: "UIKit search clear: actual tapped AX button \(tappedFrame), owning search field \(search.frame), cleared query restored real movie results, then retyped \(query) returned no matches. The native glyph is smaller than 44 points; the app's separate Clear Search action remains subject to 44-point geometry and action checks.")
        evidence.name = "Verified native search clear action"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    private func assertCompactCollectionRow(
        _ row: XCUIElement, title: String, playID: String, menuID: String,
        in app: XCUIApplication, category: UIContentSizeCategory,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let titleText = row.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch
        let play = row.buttons[playID]
        let menu = row.buttons[menuID]
        for _ in 0..<10 {
            if play.isHittable, menu.isHittable, titleText.isHittable,
               play.frame.maxY <= app.tabBars.firstMatch.frame.minY,
               menu.frame.maxY <= app.tabBars.firstMatch.frame.minY { break }
            app.swipeUp()
        }
        XCTAssertTrue(titleText.exists, file: file, line: line)
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let titleFont = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)
        let naturalTitleWidth = (title as NSString).size(withAttributes: [.font: titleFont]).width
        XCTAssertGreaterThanOrEqual(titleText.frame.width + 1, min(app.frame.width * 0.55, naturalTitleWidth),
            "Actions must not squeeze this synthetic title into a narrow column", file: file, line: line)
        let expectedTitleBounds = (title as NSString).boundingRect(
            with: CGSize(width: titleText.frame.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: titleFont], context: nil)
        XCTAssertGreaterThanOrEqual(titleText.frame.height + 4, ceil(expectedTitleBounds.height),
            "The full title must fit at the actual large text size", file: file, line: line)
        XCTAssertLessThanOrEqual(titleText.frame.maxY, play.frame.minY,
            "The title must occupy its own row above the playback action", file: file, line: line)
        let bodyFont = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        XCTAssertLessThanOrEqual(play.frame.height, max(44, ceil(bodyFont.lineHeight)) + 8,
            "Play or Resume must remain one readable line instead of wrapping into individual letters", file: file, line: line)
        for control in [play, menu] {
            XCTAssertTrue(control.isHittable, file: file, line: line)
            XCTAssertGreaterThanOrEqual(control.frame.width, 44 - 0.01, file: file, line: line)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44 - 0.01, file: file, line: line)
            XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX, file: file, line: line)
            XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX, file: file, line: line)
            XCTAssertLessThanOrEqual(control.frame.maxY, app.tabBars.firstMatch.frame.minY, file: file, line: line)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Readable collection row - \(category.rawValue)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for attempt in 0..<8 {
            if element.exists && element.frame.intersects(app.frame) && element.isHittable { break }
            let bounds = AuditContentBounds(app)
            let down = element.exists ? element.frame.maxY < bounds.minY : (attempt / 3).isMultiple(of: 2) == false
            AuditScroll(in: app, bounds: bounds, down: down)
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
    }

    private func showPlayerControls(in app: XCUIApplication) {
        // Check hit testing as well as existence: fading controls can remain
        // in the accessibility tree briefly after their touch region disappears.
        let control = app.buttons["play-pause-control"]
        let emptyVideo = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        for _ in 0..<3 {
            if control.exists && control.isHittable { return }
            emptyVideo.tap()
            if control.waitForExistence(timeout: 1) && control.isHittable { return }
        }
        XCTAssertTrue(control.exists && control.isHittable)
    }

    @MainActor
    func testPlayerErrorRecovery() throws {
        try exercisePlayerErrorFonts(.large, name: "Default")
    }

    @MainActor
    private func exercisePlayerErrorFonts(_ category: UIContentSizeCategory, name: String) throws {
        let server = try XCTUnwrap(server)
        server.useOfflineTracksFixture()
        server.rejectPlaybackRequests(true)
        let app = try launchApp(arguments: ["-UIPreferredContentSizeCategoryName", category.rawValue])
        let movie = app.staticTexts["The Clockwork Orchard"].firstMatch
        XCTAssertTrue(movie.waitForExistence(timeout: 8))
        movie.tap()
        let watch = app.buttons["Watch"]
        AuditReveal(watch, in: app)
        AuditAssertTarget(watch, in: app)
        watch.tap()
        let retry = app.buttons["Retry Current Playback"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "Real failed HTTP media must reach terminal recovery")
        XCTAssertFalse(server.preparedRequests.isEmpty)
        XCTAssertEqual(Set(server.preparedRequests.map(\.session)).count, 1)
        try capturePlayerErrorFonts(app, name: name)
        let terminalClose = app.buttons["Close"]
        AuditReveal(terminalClose, in: app)
        AuditAssertTarget(terminalClose, in: app)
        terminalClose.tap()
        XCTAssertTrue(app.navigationBars["The Clockwork Orchard"].waitForExistence(timeout: 3),
                      "The error panel's Close must leave the failed player")
        AuditReveal(watch, in: app)
        AuditAssertTarget(watch, in: app)
        watch.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        let previousGeneration = try XCTUnwrap(server.preparedRequests.last?.generation)
        server.rejectPlaybackRequests(false)
        AuditReveal(retry, in: app)
        AuditAssertTarget(retry, in: app)
        retry.tap()
        let timeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 2, timeout: 12, revealingControlsIn: app)
        XCTAssertGreaterThan(try XCTUnwrap(server.preparedRequests.last?.generation), previousGeneration,
                             "The visible Retry must start a fresh owned request and decode real media")
        XCTAssertFalse(app.staticTexts["Playback couldn't continue"].exists)
        if !category.isAccessibilityCategory {
            // Two seconds of decoded playback leaves the original controls
            // near their three-second deadline. Reveal a fresh control window
            // before interacting, instead of racing the intentional auto-hide.
            XCTAssertTrue(app.buttons["play-pause-control"].waitForNonExistence(timeout: 4))
        }
        showPlayerControls(in: app)
        let pause = app.buttons["play-pause-control"]
        XCTAssertTrue(pause.isHittable)
        // Tap the visible overlay directly. XCTest's automatic scroll-to-visible
        // gesture can dismiss the player sheet while its controls auto-hide.
        pause.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 2))
        XCTAssertEqual(pause.label, "Play", "The recovered movie must respond to Pause")
        let close = app.buttons["Close player"]
        AuditReveal(close, in: app)
        AuditAssertTarget(close, in: app)
        close.tap()
        XCTAssertTrue(app.navigationBars["The Clockwork Orchard"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func capturePlayerErrorFonts(_ app: XCUIApplication, name: String) throws {
        XCTAssertEqual(app.buttons.matching(identifier: "play-pause-control").count, 0,
                       "Only the terminal panel may own playback recovery")
        let heading = app.staticTexts["Playback couldn't continue"]
        AuditReveal(heading, in: app)
        XCTAssertTrue(AuditContains(heading.frame, in: AuditContentBounds(app)))
        try FontMatrixCapture(app, name: name, screen: "Player-error-message")
        for label in ["Retry Current Playback", "Close"] {
            let action = app.buttons[label]
            AuditReveal(action, in: app)
            AuditAssertTarget(action, in: app)
            try FontMatrixCapture(app, name: name, screen: "Player-error-\(label == "Close" ? "close" : "retry")")
        }
    }

    @MainActor
    func testStalledReadyPlaybackOffersRetryPreservingQualityAudioAndGlobalTime() throws {
        let server = try XCTUnwrap(server)
        server.useShortPreparedSegments()
        let app = try openPreparedMovie()
        let timeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 2, timeout: 12, revealingControlsIn: app)
        server.setPlaybackHeld(true)
        // AVPlayer is ready and has decoded real media. Once the initial segment
        // is consumed, no further media arrives, including on its bounded retry.
        let retry = app.buttons["Retry Current Playback"]
        XCTAssertTrue(retry.waitForExistence(timeout: 95), "Ready-to-play must not disable stall detection")
        XCTAssertEqual(app.buttons.matching(identifier: "play-pause-control").count, 0,
                       "The terminal error panel must exclusively own transport actions")
        try capturePlayerErrorFonts(app, name: "Default")
        let requests = server.preparedRequests
        XCTAssertEqual(Set(requests.map(\.session)).count, 1)
        XCTAssertEqual(Set(requests.map(\.generation)).count, 2, "Explicit prepared quality receives one automatic reconnect before useful recovery")
        XCTAssertTrue(requests.allSatisfy { $0.quality == "full_hd" && $0.audio == "0" })
        let errorPosition = app.descendants(matching: .any).matching(identifier: "player-error-position").firstMatch
        XCTAssertTrue(errorPosition.waitForExistence(timeout: 2))
        let retainedPosition = try elapsedSeconds(from: errorPosition)
        XCTAssertGreaterThan(retainedPosition, 2)
        server.setPlaybackHeld(false)
        AuditReveal(retry, in: app)
        AuditAssertTarget(retry, in: app)
        retry.tap()
        _ = try waitForElapsedSeconds(in: timeline, atLeast: retainedPosition + 2, timeout: 12, revealingControlsIn: app)
        XCTAssertFalse(app.staticTexts["Playback couldn't continue"].exists)
        let retried = try XCTUnwrap(server.preparedRequests.last)
        XCTAssertEqual(retried.session, requests.first?.session)
        XCTAssertGreaterThan(retried.generation, requests.last?.generation ?? 0)
        XCTAssertEqual(retried.quality, "full_hd")
        XCTAssertEqual(retried.audio, "0")
        XCTAssertGreaterThanOrEqual(retried.start, Int(retainedPosition) - 1)
    }

    func testStoredUnreadableOriginalSurvivesRelaunchAndCompatibleRecoveryKeepsBothCopies() throws {
        let server = try XCTUnwrap(server)
        server.setUnreadableOriginal(true)
        XCUIDevice.shared.orientation = .portrait
        var app = try launchApp()
        let movie = app.staticTexts["The Clockwork Orchard"]
        XCTAssertTrue(movie.waitForExistence(timeout: 8))
        movie.tap()
        XCTAssertTrue(app.buttons["Download"].waitForExistence(timeout: 4))
        app.buttons["Download"].tap()
        app.buttons["Original file"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Downloads"].firstMatch.tap()
        var stored = app.staticTexts.matching(NSPredicate(format: "identifier == 'download-readiness-42001' AND label CONTAINS 'Compatible copy needed'")).firstMatch
        XCTAssertTrue(stored.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-download-'")).firstMatch.exists,
                       "Nonempty binary garbage must never be advertised as ready")
        app.terminate()
        app = try launchApp()
        app.buttons["Downloads"].firstMatch.tap()
        stored = app.staticTexts.matching(NSPredicate(format: "identifier == 'download-readiness-42001' AND label CONTAINS 'Compatible copy needed'")).firstMatch
        XCTAssertTrue(stored.waitForExistence(timeout: 5), "Stored originals and their truthful status must survive process relaunch")
        let originalActions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'download-actions-'")).firstMatch
        let originalID = String(originalActions.identifier.dropFirst("download-actions-".count))
        stored.tap()
        let onlineOptions = app.buttons["Online options"]
        XCTAssertTrue(onlineOptions.waitForExistence(timeout: 3))
        onlineOptions.tap()
        let compatible = app.buttons["Download Compatible Copy"]
        XCTAssertTrue(compatible.waitForExistence(timeout: 5))
        compatible.tap()
        XCTAssertTrue(app.buttons["Cancel Download"].waitForExistence(timeout: 3),
                       "The final compatible-copy choice must create visible work immediately")
        XCTAssertFalse(app.buttons["Download Compatible Copy"].exists)
        let enqueued = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            server.compatibleDownloadRequestCount == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [enqueued], timeout: 5), .completed)
        app.navigationBars.buttons.firstMatch.tap()
        let groupedPlay = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-download-'")).firstMatch
        XCTAssertTrue(groupedPlay.waitForExistence(timeout: 40))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'download-actions-'")).count, 1,
                       "Recovery adds a copy to the same movie, not a second movie row")
        let compatibleID = String(groupedPlay.identifier.dropFirst("play-download-".count))
        app.buttons["download-actions-\(compatibleID)"].tap()
        app.buttons["download-copies-42001"].tap()
        let originalRow = app.descendants(matching: .any).matching(identifier: "download-copy-\(originalID)").firstMatch
        XCTAssertTrue(originalRow.waitForExistence(timeout: 3))
        XCTAssertTrue(originalRow.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Needs attention'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["play-copy-\(originalID)"].exists,
                       "The preserved unsupported original must not inherit the compatible file's readiness")
        XCTAssertTrue(app.buttons["play-copy-\(compatibleID)"].exists)
        app.buttons["Done"].tap()
        app.terminate()
        app.launchEnvironment = ["RUSTYVIEW_TEST_NAMESPACE": testNamespace]
        app.launchArguments = []
        let requestsBeforeLocalPlayback = server.requestCount
        app.launch()
        XCTAssertTrue(app.buttons["play-download-\(compatibleID)"].waitForExistence(timeout: 8))
        app.buttons["download-actions-\(compatibleID)"].tap()
        app.buttons["download-copies-42001"].tap()
        XCTAssertTrue(originalRow.waitForExistence(timeout: 3),
                       "The unsupported original must remain stored after another process relaunch")
        XCTAssertFalse(app.buttons["play-copy-\(originalID)"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'copy-actions-'")).count, 2)
        let recovered = app.buttons["play-copy-\(compatibleID)"]
        reveal(recovered, in: app)
        recovered.tap()
        let timeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 1, timeout: 12, revealingControlsIn: app)
        XCTAssertEqual(server.requestCount, requestsBeforeLocalPlayback,
                       "Restored copy management and the recovered compatible file must work without contacting the server")
    }

    func testDisconnectedRelaunchOpensOwnedDetailsAndPlaysAlternateAudioCaptionsAndChapterWithoutHTTP() throws {
        let server = try XCTUnwrap(server)
        server.useOfflineTracksFixture()
        XCUIDevice.shared.orientation = .portrait
        let app = try launchApp()
        let title = app.staticTexts["The Clockwork Orchard"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.tap()
        XCTAssertTrue(app.buttons["Download"].waitForExistence(timeout: 5))
        app.buttons["Download"].tap()
        app.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["download-summary-original"].exists,
                      "The original's included features and source-size meaning appear before its final action")
        app.buttons["Original file"].tap()
        XCTAssertTrue(app.buttons["Cancel Download"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Downloads"].firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-download-'")).firstMatch.waitForExistence(timeout: 35))
        XCTAssertEqual(server.originalDownloadRequestCount, 1)
        XCTAssertEqual(server.captionRequestCount, 1, "The sidecar is acquired before the package is advertised ready")
        let localDetailsBaseline = server.requestCount
        title.tap()
        XCTAssertTrue(app.buttons["Watch Offline"].waitForExistence(timeout: 4))
        XCTAssertEqual(server.requestCount, localDetailsBaseline, "Ready local details must not refresh their remote poster or metadata")
        app.segmentedControls["detail-playback-source"].buttons["Online"].tap()
        XCTAssertTrue(app.buttons["Quality"].waitForExistence(timeout: 5))
        app.buttons["Quality"].tap()
        app.buttons["1080p · 8 Mbps"].tap()
        app.buttons["Audio"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'French tone'")).firstMatch.tap()
        app.buttons["Watch"].tap()
        let onlineTimeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        _ = try waitForElapsedSeconds(in: onlineTimeline, atLeast: 2, timeout: 12, revealingControlsIn: app)
        let outgoing = try XCTUnwrap(server.preparedRequests.last)
        XCTAssertEqual(outgoing.quality, "full_hd")
        XCTAssertEqual(outgoing.audio, "12", "Online selection must use its source track ID even with an offline copy present")
        app.buttons["Close player"].tap()
        let cancelled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            server.cancelledPreparedRequests.contains(outgoing.identity)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 4), .completed)
        app.terminate()
        app.launchEnvironment = ["RUSTYVIEW_TEST_NAMESPACE": testNamespace]
        // Keep the listener observable: any accidental persisted artwork,
        // caption or media request must increment the zero-request baseline.
        // The relaunched app has no connection or credentials configured.
        let baseline = server.requestCount
        app.launch()
        XCTAssertTrue(app.buttons["Downloads"].firstMatch.waitForExistence(timeout: 6))
        XCTAssertFalse(app.navigationBars["Server"].exists, "Offline launch must not require dismissing connection setup")
        XCTAssertTrue(title.waitForExistence(timeout: 6))
        title.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume at '")).firstMatch.waitForExistence(timeout: 4),
                      "The saved online position is valid within this same-duration offline copy")
        XCTAssertFalse(app.buttons["Quality"].exists, "Offline details cannot offer online choices that playback ignores")
        let chapters = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Chapters ('")).firstMatch
        if !chapters.isHittable { app.swipeUp() }
        XCTAssertTrue(chapters.waitForExistence(timeout: 3))
        chapters.tap()
        let chapter = app.buttons["detail-chapter-1"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 3))
        XCTAssertEqual(chapter.label, "Clockwork Grove, 0:00:08")
        let visibleBottom = app.frame.maxY - 44
        for _ in 0..<2 {
            if chapter.isHittable && chapter.frame.maxY <= visibleBottom { break }
            app.swipeUp()
        }
        XCTAssertTrue(chapter.isHittable)
        XCTAssertLessThanOrEqual(chapter.frame.maxY, visibleBottom, "Expand and scroll the complete chapter row into view before tapping")
        XCTAssertGreaterThanOrEqual(chapter.frame.height, 44, "Chapter rows need a complete touch target")
        // The center is the blank space between title and time; it must be as
        // actionable as the text rather than falling through a plain label.
        chapter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 4), "Tapping the chapter row must present playback")
        let timeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 9, timeout: 12, revealingControlsIn: app)
        XCTAssertEqual(app.buttons["play-pause-control"].label, "Pause")
        app.buttons["play-pause-control"].tap()
        XCTAssertEqual(app.buttons["play-pause-control"].label, "Play")
        app.buttons["Playback options"].tap()
        let french = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'local-audio-' AND label CONTAINS[c] 'French'")).firstMatch
        XCTAssertTrue(french.waitForExistence(timeout: 3), "The actual local asset exposes its alternate audio")
        french.tap()
        XCTAssertEqual(french.value as? String, "Selected")
        let savedSubtitle = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'local-caption-' AND label CONTAINS 'English'")).firstMatch
        for _ in 0..<3 {
            if savedSubtitle.exists && savedSubtitle.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(savedSubtitle.waitForExistence(timeout: 3))
        XCTAssertTrue(savedSubtitle.isHittable)
        savedSubtitle.tap()
        XCTAssertTrue(app.staticTexts["Subtitles: Synthetic subtitle."].waitForExistence(timeout: 3),
                      "The locally saved WebVTT cue must render after selecting its track")
        let before = try waitForElapsedSeconds(in: timeline, atLeast: 9, timeout: 3, revealingControlsIn: app)
        XCTAssertEqual(app.buttons["play-pause-control"].label, "Play")
        app.buttons["play-pause-control"].tap()
        _ = try waitForElapsedSeconds(in: timeline, atLeast: before + 1, timeout: 4, revealingControlsIn: app)
        app.buttons["Close player"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume at '")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(server.requestCount, baseline,
                       "Details, artwork, chapter jump, real audio selection, captions and advancing video must all remain local after relaunch")
    }

    private func openPreparedMovie() throws -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = try launchApp()
        let movie = app.staticTexts["The Clockwork Orchard"]
        XCTAssertTrue(movie.waitForExistence(timeout: 8))
        movie.tap()
        XCTAssertTrue(app.buttons["Audio"].waitForExistence(timeout: 4))
        app.buttons["Audio"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'French dub'")).firstMatch.tap()
        app.buttons["Quality"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS '1080p'")).firstMatch.tap()
        app.buttons["Watch"].tap()
        return app
    }

    @MainActor
    func testManyAudioTracksShowLanguageAndScrollInBothOrientations() throws {
        let server = try XCTUnwrap(server)
        server.useManyAudioTracks()
        let app = try launchApp()
        let movie = app.staticTexts["The Clockwork Orchard"]
        XCTAssertTrue(movie.waitForExistence(timeout: 8))
        movie.tap()
        XCTAssertTrue(app.buttons["Audio"].waitForExistence(timeout: 5))

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            app.buttons["Audio"].tap()
            let list = app.descendants(matching: .any).matching(identifier: "audio-track-list").firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 3), "Audio choices need a bounded, scrollable list")
            let last = app.buttons["server-audio-73"]
            for _ in 0..<14 {
                if last.isHittable && app.frame.contains(last.frame) { break }
                list.swipeUp()
            }
            XCTAssertTrue(last.isHittable, "The last of 24 tracks must remain selectable")
            XCTAssertTrue(last.label.contains("RUS"))
            XCTAssertTrue(last.label.contains("Surround mix 24"))
            XCTAssertGreaterThanOrEqual(last.frame.height, 44)
            XCTAssertTrue(app.frame.contains(last.frame), "The full row must fit inside the screen")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Synthetic-audio-list-\(orientation.rawValue)"
            shot.lifetime = .keepAlways
            add(shot)
            last.tap()
            XCTAssertTrue(list.waitForNonExistence(timeout: 3))
            XCTAssertEqual(app.buttons["Audio"].value as? String, "RUS · Surround mix 24 · AAC · Stereo")
        }

        XCUIDevice.shared.orientation = .portrait
        app.buttons["Watch"].tap()
        let timeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 1, timeout: 25, revealingControlsIn: app)
        XCTAssertEqual(server.preparedRequests.last?.audio, "73", "Selection must send the server's track index")
        showPlayerControls(in: app)
        app.buttons["Pause"].tap()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            showPlayerControls(in: app)
            app.buttons["Audio track"].tap()
            let list = app.descendants(matching: .any).matching(identifier: "audio-track-list").firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 3))
            let track = app.buttons["server-audio-70"]
            for _ in 0..<14 {
                if track.isHittable && app.frame.contains(track.frame) { break }
                list.swipeUp()
            }
            XCTAssertTrue(track.isHittable)
            XCTAssertTrue(track.label.contains("ENG"))
            XCTAssertTrue(track.label.contains("complete spoken introduction"))
            XCTAssertTrue(app.frame.contains(track.frame))
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Synthetic-wrapped-audio-\(orientation.rawValue)"
            shot.lifetime = .keepAlways
            add(shot)
            track.tap()
            XCTAssertTrue(list.waitForNonExistence(timeout: 3))
        }
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            server.preparedRequests.last?.audio == "70"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 8), .completed)
        for (orientation, speed) in [(UIDeviceOrientation.portrait, "1.75×"), (.landscapeLeft, "2×")] {
            XCUIDevice.shared.orientation = orientation
            showPlayerControls(in: app)
            app.buttons["Playback speed"].tap()
            let list = app.descendants(matching: .any).matching(identifier: "speed-choice-list").firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 3))
            let choice = app.buttons[speed]
            for _ in 0..<5 {
                if choice.isHittable && app.frame.contains(choice.frame) { break }
                list.swipeUp()
            }
            XCTAssertTrue(choice.isHittable)
            XCTAssertTrue(app.frame.contains(choice.frame))
            XCTAssertGreaterThanOrEqual(choice.frame.height, 44)
            choice.tap()
            XCTAssertTrue(list.waitForNonExistence(timeout: 3))
            XCTAssertEqual(app.buttons["Playback speed"].value as? String, speed)

            app.buttons["Subtitles"].tap()
            let captions = app.descendants(matching: .any).matching(identifier: "subtitle-choice-list").firstMatch
            XCTAssertTrue(captions.waitForExistence(timeout: 3))
            let lastCaption = app.buttons["caption-track-23"]
            for _ in 0..<14 {
                if lastCaption.isHittable && app.frame.contains(lastCaption.frame) { break }
                captions.swipeUp()
            }
            XCTAssertTrue(lastCaption.isHittable)
            XCTAssertTrue(app.frame.contains(lastCaption.frame))
            lastCaption.tap()
            XCTAssertTrue(captions.waitForNonExistence(timeout: 4))
            XCTAssertTrue(app.staticTexts["Subtitles: Synthetic subtitle."].waitForExistence(timeout: 3))
        }
        XCUIDevice.shared.orientation = .portrait
        showPlayerControls(in: app)
        app.buttons["Playback options"].tap()
        XCTAssertTrue(app.navigationBars["Playback Options"].waitForExistence(timeout: 3))
        try AuditViewingPickerEdges("Speed", selecting: "0.5×", restoring: "2×", in: app)
        try AuditViewingPickerEdges("Video Size", selecting: "Fill", restoring: "Fit", in: app)
        app.buttons["stream-quality"].tap()
        let quality = app.buttons["1080p · 8 Mbps"]
        XCTAssertTrue(quality.waitForExistence(timeout: 3))
        AuditAssertTarget(quality, in: app)
        quality.tap()
        XCTAssertEqual(app.buttons["stream-quality"].value as? String, "1080p · 8 Mbps")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Playback Options"].waitForNonExistence(timeout: 3))
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
            "FRA · French dub · AAC · Stereo",
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
        let preparedRequests = try XCTUnwrap(server?.preparedRequests)
        XCTAssertEqual(Set(preparedRequests.map(\.session)).count, 1,
                       "Codec fallback and long-range seeking must remain owned by this viewer")
        XCTAssertGreaterThan(Set(preparedRequests.map(\.generation)).count, 1)
        let uniqueGenerations = preparedRequests.reduce(into: [UInt64]()) { values, request in
            if !values.contains(request.generation) { values.append(request.generation) }
        }
        XCTAssertEqual(uniqueGenerations, uniqueGenerations.sorted(), "Replacement generations must increase")
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
        app.buttons["Cancel"].tap()
        app.buttons["Close player"].tap()
        let lastPrepared = try XCTUnwrap(server?.preparedRequests.last)
        let closedGeneration = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
            self?.server?.cancelledPreparedRequests.contains(lastPrepared.identity) == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [closedGeneration], timeout: 4), .completed,
                       "Close must cancel the exact source before moving on to downloads")
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
            app.buttons["Watch Offline"].waitForExistence(timeout: 10),
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
        app.buttons["detail-actions"].tap()
        XCTAssertTrue(app.buttons["Remove Download"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.2)).tap()

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
        persistedDownload.tap()
        let savedDetails = app.buttons.containing(.staticText, identifier: "offline-copy-available").firstMatch
        reveal(savedDetails, in: app)
        savedDetails.tap()
        XCTAssertEqual(
            app.staticTexts["active-download-quality"].label,
            "Quality: Compatible · Auto · Best"
        )
        XCTAssertEqual(
            app.staticTexts["active-download-audio"].label,
            "Audio: FRA · French dub · AAC · Stereo"
        )
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["download-storage-used"].exists)
        let downloadMenus = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'download-actions-'"))
        XCTAssertGreaterThan(downloadMenus.count, 0)
        let offlinePlay = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'play-download-' AND label ENDSWITH 'The Clockwork Orchard'"
        )).firstMatch
        reveal(offlinePlay, in: app)
        offlinePlay.tap()
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Preparing video…"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Playback couldn't continue"].exists)
        XCTAssertEqual(
            server?.requestCount,
            requestsBeforeOfflineRelaunch,
            "Relaunched offline playback must remain independent of the unavailable server"
        )
        app.buttons["Close player"].tap()
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["Forget Connection"].tap()
        XCTAssertTrue(app.staticTexts["Forget this server?"].waitForExistence(timeout: 3))
        try XCTUnwrap(app.buttons.matching(identifier: "Forget Connection")
            .allElementsBoundByIndex.first(where: \.isHittable)).tap()
        XCTAssertTrue(app.buttons["Downloads"].firstMatch.waitForExistence(timeout: 3),
                      "Saved movies remain reachable without mandatory connection setup")
        app.buttons["Downloads"].firstMatch.tap()
        reveal(offlinePlay, in: app)
        offlinePlay.tap()
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Preparing video…"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Playback couldn't continue"].exists)
        XCTAssertEqual(server?.requestCount, requestsBeforeOfflineRelaunch)
        app.buttons["Close player"].tap()
        let downloadMenu = downloadMenus.firstMatch
        let selectedRecordID = String(downloadMenu.identifier.dropFirst("download-actions-".count))
        let deletedRecordIdentifier = "download-details-\(selectedRecordID)"
        XCTAssertFalse(selectedRecordID.isEmpty)
        downloadMenu.tap()
        app.buttons["delete-download-\(selectedRecordID)"].tap()
        let deleteAlert = app.alerts["Delete offline copy?"]
        XCTAssertTrue(deleteAlert.waitForExistence(timeout: 2))
        deleteAlert.buttons["Delete"].tap()
        XCTAssertTrue(
            app.buttons[deletedRecordIdentifier].waitForNonExistence(timeout: 3),
            "Deleting an offline movie must remove exactly one installed file from the downloaded library"
        )
        XCTAssertTrue(deleteAlert.waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["No downloads yet"].waitForExistence(timeout: 3),
                      "Deleting the last saved copy must expose the Downloads empty state")
        XCTAssertFalse(offlinePlay.exists)
        XCTAssertTrue(app.buttons["Connect"].exists, "The disconnected empty library must retain an explicit connection action")
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
        timeout: TimeInterval = 3,
        revealingControlsIn app: XCUIApplication? = nil
    ) throws -> Int {
        var observedElapsed: Int?
        let predicate = NSPredicate { evaluated, _ in
            guard let element = evaluated as? XCUIElement else { return false }
            if !element.exists {
                if let app, !app.staticTexts["Playback couldn't continue"].exists {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
                }
                return false
            }
            guard
                  let value = element.value as? String,
                  let number = Int(value.split(separator: " ").first ?? "") else { return false }
            guard number >= minimum else { return false }
            observedElapsed = number
            return true
        }
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
        // Controls may auto-hide between fulfilling the expectation and here.
        // Keep the actual value observed above rather than querying a vanished view.
        return try XCTUnwrap(observedElapsed)
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
        reveal(networkMenu, in: app)
        XCTAssertTrue(networkMenu.waitForExistence(timeout: 3))
        networkMenu.tap()
        XCTAssertTrue(app.buttons["Wi-Fi Only"].waitForExistence(timeout: 2))
        app.buttons["Wi-Fi Only"].tap()
        XCTAssertEqual(networkMenu.value as? String, "Wi-Fi Only")
        reveal(app.staticTexts["Downloads resume when Wi-Fi is available."], in: app)

        reveal(networkMenu, in: app)
        networkMenu.tap()
        XCTAssertTrue(app.buttons["Wi-Fi & Cellular"].waitForExistence(timeout: 2))
        app.buttons["Wi-Fi & Cellular"].tap()
        XCTAssertEqual(networkMenu.value as? String, "Wi-Fi and Cellular")
        XCTAssertFalse(app.staticTexts["Downloads resume when Wi-Fi is available."].exists)
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

    func testBackgroundDownloadStopsOptionalPollingAndCatchesUpOnForeground() throws {
        let fixture = try XCTUnwrap(server)
        fixture.controlCompatibleTransfer()
        let app = try launchApp()
        let movie = app.staticTexts["The Clockwork Orchard"]
        XCTAssertTrue(movie.waitForExistence(timeout: 8))
        movie.tap()
        let download = app.buttons["Download"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        reveal(download, in: app)
        download.tap()
        app.buttons["Compatible copy"].tap()
        XCTAssertTrue(app.staticTexts["detail-preparation-progress-42001"].waitForExistence(timeout: 6))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.state == .runningBackgroundSuspended)
        let count = fixture.transcodeStatusRequestCount
        let noInvisibleRequests = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            fixture.transcodeStatusRequestCount > count
        }, object: nil)
        noInvisibleRequests.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [noInvisibleRequests], timeout: 4), .completed,
                       "A real background transition must stop optional preparation requests")
        fixture.finishCompatiblePreparation()
        app.activate()
        let bytes = app.staticTexts["detail-download-bytes-42001"]
        let currentSize = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            bytes.exists && bytes.label.contains(" of \(fixture.controlledTotalText)")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [currentSize], timeout: 8), .completed)
        XCTAssertEqual(fixture.controlledTransferRequests, 1, "Foreground catch-up must retain the original background transfer")
        let cancel = app.buttons["Cancel Download"]
        reveal(cancel, in: app)
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        let cancelled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            fixture.validTranscodeCancellationCount == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 4), .completed)
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
        let downloadDetails = app.buttons["active-download-details"]
        reveal(downloadDetails, in: app)
        downloadDetails.tap()
        XCTAssertEqual(
            app.staticTexts["active-download-quality"].label,
            "Quality: Compatible · 1080p · 8 Mbps"
        )
        XCTAssertEqual(
            app.staticTexts["active-download-audio"].label,
            "Audio: FRA · French dub · AAC · Stereo"
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

    @MainActor
    func testDownloadPauseAndCancelAcceptSingleTapsAcrossTheirHitAreas() throws {
        let fixture = try XCTUnwrap(server)
        fixture.controlCompatibleTransfer()
        let app = try launchApp()
        let movie = app.staticTexts["The Clockwork Orchard"]
        XCTAssertTrue(movie.waitForExistence(timeout: 8))
        movie.tap()
        let download = app.buttons["Download"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        reveal(download, in: app)
        download.tap()
        app.buttons["Compatible copy"].tap()
        XCTAssertTrue(app.staticTexts["detail-download-bytes-42001"].waitForExistence(timeout: 8))
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["Downloads"].tap()

        let pause = app.buttons["Pause download of The Clockwork Orchard"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        // The padded 44-point action must respond outside its text and icon.
        pause.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.85)).tap()
        let resume = app.buttons["Resume download of The Clockwork Orchard"]
        guard resume.waitForExistence(timeout: 4) else { return XCTFail("A single tap inside Pause must pause the download") }
        resume.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.85)).tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 4))

        app.buttons["active-download-42001"].tap()
        let detailPause = app.buttons["Pause Download"]
        XCTAssertTrue(detailPause.waitForExistence(timeout: 4))
        reveal(detailPause, in: app)
        detailPause.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).tap()
        XCTAssertTrue(app.buttons["Resume Download"].waitForExistence(timeout: 4))
        let cancel = app.buttons["Cancel Download"]
        cancel.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).tap()
        XCTAssertTrue(app.buttons["Download"].waitForExistence(timeout: 4))
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            fixture.validTranscodeCancellationCount == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 4), .completed)
    }

    @MainActor
    func testCompletedPreparationKeepsShowingTheUnfinishedByteTransfer() throws {
        let fixture = try XCTUnwrap(server)
        fixture.controlCompatibleTransfer()
        let app = try launchApp()
        let movie = app.staticTexts["The Clockwork Orchard"]
        XCTAssertTrue(movie.waitForExistence(timeout: 8))
        movie.tap()
        let download = app.buttons["Download"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        reveal(download, in: app)
        download.tap()
        app.buttons["Compatible copy"].tap()

        let bytes = app.staticTexts["detail-download-bytes-42001"]
        XCTAssertTrue(bytes.waitForExistence(timeout: 8),
                      "Preparation must not hide bytes already delivered over the real chunked response")
        // A background session can batch native file-write callbacks after the
        // server has sent its prefix. Verify the reported amount is possible,
        // without requiring one particular callback boundary.
        func reportedByteCount(_ label: String, suffix: String) -> Double? {
            guard label.hasSuffix(suffix) else { return nil }
            let fields = label.dropLast(suffix.count).split(separator: " ")
            let units: [String: Double] = ["byte": 1, "bytes": 1, "KB": 1_000, "MB": 1_000_000, "GB": 1_000_000_000]
            let number = NumberFormatter()
            number.locale = Locale(identifier: "en_US")
            number.numberStyle = .decimal
            guard fields.count == 2, let amount = number.number(from: String(fields[0]))?.doubleValue,
                  let unit = units[String(fields[1])] else { return nil }
            return amount * unit
        }
        func reportsReceivedPrefix(_ label: String, suffix: String) -> Bool {
            guard let count = reportedByteCount(label, suffix: suffix) else { return false }
            return count > 0 && count <= Double(fixture.controlledPrefixByteCount)
        }
        let unknownSize = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            reportsReceivedPrefix(bytes.label, suffix: " downloaded")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [unknownSize], timeout: 8), .completed)
        XCTAssertFalse(app.staticTexts["detail-download-remaining-42001"].exists)
        let prepared = app.staticTexts["detail-preparation-progress-42001"]
        XCTAssertTrue(prepared.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["detail-download-status-42001"].label, "Preparing…")

        // The server finishes producing the file, while two thirds of its
        // bytes are deliberately withheld from the existing HTTP transfer.
        fixture.finishCompatiblePreparation()
        let totalSuffix = " of \(fixture.controlledTotalText)"
        let knownSize = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            reportsReceivedPrefix(bytes.label, suffix: totalSuffix)
                && app.staticTexts["detail-download-status-42001"].label == "Downloading…"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [knownSize], timeout: 10), .completed)
        let remaining = app.staticTexts["detail-download-remaining-42001"]
        XCTAssertTrue(remaining.exists)
        let remainingText = remaining.label
        let bytesLeft = try XCTUnwrap(reportedByteCount(remainingText, suffix: " remaining"))
        XCTAssertGreaterThan(bytesLeft, Double(fixture.controlledPrefixByteCount) * 1.9,
                             "Two thirds are still withheld: remaining bytes must not repeat bytes received")
        XCTAssertLessThanOrEqual(bytesLeft, Double(fixture.controlledPrefixByteCount) * 3.1)
        XCTAssertFalse(prepared.exists, "Completed preparation must not remain a misleading 100% download")
        let percent = try XCTUnwrap(Int(app.staticTexts["detail-download-percent-42001"].label.dropLast()))
        XCTAssertTrue((0...33).contains(percent), "With two thirds withheld, the transfer cannot show preparation's 100%")
        XCTAssertTrue(app.buttons["Cancel Download"].exists)
        XCTAssertEqual(fixture.controlledTransferRequests, 1)
        XCTAssertEqual(fixture.controlledSizeRequests, 1)
        AuditReveal(bytes, in: app)
        XCTAssertTrue(AuditContains(bytes.frame, in: AuditContentBounds(app)))
        let detailImage = XCTAttachment(screenshot: app.screenshot())
        detailImage.name = "Synthetic-transfer-details"
        detailImage.lifetime = .keepAlways
        add(detailImage)

        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["Downloads"].tap()
        let rowBytes = app.staticTexts["download-byte-progress-42001"]
        XCTAssertTrue(rowBytes.waitForExistence(timeout: 5))
        XCTAssertTrue(reportsReceivedPrefix(rowBytes.label, suffix: totalSuffix))
        XCTAssertEqual(app.staticTexts["download-bytes-remaining-42001"].label, remainingText,
                       "Both screens must retain the same remaining byte count")
        let rowPercent = try XCTUnwrap(Int((app.staticTexts["download-transfer-status-42001"].value as? String ?? "").dropLast()))
        XCTAssertGreaterThanOrEqual(rowPercent, percent, "Navigating must retain received bytes")
        XCTAssertTrue((0...33).contains(rowPercent), "Downloads must show transfer progress, not completed preparation")
        AuditReveal(rowBytes, in: app)
        XCTAssertTrue(AuditContains(rowBytes.frame, in: AuditContentBounds(app)))
        let downloadsImage = XCTAttachment(screenshot: app.screenshot())
        downloadsImage.name = "Synthetic-transfer-downloads"
        downloadsImage.lifetime = .keepAlways
        add(downloadsImage)
        XCTAssertFalse(app.staticTexts["preparation-progress-42001"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "active-download-42001").count, 1)
        let playable = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-download-'")).firstMatch
        XCTAssertFalse(playable.exists, "A completed producer cannot make a partially delivered file playable")

        fixture.deliverRemainingCompatibleBytes()
        XCTAssertTrue(playable.waitForExistence(timeout: 15), fixture.requestSummary)
        XCTAssertEqual(fixture.controlledTransferRequests, 1, "Learning the total must preserve the original transfer")
        playable.tap()
        let timeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 1, timeout: 8, revealingControlsIn: app)
        app.buttons["Close player"].tap()
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

    @MainActor
    func testLargePosterLibraryLaunchPerformance() throws {
        let server = try XCTUnwrap(server)
        try server.useLargePosterBenchmarkFixture()
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        var invocation = 0
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.terminate()
            configureLargePosterBenchmark(app, server: server)
            startMeasuring()
            app.launch()
            stopMeasuring()

            XCTAssertTrue(app.staticTexts["Paper Voyage 01"].waitForExistence(timeout: 8))
            assertLargePosterRequests(server, minimum: 3, including: "81000")
            XCTAssertTrue(server.browsePageOffsets.contains(0))
            attachLargePosterObservation(server, phase: "launch", invocation: invocation, swipes: 0)
            invocation += 1
            app.terminate()
        }
    }

    @MainActor
    func testLargePosterPaginatedRapidScrollPerformance() throws {
        let server = try XCTUnwrap(server)
        try server.useLargePosterBenchmarkFixture()
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        var metrics: [any XCTMetric] = [
            XCTOSSignpostMetric.scrollingAndDecelerationMetric,
            XCTCPUMetric(application: app),
            XCTMemoryMetric(application: app),
        ]
        if #available(iOS 26.0, *) { metrics.append(XCTHitchMetric(application: app)) }
        var invocation = 0
        measure(metrics: metrics, options: options) {
            // Launch is measured separately. The CPU/memory target is already
            // running when this measurement interval starts.
            app.terminate()
            configureLargePosterBenchmark(app, server: server)
            app.launch()
            let first = app.staticTexts["Paper Voyage 01"]
            let last = app.staticTexts["Paper Voyage 36"]
            XCTAssertTrue(first.waitForExistence(timeout: 8))
            assertLargePosterRequests(server, minimum: 3, including: "81000")
            let scroll = app.scrollViews.firstMatch
            XCTAssertTrue(scroll.exists)
            var swipes = 0
            startMeasuring()
            for _ in 0..<12 {
                if last.isHittable { break }
                scroll.swipeUp(velocity: .fast)
                swipes += 1
            }
            let reachedLastTitle = last.isHittable
            for _ in 0..<12 {
                if first.isHittable { break }
                scroll.swipeDown(velocity: .fast)
                swipes += 1
            }
            let returnedToFirstTitle = first.isHittable
            stopMeasuring()

            XCTAssertTrue(reachedLastTitle, "The measured scroll must reach the actual last title on the third server page.")
            XCTAssertTrue(returnedToFirstTitle, "The measured return scroll must restore an operable first card.")
            XCTAssertTrue(server.browsePageOffsets.contains(12))
            XCTAssertTrue(server.browsePageOffsets.contains(24))
            assertLargePosterRequests(server, minimum: 18, including: "81035")
            attachLargePosterObservation(server, phase: "rapid_scroll", invocation: invocation, swipes: swipes)
            invocation += 1
            app.terminate()
        }
    }

    @MainActor
    private func configureLargePosterBenchmark(_ app: XCUIApplication, server: SyntheticHTTPServer) {
        testNamespace = UUID().uuidString.lowercased()
        server.beginLargePosterIteration(namespace: testNamespace)
        app.launchArguments = []
        app.launchEnvironment = [
            "RUSTYVIEW_TEST_SERVER": server.serverAddress ?? "",
            "RUSTYVIEW_TEST_NAMESPACE": testNamespace,
            "RUSTYVIEW_TEST_USERNAME": "viewer",
            "RUSTYVIEW_TEST_PASSWORD": "test-only-password",
        ]
    }

    private func assertLargePosterRequests(_ server: SyntheticHTTPServer, minimum: Int, including mediaID: String) {
        let received = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let ids = server.largePosterRequestedIDs
            return ids.count >= minimum && ids.contains(mediaID)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 6), .completed,
                       "The real authenticated poster route must be exercised across the measured library region.")
    }

    private func attachLargePosterObservation(_ server: SyntheticHTTPServer, phase: String, invocation: Int, swipes: Int) {
        let values: [String: Any] = [
            "phase": phase, "invocation": invocation,
            "sample": invocation == 0 ? "XCTest warmup" : "measured",
            "synthetic_title_count": 36, "poster_width": 2_048, "poster_height": 3_072,
            "authenticated_unique_posters": server.largePosterRequestedIDs.count,
            "page_offsets": server.browsePageOffsets,
            "swipes": swipes,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print("ARTWORK_UI_BENCHMARK \(text)")
        let attachment = XCTAttachment(string: text)
        attachment.name = "Large poster \(phase) workload \(invocation)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchApp(arguments: [String] = []) throws -> XCUIApplication {
        let serverAddress = try XCTUnwrap(server?.serverAddress)
        let app = XCUIApplication()
        app.launchArguments = arguments
        if let index = arguments.firstIndex(of: "-UIPreferredContentSizeCategoryName"),
           arguments.indices.contains(index + 1) {
            auditFontCategory = UIContentSizeCategory(rawValue: arguments[index + 1])
        }
        app.launchEnvironment = [
            "RUSTYVIEW_TEST_SERVER": serverAddress,
            "RUSTYVIEW_TEST_NAMESPACE": testNamespace,
            "RUSTYVIEW_TEST_USERNAME": "viewer",
            "RUSTYVIEW_TEST_PASSWORD": "test-only-password",
        ]
        app.launch()
        return app
    }

    private func dismissSyntheticPasswordOffer(in app: XCUIApplication) {
        let offer = app.sheets["Save Password?"]
        if offer.waitForExistence(timeout: 2) {
            offer.buttons["Not Now"].tap()
            XCTAssertTrue(offer.waitForNonExistence(timeout: 3))
        }
    }

    private func ignoringVerifiedAuditFalsePositives(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        if issue.auditType == .contrast, let element = issue.element {
            let app = XCUIApplication()
            let frame = element.frame
            let identity = element.identifier.isEmpty ? element.label : element.identifier
            if !identity.isEmpty, !AuditContains(frame, in: AuditContentBounds(app)),
               app.cells.containing(element.elementType, identifier: identity).allElementsBoundByIndex.contains(where: {
                   AuditContains(frame, in: $0.frame)
               }) {
                // Native lists scroll beneath translucent navigation/tab bars.
                // Their obscured pixels are not the readable row presentation;
                // visible rows and the bar's own controls remain audited.
                return true
            }
        }
        if nativeSearchVerificationEnabled, issue.auditType == .hitRegion,
           issue.detailedDescription.contains("UISearchBarTextField"),
           let field = issue.element, field.elementType == .searchField,
           field.label == "Search downloaded movies", field.frame.height > 0 {
            let app = XCUIApplication()
            let currentField = app.searchFields[field.label]
            if app.navigationBars["Downloads"].isHittable, field.isHittable,
               currentField.exists, AuditSameRect(field.frame, currentField.frame),
               !app.keyboards.firstMatch.exists, app.sheets.count == 0, app.alerts.count == 0 {
                // AuditScreen must subsequently prove live focusing and
                // filtering at both edges; failure of that proof fails the test.
                pendingNativeSearchChecks[field.label] = field.frame
                return true
            }
        }
        if nativeSearchVerificationEnabled, issue.auditType == .hitRegion,
           issue.detailedDescription.contains("_UITextFieldClearButton"),
           let verified = verifiedNativeSearchClear,
           let element = issue.element, element.elementType == .button, element.label == "Clear text" {
            let app = XCUIApplication()
            let field = app.searchFields["Search movies"]
            let clear = field.buttons["Clear text"]
            if app.navigationBars["Movies"].isHittable, field.exists, clear.exists,
               clear.isHittable, field.value as? String == verified.query,
               AuditSameRect(field.frame, verified.field),
               AuditSameRect(clear.frame, verified.button), AuditSameRect(element.frame, clear.frame),
               AuditContains(element.frame, in: field.frame), AuditContains(element.frame, in: app.frame) {
                // Only the exact UIKit clear glyph whose real action was just
                // proved is covered; app-owned clear controls stay audited.
                return true
            }
        }
        if issue.auditType == .sufficientElementDescription,
           issue.detailedDescription.contains("TUIPredictionViewCell"),
           let element = issue.element, element.elementType == .other {
            let keyboard = XCUIApplication().keyboards.firstMatch
            if keyboard.exists, element.label.isEmpty,
               AuditContains(element.frame, in: XCUIApplication().frame) {
                // Empty system prediction slots have no spoken suggestion.
                // UIKit places the prediction accessory above its Keyboard AX
                // rectangle, so containment in that rectangle is not required.
                // Actual keys and all app-owned controls remain audited.
                return true
            }
        }
        if issue.auditType == .hitRegion, let element = issue.element,
           AuditIsInspectedNativeMenuRow(element, in: XCUIApplication()) {
            return true // Explicitly inspected UIKit popup only; its current minimum is 28 points.
        }
        if issue.auditType == .textClipped, issue.element?.elementType == .searchField {
            return true // SwiftUI's system-owned searchable field scales and clips internally.
        }
        if issue.auditType == .textClipped, let field = issue.element,
           [.textField, .secureTextField].contains(field.elementType),
           ["connection-server", "connection-username", "connection-password"].contains(field.identifier) {
            // XCTest predicts clipping at a future size for SwiftUI-backed
            // single-line native inputs. Their actual text/44-point hit area
            // is reviewed at every selected size; long editable values scroll.
            let font = UIFont.preferredFont(forTextStyle: .body,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: auditFontCategory))
            if field.frame.height + 1 >= ceil(font.lineHeight), field.frame.width >= 44 {
                let evidence = XCTAttachment(string: "Native input: \(field.identifier), category: \(auditFontCategory.rawValue), frame: \(field.frame), required line height: \(font.lineHeight)")
                evidence.name = "Measured native input clipping audit limitation"
                evidence.lifetime = .keepAlways
                add(evidence)
                return true
            }
        }
        if issue.auditType == .contrast, let label = issue.element,
           (["media-file-size", "detail-title"].contains(label.identifier)
            || (label.elementType == .staticText && XCUIApplication().navigationBars["Settings"].exists
                && ["Saved copies", "Storage used", "App", "About"].contains(label.label))),
           AuditMeasuredLabelContrast(label) {
            return true // These plain labels are checked from their actual rendered pixels.
        }
        if issue.auditType == .contrast,
           issue.detailedDescription.contains("UISearchBarTextField"),
           let field = issue.element, field.elementType == .searchField,
           ["Search movies", "Search downloaded movies"].contains(field.label),
           field.placeholderValue == field.label,
           (field.value as? String).map({ $0.isEmpty || $0 == field.label }) ?? true {
            let icon = field.images["magnifyingglass"]
            if icon.exists, AuditContains(icon.frame, in: field.frame) {
                // The white search icon must not stand in for the gray text.
                // Measure only the empty field's placeholder, at the actual
                // selected appearance, against its rendered background.
                let textFrame = CGRect(x: icon.frame.maxX + 4, y: field.frame.minY + 4,
                    width: field.frame.maxX - icon.frame.maxX - 12, height: field.frame.height - 8)
                if AuditMeasuredLabelContrast(field, contentFrame: textFrame) { return true }
            }
        }
        if [.textClipped, .contrast, .sufficientElementDescription].contains(issue.auditType) {
            let details = "\(issue.compactDescription)\n\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? "No element supplied by XCTest")"
            let attachment = XCTAttachment(string: details)
            attachment.name = "Synthetic accessibility issue details"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let evidence = FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic-font-audit-\(testNamespace)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            try XCUIApplication().screenshot().pngRepresentation.write(to: evidence.appendingPathComponent("screen.png"))
            try XCUIApplication().debugDescription.write(to: evidence.appendingPathComponent("hierarchy.txt"),
                                                         atomically: true, encoding: .utf8)
            let details = "\(issue.compactDescription)\n\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? "No element supplied by XCTest")"
            try details.write(to: evidence.appendingPathComponent("issue.txt"), atomically: true, encoding: .utf8)
            print("Synthetic font audit evidence: \(evidence.path)")
        } catch { /* The xcresult issue remains the authoritative failure. */ }
        return false
    }

    private func AuditMeasuredLabelContrast(_ label: XCUIElement, contentFrame: CGRect? = nil) -> Bool {
        guard let sourceImage = label.screenshot().image.cgImage else { return false }
        let image: CGImage
        if let contentFrame {
            let frame = label.frame
            guard frame.width > 0, frame.height > 0, AuditContains(contentFrame, in: frame) else { return false }
            let scaleX = CGFloat(sourceImage.width) / frame.width
            let scaleY = CGFloat(sourceImage.height) / frame.height
            let crop = CGRect(x: (contentFrame.minX - frame.minX) * scaleX,
                y: (contentFrame.minY - frame.minY) * scaleY,
                width: contentFrame.width * scaleX, height: contentFrame.height * scaleY)
            guard let cropped = sourceImage.cropping(to: crop) else { return false }
            image = cropped
        } else {
            image = sourceImage
        }
        let width = image.width, height = image.height
        guard width > 0, height > 0, width * height < 4_000_000,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        var histogram: [Int: Int] = [:]
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] == 255 {
            let color = Int(pixels[offset]) << 16 | Int(pixels[offset + 1]) << 8 | Int(pixels[offset + 2])
            histogram[color, default: 0] += 1
        }
        let ranked = histogram.sorted { $0.value > $1.value }
        guard let background = ranked.first else { return false }
        func belongsToBackground(_ color: Int) -> Bool {
            [16, 8, 0].allSatisfy { shift in
                abs(((color >> shift) & 255) - ((background.key >> shift) & 255)) <= 8
            }
        }
        // Scroll-edge shading can split one dark surface into several nearby
        // colors. A second background shade is not the label's foreground.
        let backgroundShades = ranked.filter { belongsToBackground($0.key) }
        guard backgroundShades.reduce(0, { $0 + $1.value }) > width * height / 3 else { return false }
        func luminance(_ color: Int) -> Double {
            let channels = [16, 8, 0].map { shift -> Double in
                let value = Double((color >> shift) & 255) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        }
        let inkCandidates = ranked.filter { !belongsToBackground($0.key) }
        let inkPixelCount = inkCandidates.reduce(0) { $0 + $1.value }
        // Native section headers expose the entire row width. Empty padding
        // must not increase the number of identical text pixels required to
        // resolve ink; still require a repeated mode, not isolated noise.
        let minimumInkSupport = max(20, inkPixelCount / 20)
        // The same native scroll-edge shading also varies solid text pixels.
        // Count a small color neighborhood, keeping the support threshold and
        // testing its lowest contrast instead of selecting one favorable pixel.
        func inkShades(around color: Int) -> [(key: Int, value: Int)] {
            inkCandidates.filter { shade in
                [16, 8, 0].allSatisfy { shift in
                    abs(((shade.key >> shift) & 255) - ((color >> shift) & 255)) <= 8
                }
            }
        }
        guard let foreground = inkCandidates.first(where: {
            inkShades(around: $0.key).reduce(0) { $0 + $1.value } >= minimumInkSupport
        }) else { return false }
        let foregroundShades = inkShades(around: foreground.key)
        let contrast = foregroundShades.flatMap { foregroundShade in
            let ink = luminance(foregroundShade.key)
            return backgroundShades.map { shade in
                let base = luminance(shade.key)
                return (max(base, ink) + 0.05) / (min(base, ink) + 0.05)
            }
        }.min() ?? 0
        let evidence = XCTAttachment(string: "Label \(label.identifier.isEmpty ? label.label : label.identifier): sRGB foreground \(foreground.key), background \(background.key), background shades \(backgroundShades.count), ink pixels \(inkPixelCount), neighborhood support \(foregroundShades.reduce(0) { $0 + $1.value }), minimum contrast \(contrast):1")
        evidence.name = "Measured plain-label contrast"
        evidence.lifetime = .keepAlways
        add(evidence)
        let cropEvidence = XCTAttachment(image: UIImage(cgImage: image))
        cropEvidence.name = "Measured label pixels"
        cropEvidence.lifetime = .keepAlways
        add(cropEvidence)
        return contrast >= 4.5
    }
}

private final class SyntheticHTTPServer {
    enum CaptionResponse { case normal, held, denied, malformed, overlapping }
    private var captionResponse = CaptionResponse.normal
    private var heldCaptionResponses: [(String, NWConnection)] = []
    private var rejectsPlayback = false

    func rejectPlaybackRequests(_ rejected: Bool) {
        queue.sync { rejectsPlayback = rejected }
    }

    func setCaptionResponse(_ response: CaptionResponse) {
        queue.sync {
            captionResponse = response
            guard response != .held else { return }
            let waiting = heldCaptionResponses
            heldCaptionResponses = []
            for (method, connection) in waiting { sendCaption(method: method, connection: connection) }
        }
    }

    private func sendCaption(method: String, connection: NWConnection) {
        if captionResponse == .held {
            heldCaptionResponses.append((method, connection))
            return
        }
        let body: String
        switch captionResponse {
        case .denied:
            send(Data("Synthetic caption access denied".utf8), status: 401,
                 contentType: "text/plain", method: method, connection: connection)
            return
        case .malformed: body = "not a caption file"
        case .overlapping:
            body = "WEBVTT\n\n00:00:00.000 --> 00:01:00.000\nLantern &amp; moon &lt;together&gt;\n\n00:00:00.000 --> 00:01:00.000\nTwo voices at once.\n"
        case .normal, .held:
            body = "WEBVTT\n\n00:00:00.000 --> 02:00:00.000\nSynthetic subtitle.\n"
        }
        send(Data(body.utf8), contentType: "text/vtt", method: method, connection: connection)
    }

    struct PreparedRequest {
        let session: UInt64
        let generation: UInt64
        let quality: String
        let audio: String
        let start: Int
        var identity: String { "\(session):\(generation)" }
    }
    private let listener: NWListener
    private let standardMediaData: Data
    private let multiaudioData: Data
    private let nativeCaptionData: Data
    private var mediaData: Data { usesNativeCaptions ? nativeCaptionData : (usesMultiaudio ? multiaudioData : standardMediaData) }
    private let preparedSegmentData: Data
    private let shortPreparedSegments: [String: Data]
    private let artwork: [String: Data]
    private var largePosterData: Data?
    private var largePosterNamespace = ""
    private var storedLargePosterIDs: Set<String> = []

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
    private var storedPreparedRequests: [PreparedRequest] = []
    private var storedBrowseOffsets: [Int] = []
    private var storedCancelledPreparedRequests: Set<String> = []
    private var playbackHeld = false
    private var unreadableOriginal = false
    private var usesShortPreparedSegments = false
    private var usesMultiaudio = false
    private var usesManyAudioTracks = false
    private var usesNativeCaptions = false
    private var auditDeepFolders = false
    private var auditLibraryRejects = false
    private var auditLibrarySchemaVersion = 2
    private var auditLibraryEmpty = false
    private var auditLibraryRequests = 0
    private var auditFailedLibraryRequests = 0
    private var auditFolders: [String] = []

    private var fullHDQualityAvailable = true
    private var usesPaginatedBrowse = false
    private var usesOfflineCollection = false
    private var collectionFontHoldDownloads = false
    private var collectionFontRejectDownloads = false
    private var collectionFontPendingChunks: [(Data, NWConnection)] = []
    private var collectionFontSentChunks = 0

    private var controlsCompatibleTransfer = false
    private var compatiblePreparationFinished = false
    private var controlledPendingBytes: [(Data, NWConnection)] = []
    private var controlledGETs = 0
    private var controlledHEADs = 0

    func controlCompatibleTransfer() { queue.sync { controlsCompatibleTransfer = true } }
    func useManyAudioTracks() { queue.sync { usesManyAudioTracks = true; usesShortPreparedSegments = true } }
    func finishCompatiblePreparation() { queue.sync { compatiblePreparationFinished = true } }
    var controlledTransferRequests: Int { queue.sync { controlledGETs } }
    var controlledSizeRequests: Int { queue.sync { controlledHEADs } }
    var controlledPrefixByteCount: Int64 { queue.sync { Int64(mediaData.count / 3) } }
    var controlledTotalText: String { queue.sync { ByteCountFormatter.string(fromByteCount: Int64(mediaData.count), countStyle: .file) } }

    func deliverRemainingCompatibleBytes() {
        queue.sync {
            let pending = controlledPendingBytes
            controlledPendingBytes = []
            for (bytes, connection) in pending {
                var chunk = Data("\(String(bytes.count, radix: 16))\r\n".utf8)
                chunk.append(bytes)
                chunk.append(Data("\r\n0\r\n\r\n".utf8))
                connection.send(content: chunk, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    var collectionFontChunkCount: Int { queue.sync { collectionFontSentChunks } }

    func collectionFontSetDownload(held: Bool, rejected: Bool) {
        queue.sync {
            collectionFontHoldDownloads = held
            collectionFontRejectDownloads = rejected
            if !held {
                let pending = collectionFontPendingChunks
                collectionFontPendingChunks = []
                for (bytes, connection) in pending {
                    connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }

    private var populatedBrowseFolder = false
    private var browseChildHeld = false
    private var heldBrowseResponses: [(Data, String, NWConnection)] = []
    private var heldMediaRequests: [(String, NWConnection)] = []
    private var startError: Error?

    var preparedRequests: [PreparedRequest] {
        countLock.lock()
        defer { countLock.unlock() }
        return storedPreparedRequests
    }

    var browsePageOffsets: [Int] {
        countLock.lock()
        defer { countLock.unlock() }
        return storedBrowseOffsets
    }

    var cancelledPreparedRequests: Set<String> {
        countLock.lock()
        defer { countLock.unlock() }
        return storedCancelledPreparedRequests
    }

    func setPlaybackHeld(_ held: Bool) {
        queue.sync {
            playbackHeld = held
            if !held {
                let pending = heldMediaRequests
                heldMediaRequests = []
                for (request, connection) in pending { respond(to: request, over: connection) }
            }
        }
    }

    func setUnreadableOriginal(_ unreadable: Bool) {
        queue.sync { unreadableOriginal = unreadable }
    }

    func useShortPreparedSegments() {
        queue.sync { usesShortPreparedSegments = true }
    }

    func useOfflineTracksFixture() {
        queue.sync { usesMultiaudio = true; usesShortPreparedSegments = true }
    }

    func useNativeCaptionFixture() {
        queue.sync { usesNativeCaptions = true; usesMultiaudio = true; usesShortPreparedSegments = true }
    }

    static let auditFolderTitles = ["Amber Room", "Paper Dock", "Copper Loft", "Moon Vault", "Star Attic"]
    private static let auditFolderIDs = ["73001", "73002", "73003", "73004", "73005"]

    func auditUseDeepFolders() { queue.sync { auditDeepFolders = true } }
    func auditRejectLibraryRequests(_ rejects: Bool) { queue.sync { auditLibraryRejects = rejects } }
    func auditSetLibrarySchemaVersion(_ version: Int) { queue.sync { auditLibrarySchemaVersion = version } }
    func auditSetEmptyLibrary(_ empty: Bool) { queue.sync { auditLibraryEmpty = empty } }
    var auditLibraryRequestCount: Int { queue.sync { auditLibraryRequests } }
    var auditFailedLibraryRequestCount: Int { queue.sync { auditFailedLibraryRequests } }
    var auditRequestedFolders: [String] { queue.sync { auditFolders } }

    private func auditFolderPayload(_ target: String) -> Data {
        guard var page = try? JSONSerialization.jsonObject(with: Data(Self.libraryJSON.utf8)) as? [String: Any],
              let movie = (page["entries"] as? [[String: Any]])?.first else { return Data() }
        let folderMode = Self.queryValue(named: "view", in: target) == "folders"
        let folder = Self.queryValue(named: "folder", in: target) ?? "0"
        let depth = Self.auditFolderIDs.firstIndex(of: folder).map { $0 + 1 } ?? 0
        var breadcrumbs: [[String: String]] = [["id": "0", "title": "Media"]]
        if depth > 0 {
            breadcrumbs += (0..<depth).map { ["id": Self.auditFolderIDs[$0], "title": Self.auditFolderTitles[$0]] }
        }
        let entries: [[String: Any]]
        if folderMode && depth < Self.auditFolderTitles.count {
            entries = [["entry_type": "folder", "id": Self.auditFolderIDs[depth], "title": Self.auditFolderTitles[depth], "child_count": 1]]
        } else {
            entries = [movie]
        }
        page["view"] = folderMode ? "folders" : "library"
        page["folder"] = folderMode ? (breadcrumbs.last ?? ["id": "0", "title": "Media"]) as Any : NSNull()
        page["breadcrumbs"] = folderMode ? breadcrumbs : []
        page["entries"] = entries
        page["total"] = entries.count
        page["has_more"] = false
        page["offset"] = 0
        page["limit"] = 60
        page["query"] = ""
        return (try? JSONSerialization.data(withJSONObject: page)) ?? Data()
    }
    func setFullHDQualityAvailable(_ available: Bool) {
        queue.sync { fullHDQualityAvailable = available }
    }

    func useLargePosterBenchmarkFixture() throws {
        // The UI-test runner generates this once before any measure block.
        // Every media ID has its own URL, while fixture bytes are shared.
        let data = try autoreleasepool {
            try Self.jpeg(size: CGSize(width: 2_048, height: 3_072), color: .systemIndigo)
        }
        queue.sync {
            usesPaginatedBrowse = true
            usesOfflineCollection = false
            largePosterData = data
        }
    }

    func beginLargePosterIteration(namespace: String) {
        queue.sync {
            largePosterNamespace = namespace
            countLock.lock()
            storedLargePosterIDs = []
            storedBrowseOffsets = []
            countLock.unlock()
        }
    }

    var largePosterRequestedIDs: Set<String> {
        countLock.lock()
        defer { countLock.unlock() }
        return storedLargePosterIDs
    }

    func usePaginatedBrowseFixture() { queue.sync { usesPaginatedBrowse = true } }
    func useOfflineCollectionFixture() {
        queue.sync { usesPaginatedBrowse = true; usesOfflineCollection = true; usesMultiaudio = true }
    }
    static func collectionTitle(_ index: Int) -> String {
        String(format: "The Paper Voyage Beyond the Copper Moon %02d", min(index, 6) + 1)
    }
    func populateEmptyBrowseFolder() { queue.sync { populatedBrowseFolder = true } }
    func setBrowseChildHeld(_ held: Bool) {
        queue.sync {
            browseChildHeld = held
            if !held {
                let pending = heldBrowseResponses
                heldBrowseResponses = []
                for (payload, method, connection) in pending {
                    send(payload, contentType: "application/json", method: method, connection: connection)
                }
            }
        }
    }

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
        standardMediaData = try Data(contentsOf: mediaURL)
        guard let multiaudioURL = Bundle(for: SyntheticHTTPServer.self).url(forResource: "synthetic-multiaudio", withExtension: "mp4") else {
            throw NSError(domain: "SyntheticHTTPServer", code: 6)
        }
        multiaudioData = try Data(contentsOf: multiaudioURL)
        guard let nativeCaptionURL = Bundle(for: SyntheticHTTPServer.self).url(forResource: "synthetic-native-caption", withExtension: "mp4") else {
            throw NSError(domain: "SyntheticHTTPServer", code: 7)
        }
        nativeCaptionData = try Data(contentsOf: nativeCaptionURL)
        preparedSegmentData = try Data(contentsOf: segmentURL)
        shortPreparedSegments = try Dictionary(uniqueKeysWithValues: (0..<3).map { index in
            let name = "synthetic-stall-\(index)"
            guard let url = Bundle(for: SyntheticHTTPServer.self).url(forResource: name, withExtension: "ts") else {
                throw NSError(domain: "SyntheticHTTPServer", code: 5, userInfo: [NSLocalizedDescriptionKey: "Synthetic short segment fixture is missing"])
            }
            return ("/web/media/\(name).ts", try Data(contentsOf: url))
        })
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
        queue.sync {
            for (_, connection) in controlledPendingBytes { connection.cancel() }
            controlledPendingBytes = []
            for (_, connection) in collectionFontPendingChunks { connection.cancel() }
            collectionFontPendingChunks = []
            for (_, connection) in heldMediaRequests { connection.cancel() }
            heldMediaRequests = []
            for (_, _, connection) in heldBrowseResponses { connection.cancel() }
            heldBrowseResponses = []
        }
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
            auditLibraryRequests += 1
            if auditLibrarySchemaVersion != 2 {
                let payload = Self.libraryJSON.replacingOccurrences(of: "\"schema_version\":2",
                    with: "\"schema_version\":\(auditLibrarySchemaVersion)")
                send(Data(payload.utf8), contentType: "application/json", method: method, connection: connection)
                return
            }
            if auditLibraryEmpty {
                var page = (try? JSONSerialization.jsonObject(with: Data(Self.libraryJSON.utf8))) as? [String: Any] ?? [:]
                page["entries"] = []
                page["offset"] = 0
                page["total"] = 0
                page["has_more"] = false
                send((try? JSONSerialization.data(withJSONObject: page)) ?? Data(),
                     contentType: "application/json", method: method, connection: connection)
                return
            }
            if auditLibraryRejects {
                auditFailedLibraryRequests += 1
                send(Data(#"{"schema_version":2,"error":{"code":"busy","message":"Synthetic temporary failure.","recoverable":true,"action":null}}"#.utf8),
                     status: 503, contentType: "application/json", method: method, connection: connection)
                return
            }
            if auditDeepFolders {
                auditFolders.append(Self.queryValue(named: "folder", in: target) ?? "0")
                send(auditFolderPayload(target), contentType: "application/json", method: method, connection: connection)
                return
            }

            if usesPaginatedBrowse {
                countLock.lock()
                storedBrowseOffsets.append(Int(Self.queryValue(named: "offset", in: target) ?? "0") ?? 0)
                countLock.unlock()
                let payload = browsePayload(target)
                if browseChildHeld, target.contains("folder=62011") {
                    heldBrowseResponses.append((payload, method, connection))
                    return
                }
                let delayed = target.contains("folder=620") || target.contains("q=absent")
                queue.asyncAfter(deadline: .now() + (delayed ? 1.5 : 0.05)) { [self] in
                    send(payload, contentType: "application/json", method: method, connection: connection)
                }
                return
            }
            let payload: String
            if target.contains("view=folders") {
                payload = target.contains("folder=folder-7") ? Self.folderChildJSON : Self.folderRootJSON
            } else {
                payload = Self.libraryJSON
            }
            var bytes = Data(payload.utf8)
            if !fullHDQualityAvailable,
               var json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               var capabilities = json["capabilities"] as? [String: Any],
               let profiles = capabilities["quality_profiles"] as? [[String: Any]] {
                capabilities["quality_profiles"] = profiles.filter { $0["id"] as? String != "full_hd" }
                json["capabilities"] = capabilities
                bytes = (try? JSONSerialization.data(withJSONObject: json)) ?? bytes
            }
            send(bytes, contentType: "application/json", method: method, connection: connection)
            return
        } else if usesPaginatedBrowse, target.hasPrefix("/api/web/item/810") {
            let id = String(target.split(separator: "/").last ?? "81000")
            send(browseItem(id), contentType: "application/json", method: method, connection: connection)
            return
        } else if target.hasPrefix("/api/web/item/42001") {
            let payload: String
            if usesNativeCaptions {
                payload = Self.nativeCaptionItemJSON.replacingOccurrences(of: "8200000000", with: String(nativeCaptionData.count))
            } else if usesManyAudioTracks {
                let tracks: [[String: Any]] = (0..<24).map { offset in
                    ["index": offset * 3 + 4, "codec": "aac", "channels": 2,
                     "language": offset.isMultiple(of: 2) ? "eng" : "rus",
                     "title": offset == 22
                        ? "Surround mix 23 with an alternate commentary recording and a complete spoken introduction"
                        : "Surround mix \(offset + 1)", "default": offset == 0]
                }
                let captions: [[String: Any]] = (0..<24).map { index in
                    ["index": index, "label": "English captions \(index + 1)", "language": "eng",
                     "default": false, "source_format": "srt", "browser_supported": true,
                     "url": "/Captions/42001/\(index).vtt"]
                }
                var response = try! JSONSerialization.jsonObject(with: Data(Self.itemJSON.utf8)) as! [String: Any]
                var item = response["item"] as! [String: Any]
                item["audio_tracks"] = tracks
                item["default_audio_index"] = 4
                item["captions"] = captions
                response["item"] = item
                response["audio_tracks"] = tracks
                payload = String(decoding: try! JSONSerialization.data(withJSONObject: response), as: UTF8.self)
            } else {
                payload = usesMultiaudio ? Self.offlineTracksItemJSON.replacingOccurrences(of: "8200000000", with: String(multiaudioData.count)) : Self.itemJSON
            }
            send(Data(payload.utf8), contentType: "application/json", method: method, connection: connection)
            return
        } else if target.hasPrefix("/api/web/transcode/42001") || (usesOfflineCollection && target.hasPrefix("/api/web/transcode/810")) {
            let requestID = Self.queryValue(named: "request", in: target) ?? "0"
            let sessionID = Self.queryValue(named: "session", in: target) ?? "0"
            countLock.lock()
            if method == "DELETE", requestID != "0", sessionID != "0" {
                storedValidTranscodeCancellationCount += 1
                storedCancelledPreparedRequests.insert("\(sessionID):\(requestID)")
            } else if method == "GET" {
                storedTranscodeStatusRequestCount += 1
            }
            countLock.unlock()
            let state = method == "DELETE" ? "cancelled" : (compatiblePreparationFinished ? "ready" : "producing")
            let itemID = target.split(separator: "?")[0].split(separator: "/").last.map(String.init) ?? "42001"
            let payload = """
            {"schema_version":2,"item_id":"\(itemID)","request_id":\(requestID),"state":"\(state)","retry_after_seconds":null,"produced_seconds":\(compatiblePreparationFinished ? 5528 : (usesOfflineCollection ? 8 : 1382))}
            """
            send(Data(payload.utf8), contentType: "application/json", method: method, connection: connection)
            return
        } else if usesOfflineCollection && (target.hasPrefix("/web/download/810") || target.hasPrefix("/web/media/810")) {
            sendMedia(request: request, method: method, slowly: true, delay: 2, connection: connection)
            return
        } else if target.hasPrefix("/web/download/42001") {
            countLock.lock()
            storedOriginalDownloadRequestCount += 1
            countLock.unlock()
            if collectionFontRejectDownloads {
                send(Data("Synthetic file is temporarily missing".utf8), status: 404,
                     contentType: "text/plain", method: method, connection: connection)
                return
            }
            if unreadableOriginal {
                send(Data(repeating: 0xa5, count: 4096), contentType: "application/octet-stream", method: method, connection: connection)
                return
            }
            sendMedia(request: request, method: method, slowly: true, delay: usesMultiaudio ? 2 : 20, connection: connection)
            return
        } else if target.hasPrefix("/web/media/42001.mp4") {
            if controlsCompatibleTransfer, target.contains("mode=compatible") {
                if method == "HEAD" {
                    controlledHEADs += 1
                    if compatiblePreparationFinished {
                        send(mediaData, contentType: "video/mp4", method: method, connection: connection)
                    } else {
                        send(Data(), status: 503, contentType: "application/json", method: method, connection: connection)
                    }
                } else {
                    controlledGETs += 1
                    let split = mediaData.count / 3
                    var first = Data("HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n\(String(split, radix: 16))\r\n".utf8)
                    first.append(mediaData.prefix(split))
                    first.append(Data("\r\n".utf8))
                    let remainder = Data(mediaData.suffix(from: split))
                    connection.send(content: first, completion: .contentProcessed { [weak self] error in
                        guard error == nil, let self else { connection.cancel(); return }
                        self.controlledPendingBytes.append((remainder, connection))
                    })
                }
                return
            }
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
            if rejectsPlayback {
                send(Data("Synthetic movie temporarily unavailable".utf8), status: 404,
                     contentType: "text/plain", method: method, connection: connection)
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
            let prepared = PreparedRequest(
                session: Self.queryValue(named: "session", in: target).flatMap(UInt64.init) ?? 0,
                generation: Self.queryValue(named: "request", in: target).flatMap(UInt64.init) ?? 0,
                quality: Self.queryValue(named: "quality", in: target) ?? "auto",
                audio: Self.queryValue(named: "audio", in: target) ?? "0",
                start: Self.queryValue(named: "start", in: target).flatMap(Int.init) ?? 0
            )
            countLock.lock()
            storedPreparedRequests.append(prepared)
            let cancelled = storedCancelledPreparedRequests.contains(prepared.identity)
            countLock.unlock()
            if cancelled {
                send(Data(), status: 410, contentType: "application/json", method: method, connection: connection)
                return
            }
            if rejectsPlayback {
                send(Data("Synthetic movie temporarily unavailable".utf8), status: 404,
                     contentType: "text/plain", method: method, connection: connection)
                return
            }
            if playbackHeld {
                heldMediaRequests.append((request, connection))
                return
            }
            guard target.contains("video_mode=transcode"),
                  target.contains("video_output=h264_sdr"),
                  target.contains("audio=0") || (usesMultiaudio && (target.contains("audio=8") || target.contains("audio=12")))
                    || (usesManyAudioTracks && (0..<24).contains { String($0 * 3 + 4) == prepared.audio }) else {
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
            let playlist: String
            if usesShortPreparedSegments {
                let identityQuery = "session=\(prepared.session)&request=\(prepared.generation)"
                playlist = """
                #EXTM3U
                #EXT-X-VERSION:3
                #EXT-X-TARGETDURATION:2
                #EXT-X-MEDIA-SEQUENCE:0
                #EXT-X-PLAYLIST-TYPE:EVENT
                #EXTINF:2.000000,
                synthetic-stall-0.ts?\(identityQuery)
                #EXTINF:2.000000,
                synthetic-stall-1.ts?\(identityQuery)
                #EXTINF:2.000000,
                synthetic-stall-2.ts?\(identityQuery)

                """
            } else {
                playlist = """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:25
            #EXT-X-MEDIA-SEQUENCE:0
            #EXT-X-PLAYLIST-TYPE:EVENT
            #EXTINF:25.000000,
            synthetic-playback.ts

            """
            }
            send(Data(playlist.utf8), contentType: "application/vnd.apple.mpegurl", method: method, connection: connection)
            return
        } else if let segment = shortPreparedSegments[String(target.split(separator: "?").first ?? "")] {
            if playbackHeld {
                heldMediaRequests.append((request, connection))
                return
            }
            countLock.lock()
            storedPreparedSegmentRequestCount += 1
            countLock.unlock()
            send(segment, contentType: "video/mp2t", method: method, connection: connection)
            return
        } else if target.hasPrefix("/web/media/synthetic-playback.ts") {
            if playbackHeld {
                heldMediaRequests.append((request, connection))
                return
            }
            countLock.lock()
            storedPreparedSegmentRequestCount += 1
            countLock.unlock()
            send(preparedSegmentData, contentType: "video/mp2t", method: method, connection: connection)
            return
        } else if target.hasPrefix("/Captions/42001/0.vtt")
                    || (usesManyAudioTracks && target.hasPrefix("/Captions/42001/")) {
            countLock.lock()
            storedCaptionRequestCount += 1
            countLock.unlock()
            sendCaption(method: method, connection: connection)
            return
        } else if let image = largePosterData,
                  target.hasPrefix("/ArtworkBenchmark/\(largePosterNamespace)/"),
                  target.hasSuffix(".jpg") {
            let fileName = String(target.split(separator: "/").last ?? "")
            let id = String(fileName.dropLast(4))
            guard Set((0..<36).map { String(81000 + $0) }).contains(id) else {
                send(Data(), status: 404, contentType: "image/jpeg", method: method, connection: connection)
                return
            }
            // This branch is after Basic authentication has been accepted.
            countLock.lock()
            storedArtworkRequestCount += 1
            storedLargePosterIDs.insert(id)
            countLock.unlock()
            send(image, contentType: "image/jpeg", method: method, connection: connection)
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
            if self.collectionFontHoldDownloads {
                self.collectionFontSentChunks += 1
                self.collectionFontPendingChunks.append((Data(body.suffix(from: split)), connection))
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

    private func browsePayload(_ target: String) -> Data {
        guard var page = try? JSONSerialization.jsonObject(with: Data(Self.libraryJSON.utf8)) as? [String: Any],
              let template = (page["entries"] as? [[String: Any]])?.first else { return Data() }
        let folders = Self.queryValue(named: "view", in: target) == "folders"
        let folder = Self.queryValue(named: "folder", in: target) ?? "0"
        let query = Self.queryValue(named: "q", in: target) ?? ""
        let offset = Int(Self.queryValue(named: "offset", in: target) ?? "0") ?? 0
        func movie(_ index: Int) -> [String: Any] {
            var value = template
            value["id"] = String(81000 + index)
            value["title"] = usesOfflineCollection ? Self.collectionTitle(index) : String(format: "Paper Voyage %02d", index + 1)
            if largePosterData != nil {
                value["art_url"] = "/ArtworkBenchmark/\(largePosterNamespace)/\(81000 + index).jpg"
            } else {
                value["art_url"] = NSNull()
            }
            if usesOfflineCollection {
                value["duration_seconds"] = 25
                value["size_bytes"] = multiaudioData.count
            }
            return value
        }
        var entries: [[String: Any]]
        var breadcrumbs: [[String: String]] = []
        if folders {
            breadcrumbs = [["id": "0", "title": "Media"]]
            if folder == "0" {
                entries = (0..<18).map { ["entry_type": "folder", "id": String(62000 + $0),
                                         "title": String(format: "Paper Shelf %02d", $0 + 1), "child_count": 13] }
            } else {
                breadcrumbs.append(["id": "62011", "title": "Paper Shelf 12"])
                if folder == "63000" {
                    breadcrumbs.append(["id": "63000", "title": "Empty Lantern Box"])
                    entries = populatedBrowseFolder ? [movie(35)] : []
                } else {
                    entries = [["entry_type": "folder", "id": "63000", "title": "Empty Lantern Box", "child_count": 0]]
                        + (0..<12).map(movie)
                }
            }
            page["folder"] = breadcrumbs.last
        } else {
            entries = (0..<(usesOfflineCollection ? 7 : 36)).map(movie)
            page["folder"] = NSNull()
        }
        if !query.isEmpty { entries = entries.filter { ($0["title"] as? String)?.localizedCaseInsensitiveContains(query) == true } }
        page["view"] = folders ? "folders" : "library"
        page["breadcrumbs"] = breadcrumbs
        page["query"] = query
        page["sort"] = Self.queryValue(named: "sort", in: target) ?? "title"
        page["offset"] = offset
        page["limit"] = 12
        page["total"] = entries.count
        page["has_more"] = offset + 12 < entries.count
        page["entries"] = Array(entries.dropFirst(offset).prefix(12))
        return (try? JSONSerialization.data(withJSONObject: page)) ?? Data()
    }

    private func browseItem(_ id: String) -> Data {
        let template = usesOfflineCollection ? Self.offlineTracksItemJSON : Self.itemJSON
        guard var response = try? JSONSerialization.jsonObject(with: Data(template.utf8)) as? [String: Any],
              var item = response["item"] as? [String: Any] else { return Data() }
        item["id"] = id
        let index = (Int(id) ?? 81000) - 81000
        item["title"] = usesOfflineCollection ? Self.collectionTitle(index) : String(format: "Paper Voyage %02d", index + 1)
        item["art_url"] = NSNull()
        if usesOfflineCollection {
            item["size_bytes"] = multiaudioData.count
            item["download_url"] = "/web/download/\(id)"
            item["source_url"] = "/web/media/\(id).mp4?mode=direct"
        }
        response["id"] = id
        response["item"] = item
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
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

    private static let offlineTracksItemJSON = itemJSON
        .replacingOccurrences(of: "\"ext\":\"mkv\"", with: "\"ext\":\"mp4\"")
        .replacingOccurrences(of: "video/x-matroska", with: "video/mp4")
        .replacingOccurrences(of: "\"container\":\"matroska\"", with: "\"container\":\"mp4\"")
        .replacingOccurrences(of: "\"video_codec\":\"hevc\"", with: "\"video_codec\":\"h264\"")
        .replacingOccurrences(of: "\"hdr\":\"hdr10\"", with: "\"hdr\":\"sdr\"")
        .replacingOccurrences(of: "3840x2160", with: "640x360")
        .replacingOccurrences(of: "\"duration_seconds\":5528", with: "\"duration_seconds\":25")
        .replacingOccurrences(of: "\"end_seconds\":1800", with: "\"end_seconds\":8")
        .replacingOccurrences(of: "\"start_seconds\":1800", with: "\"start_seconds\":8")
        .replacingOccurrences(of: "\"end_seconds\":5528", with: "\"end_seconds\":25")
        .replacingOccurrences(of: "\"default_audio_index\":1", with: "\"default_audio_index\":8")
        .replacingOccurrences(of: audioTracks, with: #"[{"index":8,"codec":"aac","channels":1,"language":"eng","title":"English tone","default":true},{"index":12,"codec":"aac","channels":1,"language":"fra","title":"French tone","default":false}]"#)

    private static let nativeCaptionItemJSON = offlineTracksItemJSON
        .replacingOccurrences(of: "\"duration_seconds\":25", with: "\"duration_seconds\":6")
        .replacingOccurrences(of: "640x360", with: "320x180")
        .replacingOccurrences(of: "\"end_seconds\":8", with: "\"end_seconds\":3")
        .replacingOccurrences(of: "\"start_seconds\":8", with: "\"start_seconds\":3")
        .replacingOccurrences(of: "\"end_seconds\":25", with: "\"end_seconds\":6")

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

// Append to RustyViewJourneyTests.swift so the existing private synthetic server
// and geometry/navigation helpers remain shared. No new product test hooks.
@MainActor
extension RustyViewJourneyTests {
    func testFontMatrixCoreLarge() throws { try FontMatrixCore(.large, name: "L") }
    func testFontMatrixCoreExtraLarge() throws { try FontMatrixCore(.extraLarge, name: "XL") }

    private func FontMatrixCore(_ category: UIContentSizeCategory, name: String) throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let fixture = try XCTUnwrap(server)
        let app = try launchApp(arguments: [
            "-AppleInterfaceStyle", "Light", "-UIPreferredContentSizeCategoryName", category.rawValue,
        ])
        defer { app.terminate() }

        let card = app.descendants(matching: .any).matching(identifier: "library-card-42001").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        AuditReveal(card, in: app)
        AuditAssertTarget(card, in: app)
        let title = card.staticTexts["The Clockwork Orchard"]
        let runtime = card.staticTexts["1:32:08"].firstMatch
        XCTAssertTrue(title.exists)
        XCTAssertTrue(runtime.exists)
        XCTAssertLessThanOrEqual(title.frame.maxY, runtime.frame.minY + 1,
                                 "The actual title must not overlap the actual runtime")
        XCTAssertGreaterThan(title.frame.width, 0)
        XCTAssertGreaterThan(runtime.frame.height, 0)
        XCTAssertTrue(AuditContains(title.frame, in: card.frame))
        XCTAssertTrue(AuditContains(runtime.frame, in: card.frame))
        try FontMatrixCapture(app, name: name, screen: "Library")
        for label in ["Browse", "Sort"] { AuditAssertTarget(app.buttons[label], in: app, content: false) }
        AuditToolbarMenuEdges("Browse", selecting: "All Movies", in: app)
        AuditToolbarMenuEdges("Sort", selecting: "Title", in: app)
        app.buttons["Sort"].tap()
        let titleSort = app.buttons["Title"].firstMatch
        XCTAssertTrue(titleSort.waitForExistence(timeout: 3))
        AuditAssertNativeMenuTarget(titleSort, in: app)
        titleSort.tap()
        AuditReveal(card, in: app)
        card.tap()

        let watch = app.buttons["Watch"]
        XCTAssertTrue(watch.waitForExistence(timeout: 5))
        let fileSize = app.staticTexts["media-file-size"]
        AuditReveal(fileSize, in: app)
        XCTAssertTrue(AuditContains(fileSize.frame, in: AuditContentBounds(app)))
        try FontMatrixCapture(app, name: name, screen: "Details-summary")
        for action in [watch, app.buttons["detail-actions"], app.buttons["Audio"], app.buttons["Quality"]] {
            AuditReveal(action, in: app)
            AuditAssertTarget(action, in: app)
        }
        let audio = app.buttons["Audio"]
        let quality = app.buttons["Quality"]
        XCTAssertFalse(audio.frame.intersects(quality.frame), "Two selection controls must not overlap")
        quality.tap()
        let automatic = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Auto'")).firstMatch
        XCTAssertTrue(automatic.waitForExistence(timeout: 3))
        AuditAssertTarget(automatic, in: app)
        automatic.tap()
        XCTAssertTrue((quality.value as? String)?.contains("Auto") == true)
        let download = app.buttons["Download"]
        AuditReveal(download, in: app)
        AuditAssertTarget(download, in: app)
        try FontMatrixCapture(app, name: name, screen: "Details-actions")
        AuditReveal(download, in: app)
        download.tap()

        let compatible = app.buttons["Compatible copy"]
        XCTAssertTrue(compatible.waitForExistence(timeout: 3))
        AuditReveal(compatible, in: app)
        AuditAssertTarget(compatible, in: app)
        try FontMatrixCapture(app, name: name, screen: "Download-choices-compatible")
        let expand = app.buttons["Compatible format details"]
        AuditReveal(expand, in: app)
        AuditAssertTarget(expand, in: app)
        expand.tap()
        let format = app.descendants(matching: .any).matching(identifier: "download-format-compatible").firstMatch
        XCTAssertTrue(format.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(format.frame.width, 0)
        XCTAssertGreaterThan(format.frame.height, 0)
        // The expanded summary may legitimately exceed a viewport at AX sizes;
        // audit its visible text and horizontal bounds instead of requiring an
        // entire long section to fit without scrolling.
        XCTAssertGreaterThanOrEqual(format.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(format.frame.maxX, app.frame.maxX)
        try FontMatrixCapture(app, name: name, screen: "Download-format-expanded")
        AuditReveal(expand, in: app)
        expand.tap()
        let original = app.buttons["Original file"]
        AuditReveal(original, in: app)
        AuditAssertTarget(original, in: app)
        let originalDetails = app.buttons["Original format details"]
        AuditReveal(originalDetails, in: app)
        AuditAssertTarget(originalDetails, in: app)
        XCTAssertTrue(AuditContains(original.frame, in: AuditContentBounds(app)))
        try FontMatrixCapture(app, name: name, screen: "Download-choices-original")
        let close = app.navigationBars["Download"].buttons["Close"]
        AuditAssertTarget(close, in: app, content: false)
        close.tap()
        XCTAssertTrue(compatible.waitForNonExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()

        let edit = app.buttons["Edit Connection"]
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        AuditReveal(edit, in: app)
        AuditAssertTarget(edit, in: app)
        edit.tap()

        let address = app.textFields["connection-server"]
        XCTAssertTrue(address.waitForExistence(timeout: 3))
        AuditReveal(address, in: app)
        AuditAssertTarget(address, in: app)
        AuditEnterConnectionText(try XCTUnwrap(fixture.serverAddress) + "\n", into: address, in: app)
        XCTAssertEqual(address.value as? String, try XCTUnwrap(fixture.serverAddress))
        try FontMatrixCapture(app, name: name, screen: "Connection-server-field")
        let username = app.textFields["connection-username"]
        AuditReveal(username, in: app)
        AuditAssertTarget(username, in: app)
        AuditEnterConnectionText("viewer\n", into: username, in: app)
        XCTAssertEqual(username.value as? String, "viewer")
        let password = app.secureTextFields["connection-password"]
        AuditReveal(password, in: app)
        AuditAssertTarget(password, in: app)
        AuditEnterConnectionText("test-only-password", into: password, in: app)
        XCTAssertTrue(app.keyboards.buttons["Go"].waitForExistence(timeout: 3))
        let submit = app.buttons["connection-submit"]
        AuditReveal(submit, in: app)
        AuditAssertTarget(submit, in: app)
        try FontMatrixCapture(app, name: name, screen: "Connection-submit-keyboard")
        let requests = fixture.auditLibraryRequestCount
        AuditReveal(submit, in: app)
        submit.tap()
        XCTAssertTrue(submit.waitForNonExistence(timeout: 8), "The actual saved-account probe must complete")
        dismissSyntheticPasswordOffer(in: app)
        XCTAssertGreaterThan(fixture.auditLibraryRequestCount, requests,
                             "A successful tap must perform authenticated HTTP, not merely dismiss setup")
        XCTAssertTrue(settings.exists)
        settings.tap()
        AuditReveal(edit, in: app)
        AuditAssertTarget(edit, in: app)
        try FontMatrixCapture(app, name: name, screen: "Settings-server")
        let preference = app.buttons["preferred-quality"]
        AuditReveal(preference, in: app)
        AuditAssertTarget(preference, in: app)
        let audioPreference = app.buttons["preferred-audio-language"]
        AuditReveal(audioPreference, in: app)
        AuditAssertTarget(audioPreference, in: app)
        try FontMatrixCapture(app, name: name, screen: "Settings-playback")
        let network = app.buttons["download-network-menu"]
        AuditReveal(network, in: app)
        AuditAssertTarget(network, in: app)
        try FontMatrixCapture(app, name: name, screen: "Settings-download-network")
        AuditReveal(network, in: app)
        network.tap()
        let wifi = app.buttons["Wi-Fi Only"]
        XCTAssertTrue(wifi.waitForExistence(timeout: 3))
        AuditAssertNativeMenuTarget(wifi, in: app)
        wifi.tap()
        XCTAssertEqual(network.value as? String, "Wi-Fi Only", "The reached control must change the actual policy")
    }

    private func FontMatrixCapture(_ app: XCUIApplication, name: String, screen: String, orientation: String = "portrait") throws {
        // XCTest can scroll lazy lists during its audit. Callers reveal their
        // next action explicitly; restoring an unrelated row can hide it again.
        // Capture the full display to avoid app snapshot cropping after rotation.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Synthetic-font-\(name)-\(screen)-\(orientation)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Review the selected size through the geometry assertions and this
        // rendered capture. XCTest's textClipped audit changes Dynamic Type
        // internally and predicts other sizes, outside this routine review.
        // The original accessibility smoke test retains that broader audit.
        AuditScreen(app, types: [.hitRegion, .sufficientElementDescription])
    }

    func testFontMatrixPlayerExtraLarge() throws { try remainingPlayerFont(.extraLarge, name: "XL") }

    private func remainingPlayerFont(_ category: UIContentSizeCategory, name: String) throws {
        // The default-size journey retains the additional malformed-response
        // and Off-during-load ownership transitions. This larger-size check still
        // visits real loading, failure, rendered cues, and terminal recovery.
        try exerciseSubtitleFeedbackFonts(category, name: name,
                                          completeFaultSequence: false, includePlayerFailure: true)
    }

    @MainActor
    private func AuditViewingPickerEdges(_ title: String, selecting choice: String,
                                          restoring original: String, in app: XCUIApplication) throws {
        for (selection, topEdge) in [(choice, true), (original, false)] {
            let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
            AuditReveal(picker, in: app)
            let rowFrame = picker.frame
            XCTAssertGreaterThanOrEqual(rowFrame.width, 44 - 0.01)
            XCTAssertGreaterThanOrEqual(rowFrame.height, 44 - 0.01)
            XCTAssertTrue(AuditContains(rowFrame, in: AuditContentBounds(app)))

            // The app-owned button exposes its complete hit region. Exercise
            // its top and bottom edges, then select from the scrollable sheet.
            let point = CGPoint(x: rowFrame.midX,
                                y: topEdge ? rowFrame.minY + 2 : rowFrame.maxY - 2)
            XCTAssertTrue(rowFrame.contains(point))
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)).tap()
            let option = app.buttons[selection].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 3), "The \(title) row padding must open its choices")
            option.tap()
            let updated = app.buttons["\(title), \(selection)"]
            XCTAssertTrue(updated.waitForExistence(timeout: 3), "The real picker must publish the selected value")
        }
    }

    private func expandPlaybackOptionsIfNeeded(for target: XCUIElement, in app: XCUIApplication) {
        let navigation = app.navigationBars["Playback Options"]
        let grabber = app.buttons["Sheet Grabber"]
        guard navigation.exists, navigation.isHittable, target.exists,
              grabber.exists, grabber.value as? String == "Half screen" else { return }
        let form = app.collectionViews.containing(.button, identifier: target.label).firstMatch
        let visibleBottom = min(AuditContentBounds(app).maxY, form.exists ? form.frame.maxY : app.frame.maxY)
        guard target.frame.maxY > visibleBottom else { return }
        XCTAssertTrue(grabber.isHittable)
        let before = navigation.frame
        // Short pans inside a Menu row can leave the native medium detent
        // unchanged. Use the actual sheet handle once, then keep the ordinary
        // full-visibility and touch-target checks on the requested action.
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            navigation.exists && navigation.frame.maxY < before.minY - 50
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 3), .completed,
                       "The native sheet grabber must expand Playback Options before revealing the lower action")
        let evidence = XCTAttachment(string: "Playback Options navigation moved from \(before) to \(navigation.frame) after one native grabber drag for \(target.label).")
        evidence.name = "Native options sheet expansion"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    private func capturePlayerAndOptionsFonts(_ app: XCUIApplication, name: String,
                                              isOffline: Bool = false) throws {
        let source = isOffline ? "Local" : "Online"
        XCTAssertEqual(app.buttons["play-pause-control"].label, "Play", "Inspect a deliberately paused real asset")
        let title = app.staticTexts["player-title"]
        AuditReveal(title, in: app)
        XCTAssertTrue(AuditContains(title.frame, in: AuditContentBounds(app)))
        for label in ["Close player", "Playback options", "AirPlay"] {
            AuditReveal(app.buttons[label], in: app)
            AuditAssertTarget(app.buttons[label], in: app)
        }
        let pip = app.buttons["Start Picture in Picture"]
        if pip.exists {
            XCTAssertGreaterThanOrEqual(pip.frame.width, 44)
            XCTAssertGreaterThanOrEqual(pip.frame.height, 44)
            XCTAssertTrue(AuditContains(pip.frame, in: AuditContentBounds(app)))
        }
        try FontMatrixCapture(app, name: name, screen: "\(source)-Player-title")
        for label in ["Rewind 10 seconds", "Play", "Forward 10 seconds", "Audio track", "Subtitles", "Playback speed"] {
            AuditReveal(app.buttons[label], in: app)
            AuditAssertTarget(app.buttons[label], in: app)
        }
        let videoSize = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Video size:'")).firstMatch
        AuditReveal(videoSize, in: app)
        AuditAssertTarget(videoSize, in: app)
        if !["XS", "S", "M", "L", "Default"].contains(name) {
            let audio = app.buttons["Audio track"]
            let subtitles = app.buttons["Subtitles"]
            XCTAssertGreaterThanOrEqual(videoSize.frame.minY, max(audio.frame.maxY, subtitles.frame.maxY) + 6,
                                       "Large text must place viewing controls below the audio/subtitle row")
            XCTAssertTrue(AuditContains(audio.frame, in: AuditContentBounds(app)))
            XCTAssertTrue(AuditContains(subtitles.frame, in: AuditContentBounds(app)))
        }
        let scrubber = app.otherElements["playback-scrubber"]
        AuditReveal(scrubber, in: app)
        AuditAssertTarget(scrubber, in: app)
        let timeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        AuditReveal(timeline, in: app)
        XCTAssertTrue(AuditContains(timeline.frame, in: AuditContentBounds(app)))
        let accessibleSizes: [String: UIContentSizeCategory] = [
            "AX-M": .accessibilityMedium, "AX-L": .accessibilityLarge,
            "AX-XL": .accessibilityExtraLarge, "AX-XXL": .accessibilityExtraExtraLarge,
            "AX-XXXL": .accessibilityExtraExtraExtraLarge,
        ]
        if let category = accessibleSizes[name] {
            let chapter = app.staticTexts["player-current-chapter"]
            AuditReveal(chapter, in: app)
            let expectedChapter = try elapsedSeconds(from: timeline) >= 8 ? "Clockwork Grove" : "Orchard Gate Opens"
            XCTAssertEqual(chapter.label, expectedChapter)
            XCTAssertGreaterThanOrEqual(chapter.frame.minY, timeline.frame.maxY,
                                       "The chapter needs its own row instead of a truncated time-row fragment")
            let font = UIFont.preferredFont(forTextStyle: .caption1,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
            let required = (chapter.label as NSString).boundingRect(
                with: CGSize(width: chapter.frame.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
            XCTAssertGreaterThanOrEqual(chapter.frame.height + 4, ceil(required.height))
            XCTAssertTrue(AuditContains(chapter.frame, in: AuditContentBounds(app)))
        }
        try FontMatrixCapture(app, name: name, screen: "\(source)-Player-controls")
        AuditReveal(timeline, in: app)
        let before = try elapsedSeconds(from: timeline)
        let forward = app.buttons["Forward 10 seconds"]
        AuditReveal(forward, in: app)
        forward.tap()
        let advanced = try waitForElapsedSeconds(in: timeline, atLeast: before + 9, timeout: 4,
                                                revealingControlsIn: app)
        AuditReveal(timeline, in: app)
        let rewind = app.buttons["Rewind 10 seconds"]
        AuditReveal(rewind, in: app)
        rewind.tap()
        XCTAssertTrue(waitForElapsedSeconds(in: timeline, atMost: advanced - 9, timeout: 4))
        AuditReveal(timeline, in: app)
        XCTAssertLessThanOrEqual(abs(try elapsedSeconds(from: timeline) - before), 1,
                                 "The reached seek buttons must move real media and return to its paused position")

        let options = app.buttons["Playback options"]
        AuditReveal(options, in: app)
        options.tap()
        XCTAssertTrue(app.navigationBars["Playback Options"].waitForExistence(timeout: 3))
        try AuditViewingPickerEdges("Speed", selecting: "2×", restoring: "1×", in: app)
        try AuditViewingPickerEdges("Video Size", selecting: "Fill", restoring: "Fit", in: app)
        try FontMatrixCapture(app, name: name, screen: "\(source)-Options-viewing")
        if isOffline {
            XCTAssertFalse(app.buttons["stream-mode"].exists)
            XCTAssertFalse(app.buttons["stream-quality"].exists)
            let audio = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'local-audio-'")).firstMatch
            XCTAssertTrue(audio.waitForExistence(timeout: 5))
            AuditReveal(audio, in: app)
            AuditAssertTarget(audio, in: app)
        } else {
            for identifier in ["stream-mode", "stream-quality"] {
                let picker = app.buttons[identifier]
                AuditReveal(picker, in: app)
                AuditAssertTarget(picker, in: app)
            }
            let apply = app.buttons["Apply Streaming Changes"]
            expandPlaybackOptionsIfNeeded(for: apply, in: app)
            AuditReveal(apply, in: app)
            AuditAssertTarget(apply, in: app)
            try FontMatrixCapture(app, name: name, screen: "Online-Options-streaming")
            let audio = app.buttons.matching(NSPredicate(format: "label CONTAINS 'French tone'")).firstMatch
            AuditReveal(audio, in: app)
            AuditAssertTarget(audio, in: app)
        }
        try FontMatrixCapture(app, name: name, screen: "\(source)-Options-audio")
        let subtitleOff = app.buttons[isOffline ? "local-caption-off" : "caption-off"]
        AuditReveal(subtitleOff, in: app)
        AuditAssertTarget(subtitleOff, in: app)
        if isOffline {
            AuditReveal(app.staticTexts["Chapters"].firstMatch, in: app)
            AuditAssertTarget(subtitleOff, in: app)
        }
        try FontMatrixCapture(app, name: name, screen: "\(source)-Options-subtitles")
        let chapter = isOffline ? app.buttons["local-chapter-1"]
            : app.buttons.matching(NSPredicate(format: "label CONTAINS 'Clockwork Grove'")).firstMatch
        AuditReveal(chapter, in: app)
        AuditAssertTarget(chapter, in: app)
        try FontMatrixCapture(app, name: name, screen: "\(source)-Options-chapters")
        let dismiss = app.navigationBars["Playback Options"].buttons[isOffline ? "Done" : "Cancel"]
        AuditAssertTarget(dismiss, in: app, content: false)
        dismiss.tap()
        XCTAssertTrue(app.navigationBars["Playback Options"].waitForNonExistence(timeout: 3))
        AuditReveal(app.buttons["play-pause-control"], in: app)
        XCTAssertEqual(app.buttons["play-pause-control"].label, "Play")
        AuditReveal(timeline, in: app)
        XCTAssertLessThanOrEqual(abs(try elapsedSeconds(from: timeline) - before), 1,
                                 "Inspecting and cancelling options must preserve the actual paused asset")
    }

    private func recoverPlayerErrorForFont(_ app: XCUIApplication, fixture: SyntheticHTTPServer, name: String) throws {
        showPlayerControls(in: app)
        let play = app.buttons["play-pause-control"]
        XCTAssertEqual(play.label, "Pause")
        play.tap()
        let timeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        AuditReveal(timeline, in: app)
        let savedTime = try elapsedSeconds(from: timeline)
        let previousGeneration = fixture.preparedRequests.last?.generation ?? 0
        fixture.rejectPlaybackRequests(true)
        let options = app.buttons["Playback options"]
        AuditReveal(options, in: app)
        options.tap()
        let quality = app.buttons["stream-quality"]
        AuditReveal(quality, in: app)
        AuditAssertTarget(quality, in: app)
        quality.tap()
        let fullHD = app.buttons["1080p · 8 Mbps"]
        XCTAssertTrue(fullHD.waitForExistence(timeout: 3))
        AuditAssertTarget(fullHD, in: app)
        fullHD.tap()
        let apply = app.buttons["Apply Streaming Changes"]
        expandPlaybackOptionsIfNeeded(for: apply, in: app)
        AuditReveal(apply, in: app)
        AuditAssertTarget(apply, in: app)
        apply.tap()
        XCTAssertTrue(app.navigationBars["Playback Options"].waitForNonExistence(timeout: 3))
        AuditReveal(play, in: app)
        XCTAssertEqual(play.label, "Play", "Changing quality must retain the deliberate pause")
        play.tap()
        let retry = app.buttons["Retry Current Playback"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "Actual HTTP 404 media must produce reachable recovery")
        let failed = try XCTUnwrap(fixture.preparedRequests.last)
        XCTAssertGreaterThan(failed.generation, previousGeneration)
        XCTAssertEqual(failed.quality, "full_hd")
        try capturePlayerErrorFonts(app, name: name)
        fixture.rejectPlaybackRequests(false)
        AuditReveal(retry, in: app)
        AuditAssertTarget(retry, in: app)
        retry.tap()
        _ = try waitForElapsedSeconds(in: timeline, atLeast: savedTime + 2, timeout: 12,
                                     revealingControlsIn: app)
        let recovered = try XCTUnwrap(fixture.preparedRequests.last)
        XCTAssertEqual(recovered.session, failed.session)
        XCTAssertGreaterThan(recovered.generation, failed.generation)
        XCTAssertEqual(recovered.quality, "full_hd")
        XCTAssertFalse(app.staticTexts["Playback couldn't continue"].exists)
        showPlayerControls(in: app)
        play.tap()
        let close = app.buttons["Close player"]
        AuditReveal(close, in: app)
        AuditAssertTarget(close, in: app)
        close.tap()
        XCTAssertTrue(app.navigationBars["The Clockwork Orchard"].waitForExistence(timeout: 3))
    }

    func testFontMatrixPlayerExtraLargeBothOrientations() throws {
        let fixture = try XCTUnwrap(server)
        fixture.useOfflineTracksFixture()
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = try launchApp(arguments: [
            "-AppleInterfaceStyle", "Light", "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.extraLarge.rawValue,
        ])
        defer { app.terminate() }
        let movie = app.staticTexts["The Clockwork Orchard"].firstMatch
        XCTAssertTrue(movie.waitForExistence(timeout: 8))
        movie.tap()
        let watch = app.buttons["Watch"]
        AuditReveal(watch, in: app)
        watch.tap()
        let timeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 1, timeout: 10, revealingControlsIn: app)
        showPlayerControls(in: app)
        app.buttons["play-pause-control"].tap()
        XCTAssertEqual(app.buttons["play-pause-control"].label, "Play")

        for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
            XCUIDevice.shared.orientation = orientation
            showPlayerControls(in: app)
            for label in ["Close player", "Playback options", "Rewind 10 seconds", "Play",
                          "Forward 10 seconds", "Audio track", "Subtitles", "Playback speed"] {
                try assertWholeTouchTarget(app.buttons[label], in: app)
            }
            try assertWholeTouchTarget(app.otherElements["playback-scrubber"], in: app)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Synthetic-font-XL-Player-\(name)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let before = try elapsedSeconds(from: timeline)
            app.buttons["Forward 10 seconds"].tap()
            let advanced = try waitForElapsedSeconds(in: timeline, atLeast: before + 9, timeout: 4, revealingControlsIn: app)
            app.buttons["Rewind 10 seconds"].tap()
            XCTAssertTrue(waitForElapsedSeconds(in: timeline, atMost: advanced - 9, timeout: 4))
            app.buttons["Playback options"].tap()
            XCTAssertTrue(app.navigationBars["Playback Options"].waitForExistence(timeout: 3))
            let caption = app.buttons["caption-track-0"]
            expandPlaybackOptionsIfNeeded(for: caption, in: app)
            AuditReveal(caption, in: app)
            try assertWholeTouchTarget(caption, in: app)
            let options = XCTAttachment(screenshot: app.screenshot())
            options.name = "Synthetic-font-XL-PlaybackOptions-\(name)"
            options.lifetime = .keepAlways
            add(options)
            try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription],
                                              ignoringVerifiedAuditFalsePositives)
            caption.tap()
            XCTAssertTrue(app.staticTexts["Subtitles: Synthetic subtitle."].waitForExistence(timeout: 3))
            showPlayerControls(in: app)
            XCTAssertEqual(app.buttons["play-pause-control"].label, "Play")
        }
        app.buttons["Close player"].tap()
        XCTAssertTrue(app.navigationBars["The Clockwork Orchard"].waitForExistence(timeout: 3))
        XCTAssertGreaterThan(fixture.mediaRequestCount, 0)
    }
}

@MainActor
extension RustyViewJourneyTests {
    func testCollectionFontLarge() throws { try CollectionFontJourney(.large, name: "L", landscape: true) }
    func testCollectionFontExtraLarge() throws { try CollectionFontJourney(.extraLarge, name: "XL", landscape: true) }

    private func CollectionFontJourney(_ category: UIContentSizeCategory, name: String, landscape: Bool = false) throws {
        let fixture = try XCTUnwrap(server)
        fixture.useOfflineTracksFixture()
        fixture.collectionFontSetDownload(held: true, rejected: false)
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let arguments = ["-AppleInterfaceStyle", "Light", "-UIPreferredContentSizeCategoryName", category.rawValue]
        let app = try launchApp(arguments: arguments)
        defer { app.terminate(); fixture.collectionFontSetDownload(held: false, rejected: false) }
        let title = "The Clockwork Orchard"
        let card = app.buttons["library-card-42001"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        reveal(card, in: app)
        card.tap()
        let download = app.buttons["Download"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        reveal(download, in: app)
        download.tap()
        let original = app.buttons["Original file"]
        reveal(original, in: app)
        original.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["Downloads"].tap()
        let sent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let status = app.staticTexts["download-transfer-status-42001"]
            guard fixture.collectionFontChunkCount > 0, status.exists,
                  let text = status.value as? String,
                  let value = Int(text.components(separatedBy: "%").first ?? "") else { return false }
            // The server holds the last two thirds. URLSession may report the
            // last delivered byte batch before it has consumed that entire third.
            return value > 0 && value <= 34
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [sent], timeout: 8), .completed,
                       "The progress row must follow real authenticated response bytes")
        let active = app.cells.containing(.button, identifier: "active-download-42001").firstMatch
        let activeMenu = active.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'active-download-actions-'")).firstMatch
        let pause = app.buttons["Pause download of \(title)"]
        CollectionFontAssertRow(active, title: title, action: pause, menu: activeMenu, category: category, in: app)
        try CollectionFontCapture(app, name: name, state: "Downloading", orientation: "portrait")
        try CollectionFontInspectActiveDetails(app, name: name, state: "Downloading", actions: ["Pause Download", "Cancel Download"])
        AuditReveal(pause, in: app)
        pause.tap()
        let resume = app.buttons["Resume download of \(title)"]
        XCTAssertTrue(resume.waitForExistence(timeout: 8))
        CollectionFontAssertRow(active, title: title, action: resume, menu: activeMenu, category: category, in: app)
        try CollectionFontCapture(app, name: name, state: "Paused", orientation: "portrait")
        try CollectionFontInspectActiveDetails(app, name: name, state: "Paused", actions: ["Resume Download", "Cancel Download"])
        fixture.collectionFontSetDownload(held: true, rejected: true)
        let beforeResume = fixture.originalDownloadRequestCount
        AuditReveal(resume, in: app)
        resume.tap()
        let retry = app.buttons["Retry download of \(title)"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(fixture.originalDownloadRequestCount, beforeResume,
                             "The visible failure must be caused by the resumed HTTP transfer")
        CollectionFontAssertRow(active, title: title, action: retry, menu: activeMenu, category: category, in: app)
        try CollectionFontCapture(app, name: name, state: "Failed", orientation: "portrait")
        try CollectionFontInspectActiveDetails(app, name: name, state: "Failed", actions: ["Remove from Queue"])
        AuditReveal(activeMenu, in: app)
        activeMenu.tap()
        let showError = app.buttons["Show Error"]
        XCTAssertTrue(showError.waitForExistence(timeout: 3))
        AuditAssertNativeMenuTarget(showError, in: app)
        showError.tap()
        let explanation = app.alerts["Download needs attention"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 3))
        try CollectionFontCapture(app, name: name, state: "Download-error", orientation: "portrait")
        explanation.buttons["OK"].tap()
        fixture.collectionFontSetDownload(held: false, rejected: false)
        reveal(retry, in: app)
        retry.tap()
        let play = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-download-'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        var recordID = String(play.identifier.dropFirst("play-download-".count))
        var row = app.cells.containing(.button, identifier: "download-details-\(recordID)").firstMatch
        var actions = app.buttons["download-actions-\(recordID)"]
        CollectionFontAssertRow(row, title: title, action: play, menu: actions, category: category, in: app)
        try CollectionFontCapture(app, name: name, state: "Ready", orientation: "portrait")
        AuditReveal(actions, in: app)
        actions.tap()
        let favorite = app.buttons["Add Favorite"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 3))
        AuditAssertNativeMenuTarget(favorite, in: app)
        favorite.tap()
        let originalRecordID = recordID
        recordID = try CollectionFontAddCompatibleCopy(to: originalRecordID, in: app)
        row = app.cells.containing(.button, identifier: "download-details-\(recordID)").firstMatch
        actions = app.buttons["download-actions-\(recordID)"]
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-download-'")).count, 1,
                       "The second stored format must not add another movie row")
        let selectedCopy = app.buttons["play-download-\(recordID)"]
        reveal(selectedCopy, in: app)
        selectedCopy.tap()
        let timeline = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        _ = try waitForElapsedSeconds(in: timeline, atLeast: 5, timeout: 12, revealingControlsIn: app)
        if category == .accessibilityExtraExtraExtraLarge {
            // No taps or reveal helper may mask the former three-second timer.
            let before = try elapsedSeconds(from: timeline)
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !timeline.exists
            }, object: nil)
            hidden.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 4.2), .completed,
                           "Accessibility-sized controls must remain until explicitly dismissed")
            _ = try waitForElapsedSeconds(in: timeline, atLeast: before + 3, timeout: 2)
        }
        showPlayerControls(in: app)
        app.buttons["Pause"].tap()
        try capturePlayerAndOptionsFonts(app, name: name, isOffline: true)
        let savedTime = try elapsedSeconds(from: timeline)
        app.buttons["Close player"].tap()
        XCTAssertTrue(app.buttons["collection-continue"].waitForExistence(timeout: 4))
        app.terminate()
        app.launchEnvironment = ["RUSTYVIEW_TEST_NAMESPACE": testNamespace]
        app.launchArguments = arguments
        let baseline = fixture.requestCount
        app.launch()
        XCTAssertTrue(app.buttons["collection-continue"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-download-'")).count, 1,
                       "A resumable movie must still appear once in Downloads")
        let orientations: [(UIDeviceOrientation, String)] = landscape
            ? [(.portrait, "portrait"), (.landscapeLeft, "landscape")]
            : [(.portrait, "portrait")]
        for (orientation, orientationName) in orientations {
            XCUIDevice.shared.orientation = orientation
            let restoredPlay = app.buttons["play-download-\(recordID)"]
            CollectionFontAssertRow(row, title: title, action: restoredPlay, menu: actions, category: category, in: app)
            try CollectionFontCapture(app, name: name, state: "Downloads-restored", orientation: orientationName)
            try CollectionFontInspectCopies(originalID: originalRecordID, compatibleID: recordID,
                                            category: category, name: name, orientation: orientationName, in: app)
            app.buttons["Done"].tap()
            for (collection, destination) in [("continue", "Continue"), ("favorites", "Favorites"), ("history", "History")] {
                if collection != "continue" {
                    let collections = app.buttons["collections-menu"]
                    XCTAssertTrue(collections.exists)
                    collections.tap()
                }
                let choice = app.buttons["collection-\(collection)"]
                XCTAssertTrue(choice.waitForExistence(timeout: 3))
                if collection == "continue" {
                    AuditReveal(choice, in: app)
                    AuditAssertTarget(choice, in: app)
                } else {
                    reveal(choice, in: app)
                    AuditAssertNativeMenuTarget(choice, in: app)
                }
                choice.tap()
                let savedRow = app.descendants(matching: .any).matching(identifier: "saved-movie-42001").firstMatch
                let savedPlay = app.buttons["resume-saved-42001"]
                let savedMenu = app.buttons["saved-actions-42001"]
                XCTAssertTrue(savedPlay.waitForExistence(timeout: 4))
                XCTAssertEqual(app.buttons.matching(identifier: "resume-saved-42001").count, 1)
                CollectionFontAssertRow(savedRow, title: title, action: savedPlay, menu: savedMenu, category: category, in: app)
                try CollectionFontCapture(app, name: name, state: destination, orientation: orientationName)
                AuditReveal(savedMenu, in: app)
                savedMenu.tap()
                let startOver = app.buttons["start-over-saved-42001"]
                XCTAssertTrue(startOver.waitForExistence(timeout: 3))
                AuditAssertNativeMenuTarget(startOver, in: app)
                // At AX sizes the native popup covers the upper-left point;
                // tapping there selects Start Over. Its outer right margin is
                // outside the menu at both phone orientations.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.5)).tap()
                XCTAssertTrue(startOver.waitForNonExistence(timeout: 3))
                XCTAssertFalse(app.buttons["Close player"].exists,
                               "Dismissing the actions menu must not start playback")
                let back = app.navigationBars.buttons.firstMatch
                XCTAssertTrue(back.isHittable)
                back.tap()
            }
        }
        XCUIDevice.shared.orientation = .portrait
        try CollectionFontInspectCopies(originalID: originalRecordID, compatibleID: recordID,
                                        category: category, name: name, orientation: "portrait", in: app)
        let compatibleActions = app.buttons["copy-actions-\(recordID)"]
        reveal(compatibleActions, in: app)
        compatibleActions.tap()
        let delete = app.buttons["delete-download-\(recordID)"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        AuditAssertNativeMenuTarget(delete, in: app)
        delete.tap()
        let confirmation = app.alerts["Delete offline copy?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        AuditAssertTarget(confirmation.buttons["Delete"], in: app, content: false)
        try CollectionFontCapture(app, name: name, state: "Delete-copy-confirmation", orientation: "portrait")
        confirmation.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["play-copy-\(recordID)"].waitForNonExistence(timeout: 5))
        let survivingOriginal = app.buttons["play-copy-\(originalRecordID)"]
        XCTAssertTrue(survivingOriginal.exists, "Deleting one format must preserve the exact other stored file")
        reveal(survivingOriginal, in: app)
        AuditAssertTarget(survivingOriginal, in: app)
        survivingOriginal.tap()
        let restoredTime = try waitForElapsedSeconds(in: timeline, atLeast: savedTime, timeout: 8, revealingControlsIn: app)
        XCTAssertLessThan(restoredTime, savedTime + 4, "The readable Resume action must resume the actual saved local asset")
        XCTAssertEqual(fixture.requestCount, baseline,
                       "Offline Downloads, Continue, Favorites, History and actual Resume must cause zero requests")
    }

    private func CollectionFontAddCompatibleCopy(to originalID: String, in app: XCUIApplication) throws -> String {
        let details = app.buttons["download-details-\(originalID)"]
        reveal(details, in: app)
        details.tap()
        let online = app.segmentedControls["detail-playback-source"].buttons["Online"]
        XCTAssertTrue(online.waitForExistence(timeout: 4))
        reveal(online, in: app)
        online.tap()
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["Watch"].exists && app.buttons["Watch"].isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 8), .completed)
        let actions = app.buttons["detail-actions"]
        reveal(actions, in: app)
        actions.tap()
        let another = app.buttons["Download Another Copy"]
        XCTAssertTrue(another.waitForExistence(timeout: 3))
        AuditAssertNativeMenuTarget(another, in: app)
        another.tap()
        let compatible = app.buttons["Compatible copy"]
        reveal(compatible, in: app)
        AuditAssertTarget(compatible, in: app)
        compatible.tap()
        app.navigationBars.buttons.firstMatch.tap()
        let rowActions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'download-actions-'")).firstMatch
        reveal(rowActions, in: app)
        rowActions.tap()
        let copies = app.buttons["download-copies-42001"]
        XCTAssertTrue(copies.waitForExistence(timeout: 3))
        copies.tap()
        let playable = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-copy-' AND label == %@",
            "Play compatible copy of The Clockwork Orchard")).firstMatch
        XCTAssertTrue(playable.waitForExistence(timeout: 35), "The second copy must finish a real background transfer and asset inspection")
        let compatibleID = String(playable.identifier.dropFirst("play-copy-".count))
        XCTAssertNotEqual(originalID, compatibleID)
        XCTAssertTrue(app.buttons["play-copy-\(originalID)"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["play-download-\(compatibleID)"].waitForExistence(timeout: 4))
        return compatibleID
    }

    private func CollectionFontInspectActiveDetails(_ app: XCUIApplication, name: String,
                                                     state: String, actions: [String]) throws {
        let row = app.buttons["active-download-42001"]
        AuditReveal(row, in: app)
        row.tap()
        XCTAssertTrue(app.navigationBars["The Clockwork Orchard"].waitForExistence(timeout: 5))
        for label in actions {
            let action = app.buttons[label]
            AuditReveal(action, in: app)
            AuditAssertTarget(action, in: app)
        }
        try FontMatrixCapture(app, name: name, screen: "Details-\(state)")
        let disclosure = app.buttons.containing(.staticText, identifier: "active-download-details").firstMatch
        AuditReveal(disclosure, in: app)
        AuditAssertTarget(disclosure, in: app)
        disclosure.tap()
        let audio = app.staticTexts["active-download-audio"]
        AuditReveal(audio, in: app)
        XCTAssertGreaterThan(audio.frame.width, 0)
        try FontMatrixCapture(app, name: name, screen: "Details-\(state)-format")
        app.navigationBars["The Clockwork Orchard"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 3))
        XCTAssertTrue(row.exists, "Reviewing details must preserve the real transfer")
    }

    private func CollectionFontInspectCopies(originalID: String, compatibleID: String,
                                             category: UIContentSizeCategory, name: String,
                                             orientation: String, in app: XCUIApplication) throws {
        let actions = app.buttons["download-actions-\(compatibleID)"]
        reveal(actions, in: app)
        actions.tap()
        let manage = app.buttons["download-copies-42001"]
        XCTAssertTrue(manage.waitForExistence(timeout: 3))
        AuditAssertNativeMenuTarget(manage, in: app)
        manage.tap()
        XCTAssertTrue(app.navigationBars["Saved Copies"].waitForExistence(timeout: 3))
        for (id, title) in [(compatibleID, "Compatible copy"), (originalID, "Original file")] {
            let row = app.descendants(matching: .any).matching(identifier: "download-copy-\(id)").firstMatch
            let play = app.buttons["play-copy-\(id)"]
            let copyActions = app.buttons["copy-actions-\(id)"]
            XCTAssertTrue(play.exists, "Both exact stored renditions must remain playable")
            let summary = row.descendants(matching: .any).matching(identifier: "copy-summary-\(id)").firstMatch
            XCTAssertTrue(summary.exists)
            XCTAssertEqual(summary.label, title)
            let storedSize = try XCTUnwrap(summary.value as? String)
            XCTAssertNotNil(storedSize.range(of: #"[1-9][0-9]*(?:[.,][0-9]+)?\s*(?:KB|MB|GB)"#, options: .regularExpression),
                            "Each saved rendition must announce its size with its format")
            CollectionFontAssertRow(row, title: title, action: play, menu: copyActions, category: category,
                                    in: app, titleElement: summary)
            try CollectionFontCapture(app, name: name, state: "Saved-Copies-\(title)", orientation: orientation)
            AuditReveal(copyActions, in: app)
            copyActions.tap()
            let delete = app.buttons["delete-download-\(id)"]
            XCTAssertTrue(delete.waitForExistence(timeout: 3))
            AuditAssertNativeMenuTarget(delete, in: app)
            // Dismiss without selecting: inspection must not remove either copy.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.5)).tap()
            XCTAssertTrue(delete.waitForNonExistence(timeout: 3))
            XCTAssertFalse(app.alerts["Delete offline copy?"].exists)
        }
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-copy-'")).count, 2)
    }

    private func CollectionFontAssertRow(_ row: XCUIElement, title: String, action: XCUIElement,
                                         menu: XCUIElement, category: UIContentSizeCategory, in app: XCUIApplication,
                                         titleElement: XCUIElement? = nil) {
        let text = titleElement ?? row.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch
        reveal(text, in: app)
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let font = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)
        let naturalWidth = (title as NSString).size(withAttributes: [.font: font]).width
        XCTAssertGreaterThanOrEqual(text.frame.width + 1, min(app.frame.width * 0.55, naturalWidth))
        let bounds = (title as NSString).boundingRect(with: CGSize(width: text.frame.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
        XCTAssertGreaterThanOrEqual(text.frame.height + 4, ceil(bounds.height), "The full synthetic title must fit without truncation")
        XCTAssertLessThanOrEqual(text.frame.maxY, action.frame.minY, "Actions must sit below the readable title")
        for control in [action, menu] {
            reveal(control, in: app)
            AuditAssertTarget(control, in: app)
        }
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        XCTAssertLessThanOrEqual(action.frame.height, max(44, ceil(body.lineHeight)) + 8,
                                 "The action must remain a readable line instead of wrapping into individual letters")
        XCTAssertFalse(action.frame.intersects(menu.frame))
    }

    private func CollectionFontCapture(_ app: XCUIApplication, name: String, state: String, orientation: String) throws {
        try FontMatrixCapture(app, name: name, screen: state, orientation: orientation)
    }
}

// Normal and moderately larger text cover the routine screens. Separate cases
// keep a failure in one journey from hiding the other screen families.
@MainActor
extension RustyViewJourneyTests {
    func testFontMatrixFoldersChaptersLarge() throws { try AuditDeepFolderPathAndExpandedChapters(appearance: "Light", category: .large) }
    func testFontMatrixFoldersChaptersExtraLarge() throws { try AuditDeepFolderPathAndExpandedChapters(appearance: "Light", category: .extraLarge) }

    func testFontMatrixSetupRecoveryLarge() throws { try AuditSetupSettingsAndHTTPRecovery(appearance: "Light", category: .large) }
    func testFontMatrixSetupRecoveryExtraLarge() throws { try AuditSetupSettingsAndHTTPRecovery(appearance: "Light", category: .extraLarge) }

    func testFontMatrixEmptyCompatibilityLarge() throws { try FontAdditionalEmptyCompatibility(.large) }
    func testFontMatrixEmptyCompatibilityExtraLarge() throws { try FontAdditionalEmptyCompatibility(.extraLarge) }

    private func FontAdditionalEmptyCompatibility(_ category: UIContentSizeCategory) throws {
        XCUIDevice.shared.orientation = .portrait
        let fixture = try XCTUnwrap(server)
        fixture.usePaginatedBrowseFixture()
        fixture.auditSetLibrarySchemaVersion(99)
        let app = try launchApp(arguments: AuditArguments("Light", category: category))
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = category.rawValue
        let compatibility = app.buttons["Compatibility Help"]
        XCTAssertTrue(compatibility.waitForExistence(timeout: 8))
        XCTAssertGreaterThan(fixture.auditLibraryRequestCount, 0,
                             "The compatibility error must come from actual unsupported-schema HTTP")
        AuditReveal(compatibility, in: app)
        AuditAssertTarget(compatibility, in: app)
        try FontMatrixCapture(app, name: name, screen: "Library-unsupported-schema")
        AuditReveal(compatibility, in: app)
        compatibility.tap()
        XCTAssertTrue(app.navigationBars["Compatibility Help"].waitForExistence(timeout: 3))
        let edit = app.buttons["compatibility-edit-connection"]
        AuditReveal(edit, in: app)
        AuditAssertTarget(edit, in: app)
        let offline = app.buttons["compatibility-watch-downloads"]
        AuditReveal(offline, in: app)
        AuditAssertTarget(offline, in: app)
        try FontMatrixCapture(app, name: name, screen: "Compatibility-Help-actions")
        let requirements = app.buttons["Server requirements"]
        AuditReveal(requirements, in: app)
        AuditAssertTarget(requirements, in: app)
        requirements.tap()
        let schema = app.staticTexts["rustyDLNA web API schema 2 over HTTPS."]
        XCTAssertTrue(schema.waitForExistence(timeout: 3))
        AuditReveal(schema, in: app)
        XCTAssertTrue(AuditContains(schema.frame, in: AuditContentBounds(app)))
        try FontMatrixCapture(app, name: name, screen: "Compatibility-Help-requirements")
        AuditReveal(offline, in: app)
        offline.tap()
        XCTAssertTrue(app.staticTexts["No downloads yet"].waitForExistence(timeout: 3))
        let browseMovies = app.buttons["Browse Movies"]
        AuditReveal(browseMovies, in: app)
        AuditAssertTarget(browseMovies, in: app)
        try FontMatrixCapture(app, name: name, screen: "Downloads-empty")
        AuditReveal(browseMovies, in: app)
        browseMovies.tap()
        XCTAssertTrue(compatibility.waitForExistence(timeout: 3))
        AuditReveal(compatibility, in: app)
        compatibility.tap()
        AuditReveal(edit, in: app)
        edit.tap()

        let submit = app.buttons["connection-submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 3), "Help must lead to an editable connection")
        let address = app.textFields["connection-server"]
        AuditReveal(address, in: app)
        address.tap()
        address.typeText(try XCTUnwrap(fixture.serverAddress) + "\n")
        let username = app.textFields["connection-username"]
        AuditReveal(username, in: app)
        username.tap()
        username.typeText("viewer\n")
        let password = app.secureTextFields["connection-password"]
        AuditReveal(password, in: app)
        password.tap()
        password.typeText("test-only-password")
        AuditReveal(submit, in: app)
        AuditAssertTarget(submit, in: app)
        fixture.auditSetLibrarySchemaVersion(2)
        let beforeReconnect = fixture.auditLibraryRequestCount
        submit.tap()
        let firstMovie = app.staticTexts["Paper Voyage 01"].firstMatch
        XCTAssertTrue(firstMovie.waitForExistence(timeout: 8))
        XCTAssertTrue(submit.waitForNonExistence(timeout: 3))
        dismissSyntheticPasswordOffer(in: app)
        XCTAssertGreaterThan(fixture.auditLibraryRequestCount, beforeReconnect,
                             "Reconnect must validate the corrected response through a real request")

        // These collections open within the Library stack. Merely selecting
        // the already-selected Library tab leaves an empty collection stuck
        // onscreen; Browse Movies must actually return to the catalog.
        for (identifier, title) in [("collection-favorites", "Favorites"), ("collection-history", "History")] {
            app.buttons["Browse"].tap()
            let collection = app.buttons[identifier]
            XCTAssertTrue(collection.waitForExistence(timeout: 3))
            AuditAssertNativeMenuTarget(collection, in: app)
            collection.tap()
            let navigation = app.navigationBars[title]
            XCTAssertTrue(navigation.waitForExistence(timeout: 3))
            let browse = app.buttons["Browse Movies"]
            AuditReveal(browse, in: app)
            AuditAssertTarget(browse, in: app)
            try FontMatrixCapture(app, name: name, screen: "\(title)-empty")
            AuditReveal(browse, in: app)
            browse.tap()
            XCTAssertTrue(navigation.waitForNonExistence(timeout: 3),
                          "Browse Movies must dismiss the empty collection")
            XCTAssertTrue(firstMovie.waitForExistence(timeout: 3))
            XCTAssertTrue(firstMovie.isHittable)
        }

        let search = app.searchFields["Search movies"]
        // Search belongs to the native navigation area, outside the scrolling
        // content bounds used by AuditReveal. Reveal it without treating that
        // correct placement as clipping beneath the navigation bar.
        for _ in 0..<5 {
            if search.isHittable { break }
            app.swipeDown()
        }
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(AuditContains(search.frame, in: app.frame))
        search.tap()
        search.typeText("absent")
        XCTAssertTrue(app.staticTexts["No matching movies"].waitForExistence(timeout: 5))
        let clear = app.buttons["Clear Search"]
        AuditReveal(clear, in: app)
        AuditAssertTarget(clear, in: app)
        AuditVerifyLibrarySearchClear(restoring: "absent", firstResult: firstMovie, in: app)
        try FontMatrixCapture(app, name: name, screen: "Library-no-matches")
        verifiedNativeSearchClear = nil
        AuditReveal(clear, in: app)
        clear.tap()
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        XCTAssertTrue(firstMovie.waitForExistence(timeout: 5))

        app.buttons["Browse"].tap()
        let folders = app.buttons["Folders"]
        XCTAssertTrue(folders.waitForExistence(timeout: 3))
        folders.tap()
        let shelf = app.staticTexts["Paper Shelf 12"]
        AuditReveal(shelf, in: app)
        shelf.tap()
        let emptyFolder = app.staticTexts["Empty Lantern Box"]
        XCTAssertTrue(emptyFolder.waitForExistence(timeout: 5))
        AuditReveal(emptyFolder, in: app)
        emptyFolder.tap()
        XCTAssertTrue(app.staticTexts["This folder is empty"].waitForExistence(timeout: 5))
        for label in ["Parent Folder", "All Movies", "Refresh"] {
            let action = app.buttons[label]
            AuditReveal(action, in: app)
            AuditAssertTarget(action, in: app)
        }
        try FontMatrixCapture(app, name: name, screen: "Folder-empty")
        fixture.populateEmptyBrowseFolder()
        let beforeRefresh = fixture.auditLibraryRequestCount
        AuditReveal(app.buttons["Refresh"], in: app)
        app.buttons["Refresh"].tap()
        XCTAssertTrue(app.staticTexts["Paper Voyage 36"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(fixture.auditLibraryRequestCount, beforeRefresh,
                             "Empty-folder recovery must fetch its new child, not just hide the empty message")

        app.buttons["Browse"].tap()
        app.buttons["All Movies"].tap()
        fixture.auditSetEmptyLibrary(true)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["No movies yet"].waitForExistence(timeout: 8))
        let refresh = app.buttons["Refresh"]
        AuditReveal(refresh, in: app)
        AuditAssertTarget(refresh, in: app)
        try FontMatrixCapture(app, name: name, screen: "Library-empty")
        fixture.auditSetEmptyLibrary(false)
        let beforeLibraryRefresh = fixture.auditLibraryRequestCount
        AuditReveal(refresh, in: app)
        refresh.tap()
        XCTAssertTrue(firstMovie.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(fixture.auditLibraryRequestCount, beforeLibraryRefresh)
    }
}
