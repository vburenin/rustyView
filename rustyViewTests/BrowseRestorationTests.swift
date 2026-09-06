import Foundation
import XCTest
@testable import rustyView

@MainActor
final class BrowseRestorationTests: XCTestCase {
    override func tearDown() {
        BrowseHTTPProtocol.handler = nil
        super.tearDown()
    }

    func testReturningToParentRestoresEveryLoadedPageAnchorAndItsPaginationGeneration() async throws {
        let (client, model) = try makeModel()
        _ = client
        let requests = BrowseRequests()
        BrowseHTTPProtocol.handler = { request, reply in
            let values = requests.capture(request)
            let child = values["folder"] == "child"
            let offset = Int(values["offset"] ?? "0") ?? 0
            let ids = child ? ["900"] : offset == 0 ? ["100", "101"] : offset == 2 ? ["102", "103"] : ["104"]
            reply(Self.page(values, ids: ids, generation: child ? 99 : 7, total: child ? 1 : 5, hasMore: !child && offset < 4))
        }
        await model.switchView(.folders)
        await model.loadMoreIfNeeded(after: try XCTUnwrap(model.entries.last))
        XCTAssertEqual(model.entries.map(\.id), ["100", "101", "102", "103"])
        model.recordVisibleAnchor("103")
        await model.openFolder("child")
        XCTAssertEqual(model.entries.map(\.id), ["900"])
        let beforeReturn = requests.values.count
        await model.navigateUp()
        XCTAssertEqual(requests.values.count, beforeReturn, "A cached parent must not lose its loaded pages to another first-page request")
        XCTAssertEqual(model.entries.map(\.id), ["100", "101", "102", "103"])
        XCTAssertEqual(model.visibleAnchor, "103")
        XCTAssertEqual(model.currentFolder?.id, "root")
        XCTAssertEqual(model.breadcrumbs.map(\.id), ["root"])
        XCTAssertEqual(model.total, 5)
        XCTAssertTrue(model.canLoadMore)
        await model.loadMoreIfNeeded(after: try XCTUnwrap(model.entries.last))
        XCTAssertEqual(requests.values.last?["offset"], "4")
        XCTAssertEqual(requests.values.last?["generation"], "7", "The child generation must not replace the restored parent's paging owner")
        XCTAssertEqual(model.entries.map(\.id), ["100", "101", "102", "103", "104"])
        XCTAssertFalse(model.canLoadMore)
    }

    func testSearchAndViewReturnRestoreOnlyTheMatchingSortAndLocation() async throws {
        let (_, model) = try makeModel()
        let requests = BrowseRequests()
        BrowseHTTPProtocol.handler = { request, reply in
            let values = requests.capture(request)
            let ids = values["q"] == "orbit" ? ["300"] : values["view"] == "folders" ? ["400"]
                : values["sort"] == "date_desc" ? ["200", "201"] : ["100", "101"]
            reply(Self.page(values, ids: ids))
        }
        try await model.reload()
        model.recordVisibleAnchor("101")
        await model.changeSort(.recent)
        XCTAssertEqual(model.entries.map(\.id), ["200", "201"])
        model.recordVisibleAnchor("201")
        model.search("orbit")
        XCTAssertTrue(model.isNavigating)
        XCTAssertEqual(model.displayedLocation?.query, "")
        XCTAssertEqual(model.requestedLocation?.query, "orbit")
        try await waitUntil { !model.isLoading && model.displayedLocation?.query == "orbit" }
        XCTAssertEqual(model.entries.map(\.id), ["300"])
        XCTAssertNil(model.visibleAnchor, "A new search starts at the top until the view records its visible item")
        let searched = requests.values.count
        await model.clearSearch()
        XCTAssertEqual(requests.values.count, searched)
        XCTAssertEqual(model.entries.map(\.id), ["200", "201"])
        XCTAssertEqual(model.visibleAnchor, "201")
        XCTAssertEqual(model.displayedLocation?.sort, "date_desc")
        await model.switchView(.folders)
        XCTAssertEqual(model.entries.map(\.id), ["400"])
        let folders = requests.values.count
        await model.switchView(.library)
        XCTAssertEqual(requests.values.count, folders)
        XCTAssertEqual(model.entries.map(\.id), ["200", "201"])
        XCTAssertEqual(model.visibleAnchor, "201")
    }

    func testDelayedFolderResponseCannotReplaceNewerSearchOrItsDisplayedLocation() async throws {
        let (_, model) = try makeModel()
        let pending = expectation(description: "Child request reached HTTP")
        let replies = BrowseDelayedReplies()
        BrowseHTTPProtocol.handler = { request, reply in
            let values = BrowseRequests.query(request)
            if values["folder"] == "child", values["q"] == "" {
                replies.store { reply(Self.page(values, ids: ["899"])) }
                pending.fulfill()
            } else {
                reply(Self.page(values, ids: values["q"] == "comet" ? ["900"] : ["800"]))
            }
        }
        await model.switchView(.folders)
        let parentLocation = model.displayedLocation
        let child = Task { await model.openFolder("child") }
        await fulfillment(of: [pending], timeout: 2)
        XCTAssertTrue(model.isNavigating)
        XCTAssertEqual(model.entries.map(\.id), ["800"])
        XCTAssertEqual(model.displayedLocation, parentLocation, "Retained content must keep its old location while a folder loads")
        XCTAssertEqual(model.requestedLocation?.folderID, "child")
        model.search("comet")
        try await waitUntil { !model.isLoading && model.entries.first?.id == "900" }
        replies.deliver()
        await child.value
        XCTAssertEqual(model.entries.map(\.id), ["900"])
        XCTAssertEqual(model.displayedLocation?.query, "comet")
        XCTAssertEqual(model.displayedLocation?.folderID, "child")
        XCTAssertNil(model.visibleAnchor, "A new location starts at the top rather than inheriting an old row anchor")
        XCTAssertNil(model.error)
    }

