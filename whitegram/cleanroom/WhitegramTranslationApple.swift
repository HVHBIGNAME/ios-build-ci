import Foundation
import UIKit
import SwiftUI
import Translation
import NaturalLanguage
import SwiftSignalKit
import AccountContext
import TelegramCore

func whitegramAppleTranslate(context: AccountContext, texts: [String], fromLang: String?, toLang: String) -> Signal<[String], WhitegramTranslationFailure> {
    guard #available(iOS 18.0, *) else { return .fail(.localUnavailable) }
    return Signal { subscriber in
        let id = UUID()
        let cancelled = Atomic(value: false)
        DispatchQueue.main.async {
            guard !cancelled.with({ $0 }) else { return }
            guard let view = context.sharedContext.mainWindow?.hostView.containerView else { subscriber.putError(.localUnavailable); return }
            WhitegramAppleTranslationQueue.shared.enqueue(id: id, texts: texts, fromLang: fromLang, toLang: toLang, in: view) { result in
                guard !cancelled.with({ $0 }) else { return }
                switch result {
                case let .success(texts): subscriber.putNext(texts); subscriber.putCompletion()
                case let .failure(error): subscriber.putError(error)
                }
            }
        }
        return ActionDisposable {
            _ = cancelled.swap(true)
            DispatchQueue.main.async { WhitegramAppleTranslationQueue.shared.cancel(id) }
        }
    }
}

@available(iOS 18.0, *)
@MainActor
private final class WhitegramAppleTranslationQueue {
    static let shared = WhitegramAppleTranslationQueue()
    private var requests: [WhitegramAppleTranslationRequest] = []
    private var active: WhitegramAppleTranslationRequest?
    private var host: UIHostingController<WhitegramAppleTranslationView>?
    private var backgroundObserver: NSObjectProtocol?

    private init() {
        self.backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.cancelAll() }
        }
    }

    func enqueue(id: UUID, texts: [String], fromLang: String?, toLang: String, in view: UIView, completion: @escaping (Result<[String], WhitegramTranslationFailure>) -> Void) {
        guard self.requests.count < 32, !texts.isEmpty, texts.count <= 513,
              texts.allSatisfy({ WhitegramTranslationTextRules.hasText($0) }) else { completion(.failure(.localUnavailable)); return }
        let source = fromLang.flatMap { $0.isEmpty || $0 == "auto" ? nil : $0 } ?? NLLanguageRecognizer.dominantLanguage(for: texts.joined(separator: "\n"))?.rawValue
        guard let source else { completion(.failure(.localUnavailable)); return }
        if source.lowercased() == toLang.lowercased() { completion(.success(texts)); return }
        let request = WhitegramAppleTranslationRequest(id: id, texts: texts, source: source, target: toLang, view: view, completion: completion)
        self.requests.append(request)
        self.pump()
    }

    private func pump() {
        guard self.active == nil, !self.requests.isEmpty else { return }
        let request = self.requests.removeFirst()
        guard let view = request.container, view.window != nil else {
            request.completion(.failure(.localUnavailable))
            self.pump()
            return
        }
        self.active = request
        request.finished = { [weak self] result in self?.finish(request.id, result: result) }
        let host = UIHostingController(rootView: WhitegramAppleTranslationView(request: request))
        self.host = host
        host.view.backgroundColor = .clear
        host.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        var responder: UIResponder? = view
        while let next = responder, !(next is UIViewController) { responder = next.next }
        let parent = responder as? UIViewController
        parent?.addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: parent)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self, weak request] in
            guard let request, self?.active?.id == request.id else { return }
            self?.finish(request.id, result: .failure(.timedOut))
        }
    }

    private func detachHost() {
        self.host?.willMove(toParent: nil)
        self.host?.view.removeFromSuperview()
        self.host?.removeFromParent()
        self.host = nil
    }

    private func finish(_ id: UUID, result: Result<[String], WhitegramTranslationFailure>) {
        guard let active = self.active, active.id == id else { return }
        self.active = nil
        active.finished = nil
        self.detachHost()
        active.completion(result)
        DispatchQueue.main.async { self.pump() }
    }

    func cancel(_ id: UUID) {
        self.requests.removeAll(where: { $0.id == id })
        if self.active?.id == id {
            self.active?.finished = nil
            self.active = nil
            self.detachHost()
            self.pump()
        }
    }

    private func cancelAll() {
        let requests = self.requests
        self.requests.removeAll()
        for request in requests { request.completion(.failure(.localUnavailable)) }
        if let id = self.active?.id { self.finish(id, result: .failure(.localUnavailable)) }
    }
}

@available(iOS 18.0, *)
@MainActor
private final class WhitegramAppleTranslationRequest {
    let id: UUID
    let texts: [String]
    let source: Locale.Language
    let target: Locale.Language
    weak var container: UIView?
    let completion: (Result<[String], WhitegramTranslationFailure>) -> Void
    var finished: ((Result<[String], WhitegramTranslationFailure>) -> Void)?

    init(id: UUID, texts: [String], source: String, target: String, view: UIView, completion: @escaping (Result<[String], WhitegramTranslationFailure>) -> Void) {
        self.id = id
        self.texts = texts
        self.source = Locale.Language(identifier: source)
        self.target = Locale.Language(identifier: target)
        self.container = view
        self.completion = completion
    }

    func run(_ session: TranslationSession) async {
        let availability = await LanguageAvailability().status(from: self.source, to: self.target)
        guard !Task.isCancelled, self.finished != nil else { return }
        switch availability {
        case .installed, .supported: break
        case .unsupported: self.finished?(.failure(.localUnavailable)); return
        @unknown default: self.finished?(.failure(.localUnavailable)); return
        }
        do {
            // Supported languages can require the system's explicit download permission.
            try await session.prepareTranslation()
            guard !Task.isCancelled, self.finished != nil else { return }
            let requests = self.texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
            let responses = try await session.translations(from: requests)
            guard !Task.isCancelled, self.finished != nil else { return }
            var indexed: [Int: String] = [:]
            for response in responses {
                guard let clientId = response.clientIdentifier, let index = Int(clientId), self.texts.indices.contains(index), indexed[index] == nil else {
                    self.finished?(.failure(.emptyResult)); return
                }
                indexed[index] = response.targetText
            }
            guard indexed.count == self.texts.count else { self.finished?(.failure(.emptyResult)); return }
            self.finished?(.success(self.texts.indices.map { indexed[$0]! }))
        } catch {
            if !Task.isCancelled { self.finished?(.failure(.localUnavailable)) }
        }
    }
}

@available(iOS 18.0, *)
@MainActor
private struct WhitegramAppleTranslationView: View {
    let request: WhitegramAppleTranslationRequest

    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .translationTask(TranslationSession.Configuration(source: self.request.source, target: self.request.target)) { session in
                await self.request.run(session)
            }
    }
}
