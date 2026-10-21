import Foundation
import VeltoretKit

// The HTTP layer Drive and Google sign-in use (the Windows app's HttpClient + handlers). A small protocol so tests
// can answer requests in memory; production goes through URLSession without following redirects (Drive's 308
// "Resume Incomplete" is not a redirect).

/// A network or Drive failure a retry may fix (the Windows app's IOException). `message` is shown to the user.
public struct DriveIOError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// A whole HTTP answer. Header names are lowercased.
public struct HttpResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, b in b })
        self.body = body
    }

    public init(status: Int, json: String) {
        self.init(status: status, headers: ["content-type": "application/json"], body: Data(json.utf8))
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
    public var text: String { String(decoding: body, as: UTF8.self) }
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// A response body read as it arrives (downloads, range reads).
public protocol HttpBodyStream: AnyObject, Sendable {
    /// Up to `max` bytes; empty at the end of the body.
    func read(max: Int) async throws -> Data
    func close()
}

/// An HTTP answer whose body is still arriving.
public struct HttpStreamResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: HttpBodyStream

    public init(status: Int, headers: [String: String] = [:], body: HttpBodyStream) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, b in b })
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public protocol HttpTransport: AnyObject, Sendable {
    /// Sends the request and reads the whole answer.
    func send(_ request: URLRequest) async throws -> HttpResponse
    /// Sends the request and returns as soon as the headers arrived. Default: `send` with the body in memory.
    func open(_ request: URLRequest) async throws -> HttpStreamResponse
}

public extension HttpTransport {
    func open(_ request: URLRequest) async throws -> HttpStreamResponse {
        let r = try await send(request)
        return HttpStreamResponse(status: r.status, headers: r.headers, body: DataBodyStream(r.body))
    }
}

/// A body already in memory.
public final class DataBodyStream: HttpBodyStream, @unchecked Sendable {
    private let data: Data
    private var pos = 0
    private let lock = NSLock()
    public init(_ data: Data) { self.data = data }
    public func read(max: Int) async throws -> Data {
        lock.withLock {
            let end = min(data.count, pos + max)
            let out = data.subdata(in: pos..<end)
            pos = end
            return out
        }
    }
    public func close() {}
}

/// Gives Drive calls a bearer token for an account (GoogleAuthService; fakes in tests).
public protocol TokenProvider: AnyObject, Sendable {
    func accessToken(_ email: String) async throws -> String
    /// Drops a token Google rejected (HTTP 401) so the next call fetches a fresh one.
    func invalidate(_ email: String)
}

// MARK: - URL helpers

public enum UrlEncoding {
    private static let unreserved: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s
    }()

    /// RFC 3986 escaping of everything but unreserved characters (C# Uri.EscapeDataString).
    public static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    /// application/x-www-form-urlencoded (spaces as '+').
    public static func form(_ pairs: [(String, String)]) -> Data {
        let text = pairs.map { k, v in
            escape(k).replacingOccurrences(of: "%20", with: "+") + "=" + escape(v).replacingOccurrences(of: "%20", with: "+")
        }.joined(separator: "&")
        return Data(text.utf8)
    }
}

// MARK: - Auth

/// Adds "Authorization: Bearer" for the account a Drive request is tagged with (`accountHeader`) and, on HTTP 401,
/// drops the token and re-sends exactly once with a fresh one (Android: DriveAuthInterceptor, Windows:
/// DriveAuthHandler). Requests without an account tag pass through untouched.
public final class DriveAuthTransport: HttpTransport, @unchecked Sendable {
    /// Internal tag naming the account; removed before the request leaves.
    public static let accountHeader = "X-Veltoret-Account"

    private let tokens: TokenProvider
    private let inner: HttpTransport

    public init(tokens: TokenProvider, inner: HttpTransport) {
        self.tokens = tokens
        self.inner = inner
    }

    public static func tag(_ request: inout URLRequest, account: String) {
        request.setValue(account, forHTTPHeaderField: accountHeader)
    }

    private func prepare(_ request: URLRequest) async throws -> (URLRequest, String?) {
        guard let email = request.value(forHTTPHeaderField: Self.accountHeader), !email.isEmpty else { return (request, nil) }
        var r = request
        r.setValue(nil, forHTTPHeaderField: Self.accountHeader)
        r.setValue("Bearer " + (try await tokens.accessToken(email)), forHTTPHeaderField: "Authorization")
        return (r, email)
    }

    public func send(_ request: URLRequest) async throws -> HttpResponse {
        var (r, email) = try await prepare(request)
        let response = try await inner.send(r)
        guard let email, response.status == 401 else { return response }
        tokens.invalidate(email)
        r.setValue("Bearer " + (try await tokens.accessToken(email)), forHTTPHeaderField: "Authorization")
        return try await inner.send(r)
    }

    public func open(_ request: URLRequest) async throws -> HttpStreamResponse {
        var (r, email) = try await prepare(request)
        let response = try await inner.open(r)
        guard let email, response.status == 401 else { return response }
        response.body.close()
        tokens.invalidate(email)
        r.setValue("Bearer " + (try await tokens.accessToken(email)), forHTTPHeaderField: "Authorization")
        return try await inner.open(r)
    }
}

// MARK: - URLSession