    func testBrowsePreferencesAndCachedLocationsAreSeparatedByAccountAndDeployment() async throws {
        let suite = "BrowseRestoration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (client, model) = try makeModel(defaults: defaults)
        let first = try XCTUnwrap(client.connection)
        BrowseHTTPProtocol.handler = { request, reply in reply(Self.page(BrowseRequests.query(request), ids: ["100"])) }
        await model.switchView(.folders)
        await model.changeSort(.recent)
        let second = try ServerConnection(serverAddress: first.baseURL.absoluteString, username: "other-viewer", password: "other-secret")
        client.configure(second)
        model.configureConnection(second)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.displayedLocation)
        XCTAssertEqual(model.viewMode, .library)
        XCTAssertEqual(model.sort, .title)
        let reopened = LibraryModel(client: client, defaults: defaults)
        let sameFirst = try ServerConnection(serverAddress: "https://MEDIA.example.test:443/deployment/", username: "viewer", password: "synthetic-secret")
        XCTAssertEqual(reopened.initialRequest(for: sameFirst).view, .folders)
        XCTAssertEqual(reopened.initialRequest(for: sameFirst).sort, .recent)
        XCTAssertEqual(reopened.initialRequest(for: second).view, .library)
        XCTAssertEqual(reopened.initialRequest(for: second).sort, .title)
        let deployment = try ServerConnection(serverAddress: "https://media.example.test/another", username: "viewer", password: "synthetic-secret")
        XCTAssertEqual(reopened.initialRequest(for: deployment).view, .library)
        XCTAssertEqual(reopened.initialRequest(for: deployment).sort, .title)
    }

    private func makeModel(defaults: UserDefaults? = nil) throws -> (RustyDLNAClient, LibraryModel) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrowseHTTPProtocol.self]
        let client = RustyDLNAClient(configuration: configuration)
        let connection = try ServerConnection(serverAddress: "https://media.example.test/deployment", username: "viewer", password: "synthetic-secret")
        client.configure(connection)
        let model = LibraryModel(client: client, defaults: defaults)
        model.configureConnection(connection)
        return (client, model)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate())
    }

    nonisolated private static func page(_ query: [String: String], ids: [String], generation: Int = 7,
                                        total: Int? = nil, hasMore: Bool = false) -> Data {
        let view = query["view"] ?? "library"
        let folder = query["folder"] ?? "root"
        var page: [String: Any] = [
            "schema_version": 2, "generation": generation, "server_name": "Synthetic Browse Server", "root_folder_id": "root",
            "capabilities": ["transcoding": true, "captions": true, "quality_profiles": []],
            "library_state": "ready", "view": view, "breadcrumbs": view == "folders"
                ? (folder == "root" ? [["id": "root", "title": "Invented Folders"]]
                   : [["id": "root", "title": "Invented Folders"], ["id": folder, "title": "Synthetic Child"]]) : [],
            "offset": Int(query["offset"] ?? "0") ?? 0, "limit": 60, "total": total ?? ids.count,
            "has_more": hasMore, "query": query["q"] ?? "", "sort": query["sort"] ?? "title",
            "entries": ids.map { ["entry_type": "video", "id": $0, "title": "Synthetic Movie \($0)"] },
        ]
        if view == "folders" { page["folder"] = ["id": folder, "title": "Synthetic Folder"] }
        return (try? JSONSerialization.data(withJSONObject: page)) ?? Data()
    }
}

private final class BrowseRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String: String]] = []
    var values: [[String: String]] { lock.lock(); defer { lock.unlock() }; return stored }
    func capture(_ request: URLRequest) -> [String: String] {
        let value = Self.query(request)
        lock.lock(); stored.append(value); lock.unlock()
        return value
    }
    static func query(_ request: URLRequest) -> [String: String] {
        guard let url = request.url else { return [:] }
        return Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, newer in newer })
    }
}

private final class BrowseDelayedReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: (() -> Void)?
    func store(_ reply: @escaping () -> Void) { lock.lock(); self.reply = reply; lock.unlock() }
    func deliver() { lock.lock(); let value = reply; reply = nil; lock.unlock(); value?() }
}

private final class BrowseHTTPProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, @escaping (Data) -> Void) -> Void)?
    private let lock = NSRecursiveLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.handler?(request) { [self] body in
            lock.lock()
            defer { lock.unlock() }
            guard !stopped, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}
