import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct VoiceTestFailure: Error { let message: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw VoiceTestFailure(message: message) }
}

private final class VoiceFixtureProtocol: URLProtocol {
    static var status = 200
    static var payload = Data()
    static var requests = 0
    static var extraHeaders: [String: String] = [:]
    override class func canInit(with request: URLRequest) -> Bool { return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }
    override func startLoading() {
        Self.requests += 1
        let headers = ["Content-Type": "application/json"].merging(Self.extraHeaders, uniquingKeysWith: { _, new in new })
        let response = HTTPURLResponse(url: self.request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Self.payload)
        self.client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func requestContract() throws {
    let service = WhitegramVoiceRemoteService()
    let audio = Data([0x52, 0x49, 0x46, 0x46, 0, 1, 2, 3])
    let request = try service.conversionRequest(wav: audio, voiceId: "original_voice-1", key: "fixture-key", useProxy: false, boundary: "WhitegramBoundaryFixture")
    try require(request.url?.absoluteString == "https://api.elevenlabs.io/v1/speech-to-speech/original_voice-1?output_format=mp3_44100_128", "Original endpoint/output format drift")
    try require(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "xi-api-key") == "fixture-key", "Original method/auth header drift")
    try require(request.value(forHTTPHeaderField: "Accept") == "audio/mpeg", "Original audio MIME drift")
    let body = request.httpBody!
    try require(body.range(of: Data("name=\"model_id\"\r\n\r\neleven_multilingual_sts_v2\r\n".utf8)) != nil, "Original speech-to-speech model missing")
    try require(body.range(of: Data("name=\"file_format\"\r\n\r\nother\r\n".utf8)) != nil, "Original format field missing")
    try require(body.range(of: audio) != nil && body.suffix(30) == Data("--WhitegramBoundaryFixture--\r\n".utf8).suffix(30), "Multipart audio/final delimiter damaged")
    for id in ["", "../another", "a?x=b", "a/b", "a\r\nb", "голос"] {
        try require(!WhitegramVoiceRemoteService.isValidVoiceId(id), "Invalid voice identifier accepted")
    }
    do {
        _ = try service.makeRequest(path: "/v1/voices", method: "GET", key: "", useProxy: true, accept: "application/json")
        throw VoiceTestFailure(message: "An unconfigured proxy fell back to direct traffic")
    } catch WhitegramVoiceProcessingError.proxyUnavailable {}
    do {
        _ = try service.conversionRequest(wav: audio, voiceId: "voice", key: "a\nInjected: value", useProxy: false)
        throw VoiceTestFailure(message: "Header injection accepted")
    } catch WhitegramVoiceProcessingError.invalidCredential {}
    var captured: [String] = []
    let proxy = WhitegramVoiceRemoteService(proxyRequest: { path, method, key, accept in
        captured = [path, method, key ?? "", accept]
        var request = URLRequest(url: URL(string: "https://fixture.invalid/proxy")!)
        request.httpMethod = method
        return request
    })
    _ = try proxy.conversionRequest(wav: audio, voiceId: "voice", key: "", useProxy: true, boundary: "Fixture")
    try require(captured == ["/v1/speech-to-speech/voice?output_format=mp3_44100_128", "POST", "", "audio/mpeg"], "Proxy adapter lost provider request metadata")
}

private func transportAndCancellation() throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [VoiceFixtureProtocol.self]
    let service = WhitegramVoiceRemoteService(configuration: configuration)
    func voices(status: Int, json: String) throws -> Result<[WhitegramVoiceRemoteVoice], WhitegramVoiceProcessingError> {
        VoiceFixtureProtocol.status = status
        VoiceFixtureProtocol.payload = Data(json.utf8)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[WhitegramVoiceRemoteVoice], WhitegramVoiceProcessingError>?
        let task = WhitegramVoiceTask()
        service.voices(key: "fixture", useProxy: false, task: task) { result = $0; semaphore.signal() }
        defer { task.cancel() }
        try require(semaphore.wait(timeout: .now() + 5) == .success, "Fixture request did not complete")
        return result!
    }
    let values = try voices(status: 200, json: "{\"voices\":[{\"voice_id\":\"test_1\",\"name\":\"Test\",\"preview_url\":null}]}").get()
    try require(values.count == 1 && values[0].id == "test_1", "Voice list decoding failed")
    for status in [401, 403, 429, 500] {
        let result = try voices(status: status, json: "{\"error\":\"fixture\"}")
        guard case let .failure(.http(code)) = result, code == status else { throw VoiceTestFailure(message: "HTTP error was promoted to success") }
    }
    let duplicate = try voices(status: 200, json: "{\"voices\":[{\"voice_id\":\"same\",\"name\":\"A\"},{\"voice_id\":\"same\",\"name\":\"B\"}]}")
    guard case .failure(.invalidResponse) = duplicate else { throw VoiceTestFailure(message: "Duplicate voice identities accepted") }
    VoiceFixtureProtocol.extraHeaders = ["Content-Length": String(WhitegramVoiceHTTP.maximumBytes + 1)]
    let oversized = try voices(status: 200, json: "{\"voices\":[]}")
    VoiceFixtureProtocol.extraHeaders = [:]
    guard case .failure(.invalidResponse) = oversized else { throw VoiceTestFailure(message: "Oversized response was not rejected at headers") }
    let before = VoiceFixtureProtocol.requests
    let cancelled = WhitegramVoiceTask()
    var cancellations = 0
    cancelled.onCancel { cancellations += 1 }
    cancelled.cancel()
    cancelled.cancel()
    cancelled.onCancel { cancellations += 1 }
    try require(cancellations == 2, "Cancellation hooks did not run exactly once")
    let late = DispatchSemaphore(value: 0)
    service.voices(key: "fixture", useProxy: false, task: cancelled) { _ in late.signal() }
    try require(late.wait(timeout: .now() + 0.1) == .timedOut && VoiceFixtureProtocol.requests == before, "Cancelled operation sent a request or delivered a late result")
}

