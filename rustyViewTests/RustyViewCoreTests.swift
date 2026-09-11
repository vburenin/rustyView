import Foundation
import Combine
import XCTest
@testable import rustyView

final class ApplicationConfigurationTests: XCTestCase {
    func testInstalledAppDeclaresBackgroundAudioForPictureInPicture() throws {
        let modes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        )
        XCTAssertTrue(
            modes.contains("audio"),
            "The built app must retain AVKit's required background playback capability"
        )
    }
}

final class DisplayTitleTests: XCTestCase {
    func testRemovesOnlyTrailingTechnicalReleaseMetadata() {
        XCTAssertEqual(
            DisplayTitle.clean("The Paper Observatory 2160p HDR10 BDRemux"),
            "The Paper Observatory"
        )
        XCTAssertEqual(
            DisplayTitle.clean("The Velvet Astrolabe [1080p HEVC WEB-DL]"),
            "The Velvet Astrolabe"
        )
        XCTAssertEqual(
            DisplayTitle.clean("The Silver Orrery.1080p.DTS-HD.MA.BluRay"),
            "The Silver Orrery"
        )
        XCTAssertEqual(DisplayTitle.clean("The 1080p Experiment"), "The 1080p Experiment")
        XCTAssertEqual(DisplayTitle.clean("District 9"), "District 9")
        XCTAssertEqual(DisplayTitle.clean("The Paper Observatory (2024)"), "The Paper Observatory (2024)")
        XCTAssertEqual(
            DisplayTitle.clean("The Paper Observatory (2024) 2160p HDR10 BDRemux"),
            "The Paper Observatory (2024)",
            "Removing release metadata must preserve punctuation that belongs to the title"
        )
        XCTAssertEqual(
            DisplayTitle.clean("The Paper [Archive] 1080p"),
            "The Paper [Archive]",
            "Bracketed title text must not be mistaken for a release-tag wrapper"
        )
        XCTAssertEqual(DisplayTitle.clean("HDR"), "HDR", "A title made only of a tag must never become blank")
    }

    func testRemovesRedundantEpisodeLabelOnlyWhenItMatchesTheEpisodeCode() {
        XCTAssertEqual(
            DisplayTitle.clean("The Paper Observatory S02E5 - Episode 5"),
            "The Paper Observatory S02E5"
        )
        XCTAssertEqual(
            DisplayTitle.clean("The Velvet Astrolabe S02E005 — Episode 5 1080p HDR"),
            "The Velvet Astrolabe S02E005"
        )
        XCTAssertEqual(
            DisplayTitle.clean("The Silver Orrery S02E5 - Episode 6"),
            "The Silver Orrery S02E5 - Episode 6",
            "A mismatched label may carry useful information and must be preserved"
        )
    }
}

final class ServerConnectionTests: XCTestCase {
    func testResolvesOnlyConfiguredHTTPSOrigin() throws {
        let connection = try ServerConnection(
            serverAddress: "https://media.example.test",
            username: "viewer",
            password: "correct horse"
        )

        XCTAssertEqual(
            try connection.resolve(serverPath: "/api/web/item/42").absoluteString,
            "https://media.example.test/api/web/item/42"
        )
        XCTAssertThrowsError(try connection.resolve(serverPath: "https://attacker.example/web/media/42.mp4")) {
            XCTAssertEqual($0 as? RustyDLNAError, .untrustedURL)
        }
        XCTAssertThrowsError(try connection.resolve(serverPath: "//media.example.test:444/web/media/42.mp4")) {
            XCTAssertEqual($0 as? RustyDLNAError, .untrustedURL)
        }
        XCTAssertThrowsError(
            try ServerConnection(serverAddress: "http://media.example.test", username: "viewer", password: "secret")
        ) {
            XCTAssertEqual($0 as? ConnectionValidationError, .insecureURL)
        }
    }

    func testAuthorizationHeaderUsesExactUTF8Credentials() throws {
        let connection = try ServerConnection(
            serverAddress: "https://media.example.test",
            username: "viewer",
            password: "päss:word"
        )
        let encoded = try XCTUnwrap(connection.authorizationHeader().split(separator: " ").last)
        let decoded = try XCTUnwrap(Data(base64Encoded: String(encoded)))
        XCTAssertEqual(String(data: decoded, encoding: .utf8), "viewer:päss:word")
    }

    func testAuthenticationChallengeCredentialsAreConfinedToTheConfiguredOrigin() throws {
        let connection = try ServerConnection(
            serverAddress: "https://media.example.test",
            username: "viewer",
            password: "synthetic-secret"
        )
        let trusted = Self.challenge(host: "media.example.test", port: 443)
        let credential = try XCTUnwrap(ServerAuthenticationPolicy.credential(
            for: trusted,
            connection: connection
        ))
        XCTAssertEqual(credential.user, "viewer")
        XCTAssertEqual(credential.password, "synthetic-secret")

        XCTAssertNil(ServerAuthenticationPolicy.credential(
            for: Self.challenge(host: "other.example.test", port: 443),
            connection: connection
        ))
        XCTAssertNil(ServerAuthenticationPolicy.credential(
            for: Self.challenge(host: "media.example.test", port: 444),
            connection: connection
        ))
        XCTAssertNil(ServerAuthenticationPolicy.credential(
            for: Self.challenge(
                host: "media.example.test",
                port: 443,
                method: NSURLAuthenticationMethodServerTrust
            ),
            connection: connection
        ))
    }

    private static func challenge(
        host: String,
        port: Int,
        method: String = NSURLAuthenticationMethodHTTPBasic
    ) -> URLAuthenticationChallenge {
        URLAuthenticationChallenge(
            protectionSpace: URLProtectionSpace(
                host: host,
                port: port,
                protocol: "https",
                realm: "Synthetic media",
                authenticationMethod: method
            ),
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: TestAuthenticationChallengeSender()
        )
    }
}

private final class TestAuthenticationChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

@MainActor
final class AppSettingsSecurityTests: XCTestCase {
    func testPasswordRoundTripsThroughKeychainButNeverEntersPreferences() throws {
        let identifier = UUID().uuidString
        let suiteName = "com.example.rustyViewTests.\(identifier)"
        let service = "com.example.rustyViewTests.keychain.\(identifier)"
        let account = "server-password"
        let password = "synthetic-keychain-secret"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: service)
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? keychain.remove(account: account)
        }

        let settings = AppSettings(defaults: defaults, secrets: keychain)
        _ = try settings.save(
            serverAddress: "https://media.example.test",
            username: "viewer",
            password: password
        )

        XCTAssertEqual(try keychain.read(account: account), password)
        XCTAssertFalse(
            defaults.dictionaryRepresentation().values.contains { ($0 as? String) == password },
            "ordinary preferences must never contain the password"
        )

        let restored = AppSettings(defaults: defaults, secrets: keychain)
        XCTAssertEqual(try restored.connection().password, password)
        try restored.forget()
        XCTAssertNil(try keychain.read(account: account))
    }

    func testCellularDownloadsDefaultToAllowedAndPersistAnOptOut() throws {
        let suiteName = "AppSettingsCellularTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults, secrets: KeychainStore(service: suiteName))
        XCTAssertTrue(settings.allowCellularDownloads)

        settings.allowCellularDownloads = false
        let restored = AppSettings(defaults: defaults, secrets: KeychainStore(service: suiteName))
        XCTAssertFalse(restored.allowCellularDownloads)
    }

    func testConnectionIdentityHasNoBuiltInPrivateDefaultAndForgetClearsIt() throws {
        let suiteName = "AppSettingsIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? keychain.remove(account: "server-password")
        }

        let settings = AppSettings(defaults: defaults, secrets: keychain)
        XCTAssertEqual(settings.serverAddress, "")
        XCTAssertEqual(settings.username, "")

        _ = try settings.save(
            serverAddress: "https://media.example.test",
            username: "viewer",
            password: "synthetic-secret"
        )
        try settings.forget()

        XCTAssertEqual(settings.serverAddress, "")
        XCTAssertEqual(settings.username, "")
        XCTAssertFalse(settings.hasSavedConnection)
    }
}

