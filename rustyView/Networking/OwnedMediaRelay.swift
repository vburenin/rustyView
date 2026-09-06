import Foundation
import Network

/// One immutable playback attempt owns the listener, authentication and routes.
/// All transport state below is confined to `queue`; only rejection/callback
/// access uses the small lock. No media I/O runs on the main actor.
final class OwnedMediaRelay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let attemptID = UUID()
    private let connection: ServerConnection
    private let sourceURL: URL
    private let sourceKind: MediaRelayResourceKind
    private let limits: MediaRelayLimits
    private let queue = DispatchQueue(label: "com.example.rustyView.media-relay")
    private let listener: NWListener
    private var session: URLSession!
    private var registry: MediaRelayRegistry
    private var port: UInt16?
    private var stopped = false
    private var startupWaiters: [CheckedContinuation<URL, Error>] = []
    private var clients: [UUID: RelayClient] = [:]
    private var waiting: [UUID] = []
    private var taskClients: [Int: UUID] = [:]
    private var bufferedBytes = 0
    private var peakBufferedBytes = 0
    private var peakStreamBytes = 0
    private var completedMediaResponses = 0
    private var forwardedBodyBytes: Int64 = 0
    private let issueLock = NSLock()
    private var storedRejection: UserFacingError?
    private var failureCallback: ((UserFacingError) -> Void)?

    var rejection: UserFacingError? { issueLock.lock(); defer { issueLock.unlock() }; return storedRejection }
    func metrics() async -> MediaRelayMetrics {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: MediaRelayMetrics(activeRequests: self.taskClients.count,
                    waitingRequests: self.waiting.count, acceptedConnections: self.clients.count,
                    retainedBytes: self.bufferedBytes, peakRetainedBytes: self.peakBufferedBytes,
                    peakStreamBytes: self.peakStreamBytes, registeredResources: self.registry.resources.count,
                    completedMediaResponses: self.completedMediaResponses, forwardedBodyBytes: self.forwardedBodyBytes))
            }
        }
    }
    var onFailure: ((UserFacingError) -> Void)? {
        get { issueLock.lock(); defer { issueLock.unlock() }; return failureCallback }
        set {
            issueLock.lock()
            failureCallback = newValue
            let existing = storedRejection
            issueLock.unlock()
            if let existing, existing.category == .transportSecurity, let newValue {
                DispatchQueue.main.async { newValue(existing) }
            }
        }
    }

    init(sourceURL: URL, connection: ServerConnection, limits: MediaRelayLimits = MediaRelayLimits()) throws {
        guard connection.origin.matches(sourceURL) else { throw RustyDLNAError.untrustedURL }
        self.connection = connection
        self.sourceURL = sourceURL
        sourceKind = .source(sourceURL)
        self.limits = limits
        let parameters = NWParameters.tcp
        // Bind the socket itself to loopback. acceptLocalOnly restricts peers
        // to the local network link; it is not a loopback/process boundary.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        registry = MediaRelayRegistry(origin: connection.origin, token: UUID().uuidString.lowercased(), limits: limits)
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = limits.activeRequests
        let callbacks = OperationQueue()
        callbacks.maxConcurrentOperationCount = 1
        callbacks.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: callbacks)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                self.port = self.listener.port?.rawValue
                self.finishStartup()
            case .failed(let error): self.fail(error, terminal: true)
            default: break
            }
        }
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + limits.headerTimeout) { [weak self] in
            guard let self, !self.stopped, self.port == nil else { return }
            self.fail(URLError(.timedOut), terminal: true)
        }
    }

    func assetURL() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.stopped else { continuation.resume(throwing: self.rejection ?? MediaRelayError.cancelled.issue); return }
                    self.startupWaiters.append(continuation)
                    self.finishStartup()
                }
            }
        } onCancel: { self.stop() }
    }

    private func finishStartup() {
        guard let port, !startupWaiters.isEmpty else { return }
        do {
            let local = try registry.register(sourceURL, kind: sourceKind, port: port)
            let waiters = startupWaiters
            startupWaiters.removeAll()
            waiters.forEach { $0.resume(returning: local) }
        } catch { fail(error, terminal: true) }
    }

    func stop() { queue.async { self.stopOnQueue() } }

    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        listener.cancel()
        let waiters = startupWaiters
        startupWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: rejection ?? MediaRelayError.cancelled.issue) }
        for client in Array(clients.values) { close(client) }
        waiting.removeAll()
        session.invalidateAndCancel()
    }

    private func fail(_ error: Error, terminal: Bool = false) {
        let issue = (error as? MediaRelayError)?.issue ?? UserFacingError(error, title: "Playback unavailable")
        issueLock.lock()
        let hadTrustRejection = storedRejection?.category == .transportSecurity
        // Preserve the terminal trust finding when cancellation callbacks follow.
        if storedRejection?.category != .transportSecurity { storedRejection = issue }
        let callback = failureCallback
        issueLock.unlock()
        if issue.category == .transportSecurity && !hadTrustRejection {
            if let callback { DispatchQueue.main.async { callback(issue) } }
            stopOnQueue()
        } else if terminal { stopOnQueue() }
    }

    private func accept(_ socket: NWConnection) {
        guard !stopped, clients.count < limits.acceptedConnections else { socket.cancel(); return }
        let client = RelayClient(socket: socket)
        clients[client.id] = client
        socket.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            if case .failed = state { self.close(client) }
            if case .cancelled = state { self.close(client) }
        }
        socket.start(queue: queue)
        queue.asyncAfter(deadline: .now() + limits.headerTimeout) { [weak self, weak client] in
            guard let self, let client, client.request == nil else { return }
            self.close(client)
        }
        readHeader(client)
    }

    private func readHeader(_ client: RelayClient) {
        client.socket.receive(minimumIncompleteLength: 1, maximumLength: limits.headerBytes) { [weak self, weak client] data, _, finished, error in
            guard let self, let client, self.clients[client.id] != nil else { return }
            guard error == nil, let data, data.count <= self.limits.headerBytes - client.header.count else { self.close(client); return }
            client.header.append(data)
            guard client.header.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if finished { self.close(client) } else { self.readHeader(client) }
                return
            }
            do {
                guard let port = self.port else { throw MediaRelayError.invalidRequest }
                let request = try MediaRelayHTTPRequest.parse(client.header, port: port)
                guard let resource = self.registry.resources[request.target] else { throw MediaRelayError.invalidRequest }
                client.request = request
                client.resource = resource
                client.header.removeAll(keepingCapacity: false)
                if self.taskClients.count < self.limits.activeRequests { self.launch(client) }
                else if self.waiting.count < self.limits.waitingRequests { self.waiting.append(client.id) }
                else { self.respondFailure(client, status: 503) }
                self.observeClientClosure(client)
            } catch { self.close(client) }
        }
    }

    private func observeClientClosure(_ client: RelayClient) {
        // No request body/pipelining is supported. Keep a receive pending so
        // cancellation immediately removes a queued slot or upstream transfer.
        client.socket.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self, weak client] bytes, _, ended, error in
            guard let self, let client, self.clients[client.id] != nil else { return }
            if ended || error != nil || bytes?.isEmpty == false { self.close(client) }
            else { self.observeClientClosure(client) }
        }
    }

    private func launch(_ client: RelayClient) {
        guard !stopped, let incoming = client.request, let resource = client.resource else { close(client); return }
        var request = URLRequest(url: resource.url)
        request.httpMethod = resource.kind == .playlist ? "GET" : incoming.method
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for name in ["range", "if-range", "if-none-match", "if-modified-since"] {
            // A playlist must be parsed as a whole before any references reach
            // the native player. Range semantics apply to media/key resources.
            if resource.kind != .playlist, let value = incoming.headers[name] { request.setValue(value, forHTTPHeaderField: name) }
        }
        let task = session.dataTask(with: request)
        client.task = task
        taskClients[task.taskIdentifier] = client.id
        task.resume()
    }

    private func schedule() {
        while !stopped, taskClients.count < limits.activeRequests, !waiting.isEmpty {
            let id = waiting.removeFirst()
            if let client = clients[id] { launch(client) }
        }
    }

    private func close(_ client: RelayClient) {
        guard clients.removeValue(forKey: client.id) != nil else { return }
        waiting.removeAll { $0 == client.id }
        if let task = client.task { taskClients[task.taskIdentifier] = nil; task.cancel() }
        bufferedBytes -= client.retainedBytes
        client.retainedBytes = 0
        client.pending.removeAll()
        client.prefix.removeAll()
        client.playlist.removeAll()
        client.socket.cancel()
        schedule()
    }

    private func client(for task: URLSessionTask) -> RelayClient? { taskClients[task.taskIdentifier].flatMap { clients[$0] } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard client(for: task) != nil, !stopped else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        let space = challenge.protectionSpace
        let trust = space.authenticationMethod == NSURLAuthenticationMethodServerTrust
        guard connection.origin.matches(scheme: space.protocol ?? (trust ? "https" : nil), host: space.host, port: space.port) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            fail(MediaRelayError.untrustedReference)
            return
        }
        if let credential = ServerAuthenticationPolicy.credential(for: challenge, connection: connection) {
            completionHandler(.useCredential, credential)
        } else if space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic || space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest {
            fail(RustyDLNAError.authenticationFailed)
            completionHandler(.cancelAuthenticationChallenge, nil)
        } else { completionHandler(.performDefaultHandling, nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let client = client(for: task), !stopped else { completionHandler(nil); return }
        guard let url = request.url, connection.origin.matches(url), url.fragment == nil else {
            completionHandler(nil); fail(MediaRelayError.untrustedReference); return
        }
        guard client.redirects < limits.redirectHops else { completionHandler(nil); fail(URLError(.httpTooManyRedirects)); return }
        client.redirects += 1
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let client = client(for: dataTask), !stopped else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse, let url = http.url else {
            completionHandler(.cancel); fail(MediaRelayError.invalidResponse); return
        }
        guard connection.origin.matches(url) else {
            completionHandler(.cancel); fail(MediaRelayError.untrustedReference); return
        }
        client.response = http
        guard (200..<300).contains(http.statusCode) else {
            fail(RustyDLNAError.http(status: http.statusCode, message: "The server request failed (HTTP \(http.statusCode)).", code: nil))
            completionHandler(.cancel)
            respondFailure(client, status: http.statusCode)
            return
        }
        guard http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            completionHandler(.cancel); fail(MediaRelayError.invalidResponse); respondFailure(client, status: 502); return
        }
        if client.resource?.kind == .playlist, http.expectedContentLength > Int64(limits.playlistBytes) {
            completionHandler(.cancel); fail(MediaRelayError.resourceLimit); respondFailure(client, status: 502); return
        }
        if client.resource?.kind != .playlist, HLSRelayPlaylist.resemblesPlaylist(Data(), contentType: http.mimeType) {
            completionHandler(.cancel); fail(MediaRelayError.unexpectedPlaylist); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let client = client(for: dataTask), !stopped else { return }
        if client.resource?.kind == .playlist {
            guard reserve(data.count, client: client), data.count <= limits.playlistBytes - client.playlist.count else {
                fail(MediaRelayError.resourceLimit); close(client); return
            }
            client.playlist.append(data)
            return
        }
        guard reserve(data.count, client: client) else { fail(MediaRelayError.resourceLimit); close(client); return }
        if !client.headersSent {
            client.prefix.append(data)
            if HLSRelayPlaylist.resemblesPlaylist(client.prefix, contentType: client.response?.mimeType) {
                fail(MediaRelayError.unexpectedPlaylist); return
            }
            if client.prefix.count < 4096 { return }
            beginMedia(client)
        } else { enqueue(data, client: client, alreadyReserved: true) }
    }

    private func reserve(_ count: Int, client: RelayClient) -> Bool {
        guard count >= 0, count <= limits.streamBufferBytes - client.retainedBytes,
              count <= limits.totalBufferBytes - bufferedBytes else { return false }
        client.retainedBytes += count
        bufferedBytes += count
        peakBufferedBytes = max(peakBufferedBytes, bufferedBytes)
        peakStreamBytes = max(peakStreamBytes, client.retainedBytes)
        return true
    }

    private func release(_ count: Int, client: RelayClient) {
        guard clients[client.id] != nil else { return }
        client.retainedBytes -= count
        bufferedBytes -= count
    }

    private func beginMedia(_ client: RelayClient) {
        guard let http = client.response, !client.headersSent else { return }
        if HLSRelayPlaylist.resemblesPlaylist(client.prefix, contentType: http.mimeType) { fail(MediaRelayError.unexpectedPlaylist); return }
        client.headersSent = true
        client.chunked = http.expectedContentLength < 0 && client.request?.method != "HEAD"
        var header = "HTTP/1.1 \(http.statusCode) OK\r\nConnection: close\r\n"
        for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified", "Cache-Control"] {
            if let value = http.value(forHTTPHeaderField: name), !value.contains("\r"), !value.contains("\n") { header += "\(name): \(value)\r\n" }
        }
        if client.chunked { header += "Transfer-Encoding: chunked\r\n" }
        enqueue(Data((header + "\r\n").utf8), client: client, framed: true)
        let prefix = client.prefix
        client.prefix.removeAll(keepingCapacity: false)
        if !prefix.isEmpty { enqueue(prefix, client: client, alreadyReserved: true) }
    }

    private func enqueue(_ data: Data, client: RelayClient, alreadyReserved: Bool = false, framed: Bool = false) {
        guard clients[client.id] != nil else { return }
        var output = data
        if client.chunked && !framed {
            let framing = Data("\(String(data.count, radix: 16))\r\n".utf8)
            output = framing; output.append(data); output.append(Data("\r\n".utf8))
            if alreadyReserved { release(data.count, client: client) }
            guard reserve(output.count, client: client) else { fail(MediaRelayError.resourceLimit); close(client); return }
        } else if !alreadyReserved, !reserve(output.count, client: client) {
            fail(MediaRelayError.resourceLimit); close(client); return
        }
        client.pending.append(RelayOutput(data: output, bodyBytes: framed ? 0 : data.count))
        if !client.suspended, !client.upstreamFinished { client.task?.suspend(); client.suspended = true }
        drain(client)
    }

    private func drain(_ client: RelayClient) {
        guard clients[client.id] != nil, !client.sending else { return }
        guard !client.pending.isEmpty else {
            if client.upstreamFinished {
                client.socket.send(content: client.chunked ? Data("0\r\n\r\n".utf8) : nil,
                                   contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self, weak client] error in
                    guard let self, let client else { return }
                    if error == nil, client.resource?.kind == .media { self.completedMediaResponses += 1 }
                    self.close(client)
                })
            } else if client.suspended { client.suspended = false; client.task?.resume() }
            return
        }
        client.sending = true
        let output = client.pending.removeFirst()
        client.socket.send(content: output.data, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client, self.clients[client.id] != nil else { return }
            client.sending = false
            self.release(output.data.count, client: client)
            if error != nil { self.close(client) }
            else { self.forwardedBodyBytes += Int64(output.bodyBytes); self.drain(client) }
        })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let client = client(for: task) else { return }
        if let error {
            // The callback caused by our explicit response rejection must not
            // replace its typed HTTP/trust error with generic cancellation.
            if (error as? URLError)?.code != .cancelled { fail(error) }
            close(client)
            return
        }
        client.upstreamFinished = true
        if client.resource?.kind == .playlist {
            do {
                guard let base = client.response?.url, let port else { throw MediaRelayError.invalidResponse }
                let body = try registry.rewrite(client.playlist, baseURL: base, port: port)
                release(client.playlist.count, client: client)
                client.playlist.removeAll(keepingCapacity: false)
                let header = Data("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
                enqueue(header, client: client, framed: true)
                if client.request?.method != "HEAD" { enqueue(body, client: client, framed: true) }
            } catch { fail(error); close(client) }
        } else {
            beginMedia(client)
            drain(client)
        }
    }

    private func respondFailure(_ client: RelayClient, status: Int) {
        guard clients[client.id] != nil else { return }
        client.upstreamFinished = true
        client.headersSent = true
        let status = (400...599).contains(status) ? status : 502
        enqueue(Data("HTTP/1.1 \(status) Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), client: client, framed: true)
    }
}

private final class RelayClient {
    let id = UUID()
    let socket: NWConnection
    var header = Data()
    var request: MediaRelayHTTPRequest?
    var resource: MediaRelayResource?
    var task: URLSessionDataTask?
    var response: HTTPURLResponse?
    var redirects = 0
    var prefix = Data()
    var playlist = Data()
    var pending: [RelayOutput] = []
    var retainedBytes = 0
    var sending = false
    var suspended = false
    var headersSent = false
    var chunked = false
    var upstreamFinished = false
    init(socket: NWConnection) { self.socket = socket }
}

private struct RelayOutput {
    let data: Data
    let bodyBytes: Int
}

struct MediaRelayMetrics: Sendable {
    let activeRequests: Int
    let waitingRequests: Int
    let acceptedConnections: Int
    let retainedBytes: Int
    let peakRetainedBytes: Int
    let peakStreamBytes: Int
    let registeredResources: Int
    let completedMediaResponses: Int
    let forwardedBodyBytes: Int64
}
