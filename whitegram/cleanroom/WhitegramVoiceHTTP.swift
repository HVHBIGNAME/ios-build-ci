import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLSession serializes delegate callbacks. Cancellation only calls its
/// thread-safe invalidateAndCancel; payload/completion stay on that queue.
final class WhitegramVoiceHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maximumBytes = 64 * 1024 * 1024
    private let task: WhitegramVoiceTask
    private var session: URLSession!
    private var bytes = Data()
    private var completion: ((Result<Data, WhitegramVoiceProcessingError>) -> Void)?

    init(request: URLRequest, configuration: URLSessionConfiguration, task: WhitegramVoiceTask, completion: @escaping (Result<Data, WhitegramVoiceProcessingError>) -> Void) {
        self.task = task
        self.completion = completion
        super.init()
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let requestTask = self.session.dataTask(with: request)
        task.onCancel { [weak self] in self?.session.invalidateAndCancel() }
        if task.isCancelled { self.session.invalidateAndCancel() }
        else { requestTask.resume() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !self.task.isCancelled, self.completion != nil else { completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            self.finish(.failure(.invalidResponse))
            return
        }
        guard (200 ... 299).contains(response.statusCode) else {
            completionHandler(.cancel)
            self.finish(.failure(.http(response.statusCode)))
            return
        }
        guard response.expectedContentLength <= Int64(Self.maximumBytes) else {
            completionHandler(.cancel)
            self.finish(.failure(.invalidResponse))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !self.task.isCancelled, self.completion != nil else { dataTask.cancel(); return }
        guard data.count <= Self.maximumBytes - self.bytes.count else {
            self.bytes.removeAll()
            self.finish(.failure(.invalidResponse))
            dataTask.cancel()
            return
        }
        self.bytes.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { self.finish(.failure(.transport(error))) }
        else if self.bytes.isEmpty { self.finish(.failure(.invalidResponse)) }
        else { self.finish(.success(self.bytes)) }
    }

    private func finish(_ result: Result<Data, WhitegramVoiceProcessingError>) {
        let completion = self.completion
        self.completion = nil
        self.session.finishTasksAndInvalidate()
        if !self.task.isCancelled { completion?(result) }
    }
}
