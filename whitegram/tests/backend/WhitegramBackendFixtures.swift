import Foundation
@testable import WhitegramBackendHost

final class BackendMemorySessions: WhitegramBackendSessionStorage {
    var values: [Int64: WhitegramBackendSession] = [:]
    var removals = 0
    var saveError: WhitegramBackendError?
    func load(userId: Int64) throws -> WhitegramBackendSession? { return values[userId] }
    func save(_ session: WhitegramBackendSession) throws {
        if let saveError { throw saveError }
        values[session.userId] = session
    }
    func remove(userId: Int64) throws { values.removeValue(forKey: userId); removals += 1 }
    func remove(userId: Int64, matching session: WhitegramBackendSession) throws -> Bool {
        guard values[userId] == session else { return false }
        try remove(userId: userId)
        return true
    }
}

final class BackendFakeTask: WhitegramBackendTask {
    private(set) var cancelled = false
    func cancel() { cancelled = true }
}

final class BackendFakeHTTP: WhitegramBackendHTTP {
    struct Call {
        let request: URLRequest
        let transfer: WhitegramBackendTransfer
        let task: BackendFakeTask
        let completion: (Result<WhitegramBackendHTTPResponse, WhitegramBackendError>) -> Void
    }
    var calls: [Call] = []
    func execute(_ request: URLRequest, maximumBytes: Int, transfer: WhitegramBackendTransfer,
                 completion: @escaping (Result<WhitegramBackendHTTPResponse, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        let task = BackendFakeTask()
        calls.append(Call(request: request, transfer: transfer, task: task, completion: completion))
        return task
    }
    func respond(_ index: Int, status: Int = 200, data: Data = Data(), headers: [String: String] = [:]) {
        let call = calls[index]
        call.completion(.success(WhitegramBackendHTTPResponse(data: data,
            response: HTTPURLResponse(url: call.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, duration: 0.2)))
    }
}

final class BackendFixture {
    static let applicationKey = Data(32..<64)
    var date = Date(timeIntervalSince1970: 1_700_000_000)
    let sessions = BackendMemorySessions()
    let access = WhitegramBackendAccessStore()
    let http = BackendFakeHTTP()
    lazy var client = WhitegramBackendClient(userId: 42, sessions: sessions, http: http, now: { self.date },
        access: access, recordUsage: { _ in }, applicationKey: { BackendFixture.applicationKey }, deviceSignature: { "synthetic-device-signature:" + $0 })

    init(allowed: Bool? = true) {
        sessions.values[42] = session(token: "synthetic-token")
        if let allowed { grantFixtureAccess(allowed: allowed) }
    }

    func session(token: String) -> WhitegramBackendSession {
        return WhitegramBackendSession(userId: 42, token: token, expiresAt: date.addingTimeInterval(3600), sessionKey: Data(0..<32))
    }

    // A test-only injected store. Production accepts grants exclusively through the signed-verdict validator.
    func grantFixtureAccess(allowed: Bool = true) {
        let verdict = WhitegramBackendAccessVerdict(userId: 42, allowed: allowed, issuedAt: Int64(date.timeIntervalSince1970),
            expiresAt: Int64(date.timeIntervalSince1970) + 600, nonce: String(repeating: "0", count: 32), signature: "fixture-only")
        try! access.finish(userId: 42, generation: access.begin(userId: 42), verdict: verdict, now: date)
    }
}

final class BackendNoNetworkProtocol: URLProtocol {
    static var handler: ((BackendNoNetworkProtocol) -> Void)?
    static var stopped: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }
    override func startLoading() {
        if let handler = Self.handler { handler(self) }
        else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    }
    override func stopLoading() { Self.stopped?() }

    func respond(status: Int, chunks: [Data], headers: [String: String] = [:], finish: Bool = true) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for data in chunks { client?.urlProtocol(self, didLoad: data) }
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }

    static func configuration() -> URLSessionConfiguration {
        let result = URLSessionConfiguration.ephemeral
        result.protocolClasses = [BackendNoNetworkProtocol.self]
        return result
    }
}
