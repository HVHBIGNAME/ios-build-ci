import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class WhitegramDiagnosticsUpload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var responseData = Data()
    private var status = 0
    private let reportId: UUID
    private var completion: ((Bool, Int) -> Void)?

    init(request: URLRequest, reportId: UUID, configuration: URLSessionConfiguration = .ephemeral, completion: @escaping (Bool, Int) -> Void) {
        self.reportId = reportId
        self.completion = completion
        super.init()
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        session.dataTask(with: request).resume()
    }

    func cancel() {
        self.lock.lock()
        let session = self.session
        self.lock.unlock()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(response.expectedContentLength > 4096 ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= 4096 - self.responseData.count else { self.cancel(); return }
        self.responseData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let receipt = (try? JSONSerialization.jsonObject(with: self.responseData)) as? [String: Any]
        let accepted = error == nil && (200..<300).contains(self.status) && (receipt?["accepted"] as? Bool) == true && (receipt?["id"] as? String) == self.reportId.uuidString
        let completion = self.completion
        self.completion = nil
        session.finishTasksAndInvalidate()
        completion?(accepted, (error as NSError?)?.code ?? self.status)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        self.lock.lock()
        self.session = nil
        self.lock.unlock()
        if let completion = self.completion {
            self.completion = nil
            completion(false, (error as NSError?)?.code ?? NSURLErrorCancelled)
        }
    }
}