private func selectiveBleep() throws {
    let matcher = WhitegramVoiceProfanityMatcher()
    for word in ["FUCK!", "пиздец", "заебал", "х*й", "СУКА", "ёбаный"] {
        try require(matcher.matches(word), "Original profanity policy missed \(word)")
    }
    for word in ["hello", "политика", "страховать", "***", "", "123"] {
        try require(!matcher.matches(word), "Ordinary word was censored: \(word)")
    }
    let words = [WhitegramVoiceWord(text: "fuck", timestamp: 1, duration: 0.5), WhitegramVoiceWord(text: "shit", timestamp: 1.05, duration: 0.5), WhitegramVoiceWord(text: "hello", timestamp: 0, duration: 1)]
    let ranges = WhitegramVoiceSelectiveBleep.ranges(words: words, sampleRate: 48000, sampleCount: 96000, matcher: matcher)
    try require(ranges == [55200 ..< 66000], "Original 30%/35% audible-edge intervals or overlap merge changed")
    var silence = [Int16](repeating: 1200, count: 96000)
    WhitegramVoiceSelectiveBleep.apply(&silence, sampleRate: 48000, ranges: ranges, mode: .silence)
    try require(silence[55200 ..< 66000].allSatisfy { $0 == 0 }, "Selective silence leaked samples")
    try require(silence[0 ..< 55200].allSatisfy { $0 == 1200 } && silence[66000 ..< 96000].allSatisfy { $0 == 1200 }, "Bleep changed words outside its interval")
    var beep = [Int16](repeating: 1200, count: 96000)
    WhitegramVoiceSelectiveBleep.apply(&beep, sampleRate: 48000, ranges: ranges, mode: .beep)
    try require(beep[55200] == 0 && abs(Int(beep[55200 + 252]) - 9000) <= 1 && abs(Int(beep[55200 + 276]) + 9000) <= 1, "Original 1 kHz/9000-peak tone changed")
    let malformed = [WhitegramVoiceWord(text: "fuck", timestamp: .nan, duration: 1), WhitegramVoiceWord(text: "fuck", timestamp: -1, duration: 1), WhitegramVoiceWord(text: "fuck", timestamp: 3, duration: .infinity)]
    try require(WhitegramVoiceSelectiveBleep.ranges(words: malformed, sampleRate: 48000, sampleCount: 96000, matcher: matcher).isEmpty, "Malformed word timestamps were converted to PCM offsets")
}

private func dictionaryCacheAndCancellation() throws {
    let suite = "WhitegramVoiceTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WhitegramVoiceProfanityStore(defaults: defaults)
    try require(store.matcher().matches("fuck"), "Bundled original roots missing without backend")
    try store.update(data: Data("{\"roots\":[\" BadRoot \"],\"prefixes\":[\"pre\"]}".utf8))
    try require(store.matcher().matches("prebadrooted") && !store.matcher().matches("hello"), "Server dictionary was not normalized or cached")
    let previous = defaults.stringArray(forKey: "wg_profanityRoots_v2")
    do {
        try store.update(data: Data("{\"roots\":[]}".utf8))
        throw VoiceTestFailure(message: "Empty remote dictionary replaced the last valid roots")
    } catch WhitegramVoiceProcessingError.invalidResponse {}
    try require(defaults.stringArray(forKey: "wg_profanityRoots_v2") == previous, "Failed dictionary update changed cache")
    var loads = 0
    store.configure { completion in
        loads += 1
        completion(.success(Data("{\"roots\":[\"refresh\"]}".utf8)))
        return WhitegramVoiceTask()
    }
    let task = WhitegramVoiceTask()
    var completed = false
    store.ensureLoaded(task: task) { completed = $0.matches("badroot") }
    try require(completed && loads == 0, "Fresh 24-hour cache unnecessarily contacted backend")
    defaults.set(0, forKey: "wg_profanityRootsUpdatedAt_v2")
    completed = false
    store.ensureLoaded(task: task) { completed = $0.matches("refresh") }
    try require(completed && loads == 1, "Stale dictionary did not refresh")
    task.cancel()
    let cancelled = WhitegramVoiceTask()
    cancelled.cancel()
    store.ensureLoaded(task: cancelled) { _ in completed = false }
    try require(completed && loads == 1, "Cancelled dictionary request delivered a callback")
}

@main
private struct WhitegramVoiceProtocolTests {
    static func main() throws {
        try requestContract()
        print("PASS: original direct/proxy request contract")
        try transportAndCancellation()
        print("PASS: fixture HTTP, decoding and cancellation")
        try selectiveBleep()
        print("PASS: original profanity intervals and selective PCM masking")
        try dictionaryCacheAndCancellation()
        print("PASS: original dictionary persistence, freshness and cancellation")
    }
}