final class ServerModelDecodingTests: XCTestCase {
    func testDecodesRealisticLibraryPageWithoutDependingOnProductionMetadata() throws {
        let data = try XCTUnwrap(Self.libraryJSON.data(using: .utf8))
        let page = try JSONDecoder().decode(LibraryPage.self, from: data)

        XCTAssertEqual(page.schemaVersion, 2)
        XCTAssertEqual(page.generation, 73)
        XCTAssertEqual(page.total, 2)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.capabilities.qualityProfiles.first?.id, "auto")
        XCTAssertEqual(page.entries.map(\.id), ["42001", "folder-7"])
        XCTAssertEqual(page.entries[0].title, "The Clockwork Orchard")
        XCTAssertEqual(page.entries[0].sizeBytes, 4_294_967_300)
        XCTAssertEqual(page.entries[1].childCount, 11)
        XCTAssertTrue(page.entries[1].isFolder)
    }

    func testDecodesItemAudioCaptionsAndChapters() throws {
        let data = try XCTUnwrap(Self.itemJSON.data(using: .utf8))
        let response = try JSONDecoder().decode(ItemResponse.self, from: data)
        let item = response.item

        XCTAssertEqual(item.id, "42001")
        XCTAssertEqual(item.defaultAudioIndex, 1)
        XCTAssertEqual(item.audioTracks[1].language, "eng")
        XCTAssertEqual(item.audioTracks[1].channels, 6)
        XCTAssertEqual(item.captions.first?.sourceFormat, "srt")
        XCTAssertEqual(item.chapters.last?.startSeconds, 1800.5)
        XCTAssertEqual(item.downloadURL, "/web/download/42001")
        XCTAssertTrue(item.transcodeLikely)
    }

    func testCaptionAvailabilityRequiresBothServerSupportAndAConvertedURL() throws {
        let availableData = try XCTUnwrap(Self.itemJSON.data(using: .utf8))
        let available = try JSONDecoder().decode(ItemResponse.self, from: availableData)
        XCTAssertTrue(try XCTUnwrap(available.item.captions.first).isPlayableOnDevice)

        let missingURLJSON = Self.itemJSON.replacingOccurrences(
            of: #""browser_supported": true, "url": "/Captions/42001/0.vtt""#,
            with: #""browser_supported": true, "url": null"#
        )
        let missingURLData = try XCTUnwrap(missingURLJSON.data(using: .utf8))
        let missingURL = try JSONDecoder().decode(ItemResponse.self, from: missingURLData)
        XCTAssertFalse(try XCTUnwrap(missingURL.item.captions.first).isPlayableOnDevice)

        let unsupportedJSON = Self.itemJSON.replacingOccurrences(
            of: #""browser_supported": true"#,
            with: #""browser_supported": false"#
        )
        let unsupportedData = try XCTUnwrap(unsupportedJSON.data(using: .utf8))
        let unsupported = try JSONDecoder().decode(ItemResponse.self, from: unsupportedData)
        XCTAssertFalse(try XCTUnwrap(unsupported.item.captions.first).isPlayableOnDevice)
    }

    private static let libraryJSON = #"""
    {
      "schema_version": 2,
      "generation": 73,
      "server_name": "Synthetic Media Server",
      "root_folder_id": "0",
      "capabilities": {
        "transcoding": true,
        "captions": true,
        "quality_profiles": [{
          "id": "auto", "label": "Auto", "max_width": 3840,
          "max_height": 2160, "expected_bandwidth_kbps": 8000,
          "automatic_fallback": false
        }],
        "unknown_future_capability": true
      },
      "library_state": "ready",
      "view": "library",
      "folder": null,
      "breadcrumbs": [],
      "offset": 0,
      "limit": 2,
      "total": 2,
      "has_more": true,
      "query": "",
      "sort": "title",
      "entries": [
        {
          "entry_type": "media", "id": "42001", "title": "The Clockwork Orchard",
          "file_name": "synthetic-one.mkv", "kind": "video", "mime": "video/x-matroska",
          "ext": "mkv", "duration": "1:42:03", "duration_seconds": 6123,
          "resolution": "1920x1080", "width": 1920, "height": 1080,
          "about": "Invented fixture description.", "genre": "Fiction",
          "size_bytes": 4294967300, "container": "matroska", "video_codec": "hevc",
          "audio_codec": "dts", "hdr": "hdr10", "art_url": "/AlbumArt/42001.jpg",
          "download_url": "/web/download/42001", "source_url": "/web/media/42001.mp4?mode=direct",
          "fallback_url": "/web/media/42001.mp4", "transcode_likely": true
        },
        { "entry_type": "folder", "id": "folder-7", "title": "Invented Collection", "child_count": 11 }
      ]
    }
    """#

    private static let itemJSON = #"""
    {
      "schema_version": 2,
      "id": "42001",
      "item": {
        "id": "42001", "title": "The Clockwork Orchard", "file_name": "synthetic-one.mkv",
        "kind": "video", "mime": "video/x-matroska", "ext": "mkv",
        "duration": "1:42:03", "duration_seconds": 6123, "resolution": "1920x1080",
        "width": 1920, "height": 1080, "about": "Invented fixture description.",
        "plot": "Invented full plot.", "genre": "Fiction", "size_bytes": 4294967300,
        "container": "matroska", "video_codec": "hevc", "video_profile": "Main 10",
        "bit_depth": 10, "frame_rate": "24000/1001", "video_repair_required": false,
        "audio_codec": "aac,dts", "audio_layout": "5.1", "codec_string": "hvc1,mp4a.40.2",
        "hdr": "hdr10",
        "audio_tracks": [
          { "index": 0, "codec": "aac", "content_type": "audio/mp4; codecs=\"mp4a.40.2\"", "channels": 2, "language": "fra", "title": "Dub", "default": false },
          { "index": 1, "codec": "dts", "content_type": null, "channels": 6, "language": "eng", "title": "Original", "default": true }
        ],
        "default_audio_index": 1,
        "captions": [{ "index": 0, "label": "English", "language": "eng", "default": false, "source_format": "srt", "browser_supported": true, "url": "/Captions/42001/0.vtt" }],
        "chapters": [
          { "index": 0, "title": "Copper Key Awakens", "start_seconds": 0.0, "end_seconds": 1800.5 },
          { "index": 1, "title": "Gearwood Secret", "start_seconds": 1800.5, "end_seconds": 6123.0 }
        ],
        "art_url": "/AlbumArt/42001.jpg", "download_url": "/web/download/42001",
        "source_url": "/web/media/42001.mp4?mode=direct", "fallback_url": "/web/media/42001.mp4",
        "transcode_likely": true
      },
      "audio_tracks": [
        { "index": 0, "codec": "aac", "content_type": "audio/mp4", "channels": 2, "language": "fra", "title": "Dub", "default": false },
        { "index": 1, "codec": "dts", "content_type": null, "channels": 6, "language": "eng", "title": "Original", "default": true }
      ],
      "chapters": [
        { "index": 0, "title": "Copper Key Awakens", "start_seconds": 0.0, "end_seconds": 1800.5 },
        { "index": 1, "title": "Gearwood Secret", "start_seconds": 1800.5, "end_seconds": 6123.0 }
      ]
    }
    """#
}

final class RustyDLNAClientHTTPTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testLibraryRequestSendsAuthAndDecodesHTTPResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = RustyDLNAClient(configuration: configuration)
        client.configure(try ServerConnection(
            serverAddress: "https://media.example.test",
            username: "viewer",
            password: "secret"
        ))
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic dmlld2VyOnNlY3JldA==")
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.path, "/api/web/library")
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["view"], "library")
            XCTAssertEqual(query["kind"], "video")
            XCTAssertEqual(query["limit"], "60")
            let data = try XCTUnwrap(ServerModelDecodingTests.libraryJSONForHTTP.data(using: .utf8))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, data)
        }

        let page = try await client.library(LibraryRequest())
        XCTAssertEqual(page.serverName, "Synthetic Media Server")
        XCTAssertEqual(page.entries.first?.id, "42001")
    }

    func testSchemaMismatchIsRejectedAfterValidHTTPTransport() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = RustyDLNAClient(configuration: configuration)
        client.configure(try ServerConnection(serverAddress: "https://media.example.test", username: "viewer", password: "secret"))
        URLProtocolStub.handler = { request in
            let altered = ServerModelDecodingTests.libraryJSONForHTTP.replacingOccurrences(
                of: "\"schema_version\": 2",
                with: "\"schema_version\": 3"
            )
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(altered.utf8))
        }

        do {
            _ = try await client.library(LibraryRequest())
            XCTFail("A newer incompatible schema must not be accepted")
        } catch {
            XCTAssertEqual(error as? RustyDLNAError, .schemaMismatch(3))
        }
    }

    func testRecentlyAddedSortUsesTheServersDateDescendingValue() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = RustyDLNAClient(configuration: configuration)
        client.configure(try ServerConnection(
            serverAddress: "https://media.example.test",
            username: "viewer",
            password: "secret"
        ))
        URLProtocolStub.handler = { request in
            let components = try XCTUnwrap(URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            ))
            let sort = components.queryItems?.first(where: { $0.name == "sort" })?.value
            XCTAssertEqual(sort, "date_desc")
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )),
                try XCTUnwrap(ServerModelDecodingTests.libraryJSONForHTTP.data(using: .utf8))
            )
        }

        _ = try await client.library(LibraryRequest(sort: .recent))
    }

    func testTranscodeStatusUsesDownloadGenerationAndDecodesProducedMediaTime() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = RustyDLNAClient(configuration: configuration)
        client.configure(try ServerConnection(
            serverAddress: "https://media.example.test",
            username: "viewer",
            password: "secret"
        ))
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic dmlld2VyOnNlY3JldA==")
            let components = try XCTUnwrap(URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            ))
            XCTAssertEqual(components.path, "/api/web/transcode/42001")
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            })
            XCTAssertEqual(query["request"], "77")
            XCTAssertEqual(query["session"], "88")
            let body = Data(#"{"schema_version":2,"item_id":"42001","request_id":77,"state":"producing","retry_after_seconds":null,"produced_seconds":1382.5}"#.utf8)
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )),
                body
            )
        }

        let status = try await client.transcodeStatus(
            mediaID: "42001",
            compatiblePath: "/web/media/42001.mp4?mode=compatible&request=77&session=88"
        )

        XCTAssertEqual(status.state, "producing")
        XCTAssertEqual(status.producedSeconds, 1382.5)
    }

    func testCancelTranscodeSendsAuthenticatedDeleteForExactGeneration() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = RustyDLNAClient(configuration: configuration)
        client.configure(try ServerConnection(
            serverAddress: "https://media.example.test",
            username: "viewer",
            password: "secret"
        ))
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Basic dmlld2VyOnNlY3JldA=="
            )
            let components = try XCTUnwrap(URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            ))
            XCTAssertEqual(components.path, "/api/web/transcode/42001")
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            })
            XCTAssertEqual(query["request"], "77")
            XCTAssertEqual(query["session"], "88")
            let body = Data(#"{"schema_version":2,"item_id":"42001","request_id":77,"state":"cancelled","retry_after_seconds":null,"produced_seconds":null}"#.utf8)
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )),
                body
            )
        }

        let status = try await client.cancelTranscode(
            mediaID: "42001",
            compatiblePath: "/web/media/42001.mp4?mode=compatible&request=77&session=88"
        )

        XCTAssertEqual(status.state, "cancelled")
    }
}

@MainActor
final class LibraryFolderNavigationTests: XCTestCase {
    func testFolderBrowsingUsesServerContractAndRestoresParentBreadcrumb() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = RustyDLNAClient(configuration: configuration)
        client.configure(try ServerConnection(
            serverAddress: "https://media.example.test",
            username: "viewer",
            password: "secret"
        ))
        let requests = FolderRequestRecorder()
        URLProtocolStub.handler = { request in
            let components = try XCTUnwrap(URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            ))
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            })
            XCTAssertEqual(query["view"], "folders")
            XCTAssertEqual(query["kind"], "all", "the server rejects media-kind filters in folder view")
            let folderID = query["folder"]
            requests.append(folderID)
            let data = folderID == "folder-7" ? Self.childPage : Self.rootPage
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )),
                data
            )
        }
        defer { URLProtocolStub.handler = nil }

        let model = LibraryModel(client: client)
        await model.switchView(.folders)
        XCTAssertEqual(model.currentFolder, FolderReference(id: "0", title: "Media"))
        XCTAssertEqual(model.entries.first?.id, "folder-7")
        XCTAssertTrue(model.entries.first?.isFolder == true)
        model.recordVisibleAnchor("folder-7")

        await model.openFolder("folder-7")
        XCTAssertEqual(model.currentFolder, FolderReference(id: "folder-7", title: "Invented Shelf"))
        XCTAssertEqual(model.breadcrumbs.map(\.id), ["0", "folder-7"])
        XCTAssertTrue(model.entries.isEmpty)

        await model.navigateUp()
        XCTAssertEqual(model.currentFolder?.id, "0")
        XCTAssertEqual(model.entries.map(\.id), ["folder-7"])
        XCTAssertEqual(model.visibleAnchor, "folder-7")
        let requestedFolders = requests.values
        XCTAssertEqual(requestedFolders.count, 2, "The cached parent restores its entries and anchor without another HTTP request")
        XCTAssertNil(requestedFolders[0])
        XCTAssertEqual(requestedFolders[1], "folder-7")
    }

    private static let rootPage = Data(#"""
    {
      "schema_version":2,"generation":9,"server_name":"Synthetic Media Server",
      "root_folder_id":"0","capabilities":{"transcoding":true,"captions":true,"quality_profiles":[]},
      "library_state":"ready","view":"folders","folder":{"id":"0","title":"Media"},
      "breadcrumbs":[{"id":"0","title":"Media"}],"offset":0,"limit":60,"total":1,
      "has_more":false,"query":"","sort":"title",
      "entries":[{"entry_type":"folder","id":"folder-7","title":"Invented Shelf","child_count":2}]
    }
    """#.utf8)

    private static let childPage = Data(#"""
    {
      "schema_version":2,"generation":9,"server_name":"Synthetic Media Server",
      "root_folder_id":"0","capabilities":{"transcoding":true,"captions":true,"quality_profiles":[]},
      "library_state":"empty","view":"folders","folder":{"id":"folder-7","title":"Invented Shelf"},
      "breadcrumbs":[{"id":"0","title":"Media"},{"id":"folder-7","title":"Invented Shelf"}],
      "offset":0,"limit":60,"total":0,"has_more":false,"query":"","sort":"title","entries":[]
    }
    """#.utf8)
}

private final class FolderRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String?] = []

    func append(_ value: String?) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }

    var values: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }
}

@MainActor
final class LibraryStaleRequestTests: XCTestCase {
    func testResponseForSupersededSearchCannotReplaceCurrentResults() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = RustyDLNAClient(configuration: configuration)
        client.configure(try ServerConnection(
            serverAddress: "https://media.example.test",
            username: "viewer",
            password: "secret"
        ))
        let oldRequestStarted = expectation(description: "old search request started")
        let releaseOldRequest = DispatchSemaphore(value: 0)
        URLProtocolStub.handler = { request in
            let components = try XCTUnwrap(URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            ))
            let query = components.queryItems?.first(where: { $0.name == "q" })?.value
            if query == "old query" {
                oldRequestStarted.fulfill()
                guard releaseOldRequest.wait(timeout: .now() + 2) == .success else {
                    throw URLError(.timedOut)
                }
            }
            let responseJSON = query == "new query"
                ? ServerModelDecodingTests.libraryJSONForHTTP.replacingOccurrences(
                    of: "The Clockwork Orchard",
                    with: "The Amber Observatory"
                )
                : ServerModelDecodingTests.libraryJSONForHTTP
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )),
                Data(responseJSON.utf8)
            )
        }
        defer { URLProtocolStub.handler = nil }

        let model = LibraryModel(client: client)
        model.query = "old query"
        let oldLoad = Task { try await model.reload() }
        await fulfillment(of: [oldRequestStarted], timeout: 1)
        model.query = "new query"
        releaseOldRequest.signal()
        try await oldLoad.value
        XCTAssertTrue(model.entries.isEmpty, "a response for the old query must be discarded immediately")

        try await model.reload()
        XCTAssertEqual(model.entries.first?.title, "The Amber Observatory")
    }
}

private final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class PlaybackCompatibilityTests: XCTestCase {
    func testOnlyCopiesAppleCompatibleVideoAndRepairsBrokenTimestamps() throws {
        let base = try Self.decodeItem()
        XCTAssertEqual(PlaybackCompatibility.videoMode(for: base), "copy")

        let unsupported = try Self.decodeItem(replacing: "\"video_codec\": \"hevc\"", with: "\"video_codec\": \"av1\"")
        XCTAssertEqual(PlaybackCompatibility.videoMode(for: unsupported), "transcode")

        let repaired = try Self.decodeItem(replacing: "\"video_repair_required\": false", with: "\"video_repair_required\": true")
        XCTAssertEqual(PlaybackCompatibility.videoMode(for: repaired), "repair")
    }

    func testCompatibleURLCarriesSelectedAudioQualityStartAndAppleHLSDelivery() throws {
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(try ServerConnection(
            serverAddress: "https://media.example.test",
            username: "viewer",
            password: "secret"
        ))
        let item = try Self.decodeItem()

        let path = client.compatiblePath(
            for: item,
            delivery: "hls",
            quality: "full_hd",
            audioIndex: 0,
            startSeconds: 123
        )
        let components = try XCTUnwrap(URLComponents(string: path))
        let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map {
            ($0.name, $0.value ?? "")
        })

        XCTAssertEqual(components.path, "/web/media/42001.m3u8")
        XCTAssertEqual(query["mode"], "compatible")
        XCTAssertEqual(query["audio"], "0")
        XCTAssertEqual(query["quality"], "full_hd")
        XCTAssertEqual(query["start"], "123")
        XCTAssertEqual(query["video_mode"], "transcode")
        XCTAssertEqual(query["audio_mode"], "transcode")
        XCTAssertEqual(query["delivery"], "hls")
        XCTAssertEqual(query["reason"], "native_ios")
        XCTAssertEqual(query["request"], query["session"], "request and playback session must identify the same generation")
        XCTAssertEqual(query["video_output"], "h264_sdr")

        let portablePath = client.compatiblePath(for: item, forceVideoTranscode: true)
        let portable = try XCTUnwrap(URLComponents(string: portablePath))
        let portableQuery = Dictionary(uniqueKeysWithValues: try XCTUnwrap(portable.queryItems).map {
            ($0.name, $0.value ?? "")
        })
        XCTAssertEqual(portableQuery["video_mode"], "transcode")
        XCTAssertEqual(portableQuery["video_output"], "h264_sdr")

        let offlinePath = client.compatiblePath(for: item, delivery: "mp4")
        let offline = try XCTUnwrap(URLComponents(string: offlinePath))
        XCTAssertEqual(offline.path, "/web/media/42001.mp4")
        XCTAssertNil(offline.queryItems?.first(where: { $0.name == "delivery" }))
    }

    private static func decodeItem(replacing target: String? = nil, with replacement: String = "") throws -> MediaItem {
        var json = ServerModelDecodingTests.itemJSONForHTTP
        if let target { json = json.replacingOccurrences(of: target, with: replacement) }
        return try JSONDecoder().decode(ItemResponse.self, from: Data(json.utf8)).item
    }
}

final class DownloadManifestStoreTests: XCTestCase {
    func testInstallMovesBytesPersistsMetadataAndDeleteRemovesBoth() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let incoming = temporaryRoot.appendingPathComponent("incoming.tmp")
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let payload = try OfflineMediaFixture.validData()
        try payload.write(to: incoming)
        let store = DownloadManifestStore(rootDirectory: temporaryRoot.appendingPathComponent("offline"))
        let metadata = DownloadTaskMetadata(
            recordID: UUID(),
            serverOrigin: "https://media.example.test",
            mediaID: "42001",
            title: "The Clockwork Orchard",
            kind: .compatible,
            fileExtension: "MP4/../",
            durationSeconds: 6123,
            resolution: "3840x2160",
            qualityID: "full_hd",
            qualityLabel: "1080p · 8 Mbps",
            audioTrackIndex: 2,
            audioTrackLabel: "Commentary · AAC · Stereo"
        )

        let record = try store.install(temporaryURL: incoming, metadata: metadata)
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path), "install must consume the temporary file")
        XCTAssertEqual(try Data(contentsOf: store.localURL(for: record)), payload)
        XCTAssertEqual(record.byteCount, Int64(payload.count))
        XCTAssertTrue(record.isReadyToWatch)
        XCTAssertEqual(record.fileName, "offline-\(metadata.recordID.uuidString.lowercased()).mp4")
        XCTAssertEqual(record.qualityID, "full_hd")
        XCTAssertEqual(metadata.videoQualityDescription, "Compatible · Up to 1080p · 8 Mbps")
        XCTAssertEqual(record.assetInspection?.width, 96)
        XCTAssertEqual(record.assetInspection?.height, 64)
        XCTAssertEqual(record.videoQualityDescription, "Compatible · 96×64",
                       "A completed copy must report its inspected dimensions, not the requested 1080p ceiling")
        XCTAssertEqual(record.audioTrackIndex, 2)
        XCTAssertEqual(record.audioSelectionDescription, "Commentary · AAC · Stereo")
        XCTAssertEqual(try store.load().records, [record])

        let replacementInput = temporaryRoot.appendingPathComponent("replacement.tmp")
        let replacementPayload = try OfflineMediaFixture.unsupportedData()
        try replacementPayload.write(to: replacementInput)
        let replacementMetadata = DownloadTaskMetadata(
            recordID: UUID(),
            serverOrigin: metadata.serverOrigin,
            mediaID: metadata.mediaID,
            title: metadata.title,
            kind: .original,
            fileExtension: "webm",
            durationSeconds: metadata.durationSeconds,
            resolution: metadata.resolution
        )
        let replacement = try store.install(temporaryURL: replacementInput, metadata: replacementMetadata)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: store.localURL(for: record).path),
            "An original and a compatible copy must remain independently stored"
        )
        XCTAssertEqual(try Data(contentsOf: store.localURL(for: replacement)), replacementPayload)
        XCTAssertEqual(replacement.videoQualityDescription, "Original · 3840x2160")
        XCTAssertEqual(replacement.audioSelectionDescription, "All original tracks")
        XCTAssertEqual(try store.load().records, [record, replacement])

        try store.delete(replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.localURL(for: replacement).path))
        XCTAssertEqual(try store.load().records, [record])
        try store.delete(record)
        XCTAssertTrue(try store.load().records.isEmpty)
    }

    func testLegacyDownloadMetadataRemainsReadableWithoutInventingQualityOrAudio() throws {
        let data = Data(#"""
        {
          "id":"00000000-0000-0000-0000-000000000042",
          "serverOrigin":"https://media.example.test",
          "mediaID":"42042",
          "title":"The Synthetic Meridian",
          "kind":"compatible",
          "fileName":"offline-synthetic.mp4",
          "byteCount":2048,
          "completedAt":0,
          "durationSeconds":900,
          "resolution":"3840x2160",
          "artworkPath":null
        }
        """#.utf8)

        let record = try JSONDecoder().decode(DownloadRecord.self, from: data)
        XCTAssertEqual(record.videoQualityDescription, "Compatible quality")
        XCTAssertEqual(record.audioSelectionDescription, "Default track")
        XCTAssertNil(record.qualityID)
        XCTAssertNil(record.audioTrackIndex)
    }

    func testMalformedManifestIsReportedInsteadOfSilentlyDiscardingOfflineIndex() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(to: temporaryRoot.appendingPathComponent("manifest.json"))
        let store = DownloadManifestStore(rootDirectory: temporaryRoot)

        XCTAssertThrowsError(try store.load()) { error in
            guard case DownloadStoreError.invalidManifest = error else {
                return XCTFail("Expected invalidManifest, got \(error)")
            }
        }
    }

    func testRejectsEmptyDownloadBeforePublishingARecord() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let incoming = temporaryRoot.appendingPathComponent("empty.tmp")
        XCTAssertTrue(FileManager.default.createFile(atPath: incoming.path, contents: Data()))
        let store = DownloadManifestStore(rootDirectory: temporaryRoot.appendingPathComponent("offline"))
        let metadata = DownloadTaskMetadata(
            recordID: UUID(),
            serverOrigin: "https://media.example.test",
            mediaID: "42002",
            title: "The Lantern Cartographer",
            kind: .compatible,
            fileExtension: "mp4",
            durationSeconds: 900,
            resolution: "1280x720"
        )

        XCTAssertThrowsError(try store.install(temporaryURL: incoming, metadata: metadata)) {
            guard case DownloadStoreError.emptyDownload = $0 else {
                return XCTFail("Expected emptyDownload, got \($0)")
            }
        }
        XCTAssertTrue(try store.load().records.isEmpty)
    }

    func testValidatedLoadRemovesMissingTruncatedAndUnsafeRecords() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let offlineRoot = temporaryRoot.appendingPathComponent("offline")
        try FileManager.default.createDirectory(at: offlineRoot, withIntermediateDirectories: true)
        let validBytes = Data(repeating: 0x5A, count: 128)
        try validBytes.write(to: offlineRoot.appendingPathComponent("42001-compatible.mp4"))
        try Data(repeating: 0x3C, count: 64).write(to: offlineRoot.appendingPathComponent("42001-old.mp4"))
        try Data(repeating: 0x2A, count: 12).write(to: offlineRoot.appendingPathComponent("42002-compatible.mp4"))
        let outside = temporaryRoot.appendingPathComponent("outside.mp4")
        try Data(repeating: 0x7F, count: 64).write(to: outside)

        func record(
            mediaID: String,
            fileName: String,
            byteCount: Int64,
            completedAt: TimeInterval = 1_700_000_000
        ) -> DownloadRecord {
            DownloadRecord(
                id: UUID(),
                serverOrigin: "https://media.example.test",
                mediaID: mediaID,
                title: "Synthetic Offline \(mediaID)",
                kind: .compatible,
                fileName: fileName,
                byteCount: byteCount,
                completedAt: Date(timeIntervalSince1970: completedAt),
                durationSeconds: 600,
                resolution: "1280x720",
                artworkPath: nil
            )
        }

        let valid = record(mediaID: "42001", fileName: "42001-compatible.mp4", byteCount: 128)
        let superseded = record(
            mediaID: "42001",
            fileName: "42001-old.mp4",
            byteCount: 64,
            completedAt: 1_600_000_000
        )
        let truncated = record(mediaID: "42002", fileName: "42002-compatible.mp4", byteCount: 512)
        let missing = record(mediaID: "42003", fileName: "42003-compatible.mp4", byteCount: 128)
        let unsafe = record(mediaID: "42004", fileName: "../outside.mp4", byteCount: 64)
        let manifest = DownloadManifest(records: [superseded, valid, truncated, missing, unsafe])
        try JSONEncoder().encode(manifest).write(to: offlineRoot.appendingPathComponent("manifest.json"))

        let store = DownloadManifestStore(rootDirectory: offlineRoot)
        let reconciled = try store.loadValidated().records
        XCTAssertEqual(Set(reconciled.map(\.id)), Set([valid.id, superseded.id, truncated.id]))
        XCTAssertFalse(try XCTUnwrap(reconciled.first(where: { $0.id == truncated.id })).isReadyToWatch)
        XCTAssertNotNil(try XCTUnwrap(reconciled.first(where: { $0.id == truncated.id })).packageIssue)
        XCTAssertEqual(try store.load().records, reconciled, "reconciliation must be persisted atomically")
        XCTAssertFalse(valid.isReadyToWatch, "Legacy positive bytes are stored, not verified playable")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: offlineRoot.appendingPathComponent("42001-old.mp4").path),
            "Legacy duplicates must not silently delete user files"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: offlineRoot.appendingPathComponent("42002-compatible.mp4").path),
                      "Damaged bytes remain inventoried for explicit recovery or removal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "an unsafe manifest path must never escape the app-owned directory")
    }
}

@MainActor
final class DownloadManagerRestorationTests: XCTestCase {
    func testRestoringBackgroundTasksKeepsOnlyOneDownloadPerServerAndMovie() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let manager = DownloadManager(store: DownloadManifestStore(rootDirectory: temporaryRoot),
                                      sessionIdentifier: "core-restoration.\(UUID().uuidString)",
                                      sessionConfiguration: .ephemeral)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://media.example.test/video.mp4"))

        func task(recordID: UUID) throws -> URLSessionDownloadTask {
            let task = session.downloadTask(with: url)
            let metadata = DownloadTaskMetadata(
                recordID: recordID,
                serverOrigin: "https://media.example.test",
                mediaID: "42009",
                title: "The Paper Observatory",
                kind: .compatible,
                fileExtension: "mp4",
                durationSeconds: 1200,
                resolution: "1920x1080"
            )
            task.taskDescription = String(data: try JSONEncoder().encode(metadata), encoding: .utf8)
            return task
        }

        let retainedID = UUID()
        manager.restore(tasks: [try task(recordID: retainedID), try task(recordID: UUID())])
        await manager.waitForPendingOperations()

        XCTAssertEqual(manager.active.count, 1)
        XCTAssertEqual(manager.active.first?.id, retainedID)
        XCTAssertEqual(manager.active.first?.serverOrigin, "https://media.example.test")
        XCTAssertEqual(manager.active.first?.mediaID, "42009")
        XCTAssertEqual(manager.active.first?.phase, .queued)
    }

    func testRestoringAScheduledRetryKeepsItsVisibleQueueState() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let manager = DownloadManager(store: DownloadManifestStore(rootDirectory: temporaryRoot),
                                      sessionIdentifier: "core-restoration.\(UUID().uuidString)",
                                      sessionConfiguration: .ephemeral)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://media.example.test/video.mp4"))
        let task = session.downloadTask(with: url)
        let scheduledAt = Date().addingTimeInterval(300)
        task.earliestBeginDate = scheduledAt
        let metadata = DownloadTaskMetadata(
            recordID: UUID(),
            serverOrigin: "https://media.example.test",
            mediaID: "42011",
            title: "The Amber Planetarium",
            kind: .compatible,
            fileExtension: "mp4",
            durationSeconds: 900,
            resolution: "1280x720",
            serverPath: "/web/media/42011.mp4",
            retryAttempt: 3
        )
        task.taskDescription = String(data: try JSONEncoder().encode(metadata), encoding: .utf8)

        manager.restore(tasks: [task])
        await manager.waitForPendingOperations()

        guard case .retrying(let attempt, let restoredDate, _) = manager.active.first?.phase else {
            return XCTFail("A persisted scheduled task must remain visibly queued for retry")
        }
        XCTAssertEqual(attempt, 3)
        XCTAssertEqual(restoredDate.timeIntervalSince1970, scheduledAt.timeIntervalSince1970, accuracy: 0.01)
    }
}

final class DownloadResponseValidatorTests: XCTestCase {
    func testAcceptsSuccessfulHTTPAndRejectsAuthErrorsAndNonHTTPBodies() throws {
        let url = try XCTUnwrap(URL(string: "https://media.example.test/web/download/42"))
        let partial = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: nil))
        XCTAssertNil(DownloadResponseValidator.failure(for: partial))

        let unauthorized = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil))
        XCTAssertEqual(
            DownloadResponseValidator.failure(for: unauthorized),
            "The server rejected the saved credentials."
        )

        let missing = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil))
        XCTAssertEqual(DownloadResponseValidator.failure(for: missing), "The download failed (HTTP 404).")
        let disguisedError = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        ))
        XCTAssertEqual(
            DownloadResponseValidator.failure(for: disguisedError),
            "The server returned an error page instead of a video."
        )
        XCTAssertNotNil(DownloadResponseValidator.failure(for: URLResponse(
            url: url,
            mimeType: "application/octet-stream",
            expectedContentLength: 12,
            textEncodingName: nil
        )))
    }

    func testOnlyTransientHTTPAndTransportFailuresAreRetriedWithBoundedBackoff() throws {
        let url = try XCTUnwrap(URL(string: "https://media.example.test/video.mp4"))
        func response(_ status: Int) throws -> HTTPURLResponse {
            try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        }

        XCTAssertTrue(DownloadResponseValidator.isRetryable(try response(503)))
        XCTAssertTrue(DownloadResponseValidator.isRetryable(try response(429)))
        XCTAssertFalse(DownloadResponseValidator.isRetryable(try response(401)))
        XCTAssertFalse(DownloadResponseValidator.isRetryable(try response(404)))
        XCTAssertTrue(DownloadRetryPolicy.isRetryable(URLError(.networkConnectionLost)))
        XCTAssertTrue(DownloadRetryPolicy.isRetryable(URLError(.notConnectedToInternet)))
        XCTAssertFalse(DownloadRetryPolicy.isRetryable(URLError(.cancelled)))
        XCTAssertEqual(DownloadRetryPolicy.delay(forAttempt: 1), 0)
        XCTAssertEqual(DownloadRetryPolicy.delay(forAttempt: 4), 20)
        XCTAssertEqual(DownloadRetryPolicy.delay(forAttempt: 100), 900)
    }

    func testCellularPolicyChangesTheActualDownloadRequest() throws {
        let url = try XCTUnwrap(URL(string: "https://media.example.test/video.mp4"))
        var request = URLRequest(url: url)

        DownloadNetworkPolicy.apply(allowsCellularDownloads: false, to: &request)
        XCTAssertFalse(request.allowsCellularAccess)
        DownloadNetworkPolicy.apply(allowsCellularDownloads: true, to: &request)
        XCTAssertTrue(request.allowsCellularAccess)
    }

    func testProgressFallsBackToTheHTTPContentLengthWhenTheDelegateReportsUnknown() throws {
        let url = try XCTUnwrap(URL(string: "https://media.example.test/video.mp4"))
        let response = URLResponse(
            url: url,
            mimeType: "video/mp4",
            expectedContentLength: 4_194_304,
            textEncodingName: nil
        )

        XCTAssertEqual(
            DownloadProgressValues.expectedByteCount(
                reported: NSURLSessionTransferSizeUnknown,
                response: response
            ),
            4_194_304
        )
        XCTAssertEqual(
            DownloadProgressValues.expectedByteCount(reported: 8_388_608, response: response),
            8_388_608
        )
        XCTAssertNil(
            DownloadProgressValues.expectedByteCount(
                reported: NSURLSessionTransferSizeUnknown,
                response: nil
            )
        )
    }

    func testLegacyTaskMetadataDecodesWithoutRetryFields() throws {
        let json = """
        {
          "recordID":"5C6883BB-A93B-4FC8-B3B2-425DC6505540",
          "serverOrigin":"https://media.example.test",
          "mediaID":"42010",
          "title":"The Brass Sundial",
          "kind":"compatible",
          "fileExtension":"mp4",
          "durationSeconds":120,
          "resolution":"1280x720"
        }
        """
        let metadata = try JSONDecoder().decode(DownloadTaskMetadata.self, from: Data(json.utf8))
        XCTAssertNil(metadata.serverPath)
        XCTAssertNil(metadata.retryAttempt)
    }

    func testPreparationProgressUsesMediaTimeAndRejectsInventedPercentages() {
        let progress = DownloadPreparationProgress(producedSeconds: 1382, durationSeconds: 5528)
        XCTAssertNotNil(progress)
        XCTAssertEqual(progress?.fraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(progress?.producedSeconds, 1382)
        XCTAssertEqual(progress?.percent, 25)
        XCTAssertEqual(progress?.presentationText, "Prepared 23:02 of 1:32:08 · 25%")

        let finished = DownloadPreparationProgress(producedSeconds: 9_000, durationSeconds: 5528)
        XCTAssertEqual(finished?.fraction ?? -1, 1, accuracy: 0.0001)
        XCTAssertNil(DownloadPreparationProgress(producedSeconds: .infinity, durationSeconds: 5528))
        XCTAssertNil(DownloadPreparationProgress(producedSeconds: 30, durationSeconds: nil))
        XCTAssertNil(DownloadPreparationProgress(producedSeconds: 30, durationSeconds: 0))

        XCTAssertNil(
            DownloadPhase.downloading(progress: 0, received: 524_288, expected: nil).progress,
            "Unknown-size transcoded output must not be presented as a permanent zero percent"
        )
        XCTAssertEqual(
            DownloadPhase.downloading(progress: 0.5, received: 524_288, expected: 1_048_576).progress,
            0.5
        )
    }
}

final class PlaybackProgressStoreTests: XCTestCase {
    func testResumeThresholdsAndServerNamespacingUsePersistedState() throws {
        let suite = "PlaybackProgressStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackProgressStore(defaults: defaults)

        store.update(serverOrigin: "https://one.example", mediaID: "42", position: 12, duration: 3600)
        XCTAssertNil(store.resumePosition(serverOrigin: "https://one.example", mediaID: "42"), "near-start noise must not create a resume point")

        store.update(serverOrigin: "https://one.example", mediaID: "42", position: 905.5, duration: 3600)
        XCTAssertEqual(store.resumePosition(serverOrigin: "https://one.example", mediaID: "42"), 905.5)
        XCTAssertNil(store.resumePosition(serverOrigin: "https://two.example", mediaID: "42"), "same media ID on another server must not collide")

        let restored = PlaybackProgressStore(defaults: defaults)
        XCTAssertEqual(restored.resumePosition(serverOrigin: "https://one.example", mediaID: "42"), 905.5, "resume must survive process-level store recreation")

        store.update(serverOrigin: "https://one.example", mediaID: "42", position: 3550, duration: 3600)
        XCTAssertNil(store.resumePosition(serverOrigin: "https://one.example", mediaID: "42"), "near-complete playback must clear resume")
    }
}

final class PlaybackRoutingTests: XCTestCase {
    func testAutomaticPlaybackHonorsCompatibilityNeedsAndExplicitQuality() {
        XCTAssertFalse(PlaybackRouting.usesCompatibleStream(
            mode: .automatic,
            quality: "auto",
            transcodeLikely: false
        ))
        XCTAssertTrue(PlaybackRouting.usesCompatibleStream(
            mode: .automatic,
            quality: "full_hd",
            transcodeLikely: false
        ), "an explicit quality cannot be honored by the untouched original stream")
        XCTAssertTrue(PlaybackRouting.usesCompatibleStream(
            mode: .automatic,
            quality: "auto",
            transcodeLikely: true
        ))
        XCTAssertFalse(PlaybackRouting.usesCompatibleStream(
            mode: .original,
            quality: "full_hd",
            transcodeLikely: true
        ))
        XCTAssertTrue(PlaybackRouting.usesCompatibleStream(
            mode: .compatible,
            quality: "auto",
            transcodeLikely: false
        ))
        XCTAssertEqual(
            PlaybackRouting.attempt(mode: .portable, quality: "auto", transcodeLikely: false),
            .portable
        )
        XCTAssertEqual(
            PlaybackRouting.attempt(
                mode: .automatic,
                quality: "auto",
                transcodeLikely: false,
                selectedAudioIndex: 0,
                defaultAudioIndex: 1
            ),
            .compatible,
            "a non-default audio choice cannot be guaranteed by an untouched original stream"
        )
        XCTAssertEqual(
            PlaybackRouting.attempt(
                mode: .automatic,
                quality: "auto",
                transcodeLikely: false,
                selectedAudioIndex: 1,
                defaultAudioIndex: 1
            ),
            .original
        )
        XCTAssertEqual(
            PlaybackRouting.nextFallback(after: .original, videoMode: "copy"),
            .compatible
        )
        XCTAssertEqual(
            PlaybackRouting.nextFallback(after: .compatible, videoMode: "copy"),
            .portable
        )
        XCTAssertNil(
            PlaybackRouting.nextFallback(after: .compatible, videoMode: "transcode"),
            "a stream that already transcodes video has no broader server fallback"
        )
        XCTAssertNil(PlaybackRouting.nextFallback(after: .portable, videoMode: "copy"))
    }

    func testStartupRecoveryFallsBackThenRetriesOnlyOnce() {
        XCTAssertEqual(
            PlaybackRouting.startupAction(
                after: .original,
                videoMode: "copy",
                automaticFallbackEnabled: true,
                retryCount: 0
            ),
            .fallback(.compatible)
        )
        XCTAssertEqual(
            PlaybackRouting.startupAction(
                after: .compatible,
                videoMode: "transcode",
                automaticFallbackEnabled: true,
                retryCount: 0
            ),
            .retry,
            "an already-portable server stream has no broader codec fallback, so one fresh session is warranted"
        )
        XCTAssertEqual(
            PlaybackRouting.startupAction(
                after: .compatible,
                videoMode: "transcode",
                automaticFallbackEnabled: true,
                retryCount: 1
            ),
            .fail,
            "startup recovery must be bounded instead of spinning transcode sessions forever"
        )
    }

    func testPreparedStreamTimelineTranslatesChapterTimesAndRejectsEarlierTargets() {
        XCTAssertEqual(
            PlaybackTimeline.localTime(forGlobalTime: 2_400, streamOffset: 1_800),
            600
        )
        XCTAssertEqual(
            PlaybackTimeline.localTime(forGlobalTime: 1_800, streamOffset: 1_800),
            0
        )
        XCTAssertNil(
            PlaybackTimeline.localTime(forGlobalTime: 900, streamOffset: 1_800),
            "jumping before a prepared stream's offset requires rebuilding it at the chapter"
        )
        XCTAssertEqual(
            PlaybackTimeline.localTime(forGlobalTime: -20, streamOffset: 0),
            0
        )
    }

    func testPreparedStreamCanSeekLocallyOnlyInsideGeneratedRanges() {
        let generated = [0.0...19.0, 25.0...31.0]

        XCTAssertTrue(PlaybackTimeline.contains(10, in: generated))
        XCTAssertTrue(
            PlaybackTimeline.contains(19.4, in: generated),
            "a small floating-point boundary difference should not restart the stream"
        )
        XCTAssertFalse(
            PlaybackTimeline.contains(22, in: generated),
            "a gap between generated fragments is not seekable"
        )
        XCTAssertFalse(
            PlaybackTimeline.contains(2_400, in: generated),
            "a catalog-duration scrub must restart a growing prepared stream at the requested time"
        )
        XCTAssertFalse(PlaybackTimeline.contains(.infinity, in: generated))
    }

    func testPlayerSeekTargetsClampToRealTimelineBoundaries() {
        XCTAssertEqual(PlaybackTimeline.skipTarget(currentTime: 4, seconds: 10, duration: 90), 14)
        XCTAssertEqual(
            PlaybackTimeline.skipTarget(currentTime: 5, seconds: -10, duration: 90),
            0,
            "rewinding near the start must never create a negative AVPlayer time"
        )
        XCTAssertEqual(
            PlaybackTimeline.skipTarget(currentTime: 86, seconds: 10, duration: 90),
            90,
            "forward seeking near the end must stop at the media duration"
        )
        XCTAssertEqual(PlaybackTimeline.skipTarget(currentTime: 8, seconds: 10, duration: nil), 18)
        XCTAssertEqual(PlaybackTimeline.clampedTime(.infinity, duration: 90), 0)
    }

    func testPlayerProgressAndTimeLabelsRepresentActualTimelineValues() {
        XCTAssertEqual(PlaybackTimeline.progress(45, duration: 90), 0.5)
        XCTAssertEqual(PlaybackTimeline.progress(-10, duration: 90), 0)
        XCTAssertEqual(PlaybackTimeline.progress(120, duration: 90), 1)
        XCTAssertEqual(PlaybackTimeline.progress(1, duration: 0), 0)
        XCTAssertEqual(PlaybackTimeline.displayTime(0), "0:00")
        XCTAssertEqual(PlaybackTimeline.displayTime(65), "1:05")
        XCTAssertEqual(PlaybackTimeline.displayTime(3_725), "1:02:05")
    }

    func testActiveChapterUsesGlobalTimeAndExactChapterBoundaries() {
        let chapters = [
            Chapter(index: 0, title: "Copper Key Awakens", startSeconds: 0, endSeconds: 600),
            Chapter(index: 1, title: "Gearwood Secret", startSeconds: 600, endSeconds: 1_200),
        ]

        XCTAssertEqual(PlaybackTimeline.activeChapterIndex(in: chapters, at: -1), 0)
        XCTAssertEqual(PlaybackTimeline.activeChapterIndex(in: chapters, at: 599.999), 0)
        XCTAssertEqual(PlaybackTimeline.activeChapterIndex(in: chapters, at: 600), 1)
        XCTAssertNil(PlaybackTimeline.activeChapterIndex(in: chapters, at: 1_200))
        XCTAssertNil(PlaybackTimeline.activeChapterIndex(in: [], at: 300))
    }
}

final class WebVTTParserTests: XCTestCase {
    func testParsesMultilineHoursSettingsAndIgnoresNotesAndMalformedCues() throws {
        let source = #"""
        WEBVTT

        NOTE generated synthetic caption
        ignored

        cue-one
        00:00:01.250 --> 00:00:03.500 align:middle
        First <i>invented</i> line
        Second line

        malformed --> cue
        Not shown

        01:02:03.000 --> 01:02:04.125
        Later cue
        """#

        let cues = try WebVTTParser.parse(Data(source.utf8))
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0], SubtitleCue(start: 1.25, end: 3.5, text: "First invented line\nSecond line"))
        XCTAssertTrue(cues[0].contains(1.25))
        XCTAssertFalse(cues[0].contains(3.5), "cue end times are exclusive to avoid overlapping adjacent cues")
        XCTAssertEqual(cues[1].start, 3723, accuracy: 0.0001)
        XCTAssertEqual(cues[1].end, 3724.125, accuracy: 0.0001)
    }

    func testRejectsNonWebVTTDataInsteadOfDisplayingGarbage() {
        XCTAssertThrowsError(try WebVTTParser.parse(Data("1\n00:00:01,000 --> 00:00:02,000\ntext".utf8))) {
            guard case SubtitleError.invalidFormat = $0 else {
                return XCTFail("Expected invalidFormat, got \($0)")
            }
        }
    }
}

@MainActor
final class AppModelObservationTests: XCTestCase {
    func testNestedLibraryChangesInvalidateRootModel() async {
        let model = AppModel()
        await model.userLibrary.waitUntilRestored()
        await model.movieCache.waitUntilRestored()
        await model.downloads.waitUntilRestored()
        let settled = expectation(description: "Restoration publications have reached the main queue")
        DispatchQueue.main.async { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 1)
        let changed = expectation(description: "Root model forwards child state changes")
        let cancellable = model.objectWillChange.prefix(1).sink { changed.fulfill() }

        model.library.sort = .recent

        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(model.library.sort, .recent)
        withExtendedLifetime(cancellable) {}
    }
}

extension ServerModelDecodingTests {
    static var libraryJSONForHTTP: String { libraryJSON }
    static var itemJSONForHTTP: String { itemJSON }
}