/// The production transport: URLSession that never follows redirects. `open` streams the body with
/// back-pressure (the task is suspended while more than 4 MB wait unread).
public final class URLSessionTransport: NSObject, HttpTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!

    public init(configuration: URLSessionConfiguration = URLSessionTransport.defaultConfiguration()) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 7 * 24 * 3600
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return c
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func headers(_ r: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in r.allHeaderFields {
            out[String(describing: k).lowercased()] = String(describing: v)
        }
        return out
    }

    public func send(_ request: URLRequest) async throws -> HttpResponse {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch let e as URLError {
            throw DriveIOError(e.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw DriveIOError("Not an HTTP answer") }
        return HttpResponse(status: http.statusCode, headers: Self.headers(http), body: data)
    }

    public func open(_ request: URLRequest) async throws -> HttpStreamResponse {
        let body = StreamingBody()
        let task = session.dataTask(with: request)
        task.delegate = body
        body.task = task
        let http = try await withTaskCancellationHandler {
            try await body.start()
        } onCancel: {
            task.cancel()
        }
        return HttpStreamResponse(status: http.statusCode, headers: Self.headers(http), body: body)
    }
}

/// A response body fed by a data task's delegate callbacks.
final class StreamingBody: NSObject, URLSessionDataDelegate, HttpBodyStream, @unchecked Sendable {
    private static let high = 4 * 1024 * 1024
    private static let low = 1024 * 1024

    weak var task: URLSessionDataTask?
    private let lock = NSLock()
    private var buffer = Data()
    /// Bytes of `buffer` already handed out.
    private var readOffset = 0
    private var finished = false
    private var failure: Error?
    private var suspended = false
    private var responseWaiter: CheckedContinuation<HTTPURLResponse, Error>?
    private var dataWaiter: CheckedContinuation<Void, Never>?

    func start() async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<HTTPURLResponse, Error>) in
            lock.lock(); responseWaiter = c; lock.unlock()
            task?.resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); let w = responseWaiter; responseWaiter = nil; lock.unlock()
        if let http = response as? HTTPURLResponse {
            w?.resume(returning: http)
        } else {
            w?.resume(throwing: DriveIOError("Not an HTTP answer"))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffer.append(data)
        if buffer.count - readOffset > Self.high && !suspended {
            suspended = true
            dataTask.suspend()
        }
        let w = dataWaiter; dataWaiter = nil
        lock.unlock()
        w?.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        finished = true
        if let error {
            if let u = error as? URLError, u.code == .cancelled { failure = CancellationError() }
            else if let u = error as? URLError { failure = DriveIOError(u.localizedDescription) }
            else { failure = error }
        }
        let rw = responseWaiter; responseWaiter = nil
        let dw = dataWaiter; dataWaiter = nil
        let f = failure
        lock.unlock()
        if let rw {
            if let f { rw.resume(throwing: f) } else { rw.resume(throwing: DriveIOError("No answer")) }
        }
        dw?.resume()
    }

    func read(max: Int) async throws -> Data {
        while true {
            if let out = try take(max) { return out }
            try Task.checkCancellation()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    if buffer.count > readOffset || finished {
                        lock.unlock()
                        c.resume()
                    } else {
                        dataWaiter = c
                        lock.unlock()
                    }
                }
            } onCancel: { [weak self] in
                self?.task?.cancel()
            }
        }
    }

    /// Buffered bytes, empty at the end, or nil when the caller has to wait.
    private func take(_ max: Int) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        let available = buffer.count - readOffset
        if available > 0 {
            let n = min(max, available)
            let out = buffer.subdata(in: readOffset..<(readOffset + n))
            readOffset += n
            if readOffset == buffer.count {
                buffer = Data(); readOffset = 0
            } else if readOffset > 1 << 20 {
                buffer = buffer.subdata(in: readOffset..<buffer.count); readOffset = 0
            }
            if suspended && buffer.count - readOffset < Self.low {
                suspended = false
                task?.resume()
            }
            return out
        }
        if finished {
            if let f = failure { throw f }
            return Data()
        }
        return nil
    }

    func close() {
        task?.cancel()
        lock.withLock { buffer = Data(); readOffset = 0 }
    }
}

// MARK: - Byte streams (upload input)

/// A forward-only byte stream (upload input: a local file, an inflating ZIP entry).
public protocol ByteStream: AnyObject {
    /// Up to `max` bytes; empty at the end.
    func read(max: Int) async throws -> Data
    func close()
}

public final class DataByteStream: ByteStream {
    private let data: Data
    private var pos = 0
    public init(_ data: Data) { self.data = data }
    public func read(max: Int) async throws -> Data {
        let end = min(data.count, pos + max)
        defer { pos = end }
        return data.subdata(in: pos..<end)
    }
    public func close() {}
}

public final class FileByteStream: ByteStream {
    private let handle: FileHandle
    public init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    public func read(max: Int) async throws -> Data { try handle.read(upToCount: max) ?? Data() }
    public func close() { try? handle.close() }
}

/// Serializes async work (one reader at a time; one token refresh at a time).
actor AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }

    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        await lock()
        defer { unlock() }
        return try await body()
    }
}

/// A counting semaphore for job slots.
actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ value: Int) { self.value = value }

    func wait() async {
        if value > 0 { value -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty { value += 1 } else { waiters.removeFirst().resume() }
    }
}
