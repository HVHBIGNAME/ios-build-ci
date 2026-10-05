import Foundation
import UIKit
import AccountContext
import Display
import ItemListUI
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData

protocol WhitegramServiceListActions: AnyObject {
    func perform(_ id: String)
    func setEnabled(_ enabled: Bool)
}

struct WhitegramServiceEntry: ItemListNodeEntry {
    enum Content: Equatable {
        case toggle(String, Bool, Bool)
        case disclosure(String, String, Bool)
        case action(String, Bool)
        case text(String)
        case header(String)
    }

    let stableId: String
    let order: Int
    let section: ItemListSectionId
    let content: Content

    static func < (lhs: WhitegramServiceEntry, rhs: WhitegramServiceEntry) -> Bool { return lhs.order < rhs.order }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let actions = arguments as! WhitegramServiceListActions
        switch self.content {
        case let .toggle(title, value, enabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value,
                enabled: enabled, sectionId: self.section, style: .blocks, updated: { actions.setEnabled($0) })
        case let .disclosure(title, label, enabled):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, enabled: enabled,
                label: label, sectionId: self.section, style: .blocks, action: { if enabled { actions.perform(self.stableId) } })
        case let .action(title, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title,
                kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: self.section, style: .blocks,
                action: { if enabled { actions.perform(self.stableId) } })
        case let .text(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        }
    }
}

func whitegramServiceListController(context: AccountContext, title: String, entries: Signal<[WhitegramServiceEntry], NoError>, actions: WhitegramServiceListActions, titleKey: String? = nil) -> ItemListController {
    let localization = Signal<Bool, NoError> { subscriber in
        let observer = NotificationCenter.default.addObserver(forName: WhitegramLocalizationStore.changedNotification, object: nil, queue: .main) { _ in subscriber.putNext(true) }
        subscriber.putNext(true)
        return ActionDisposable { NotificationCenter.default.removeObserver(observer) }
    }
    let signal = combineLatest(context.sharedContext.presentationData, entries, localization)
    |> deliverOnMainQueue
    |> map { presentationData, entries, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let data = ItemListPresentationData(presentationData)
        let title = titleKey.map { WhitegramLocalization.string($0, baseLanguage: presentationData.strings.baseLanguageCode) } ?? title
        let controllerState = ItemListControllerState(presentationData: data, title: .text(title), leftNavigationButton: nil,
            rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        return (controllerState, (ItemListNodeState(presentationData: data, entries: entries, style: .blocks, animateChanges: false), actions))
    }
    return ItemListController(context: context, state: signal)
}

func whitegramServiceCopy(_ text: String) {
    UIPasteboard.general.setItems([["public.utf8-plain-text": text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(3600)])
}

func whitegramServiceDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

func whitegramServiceObserve(_ name: Notification.Name, action: @escaping (Notification) -> Void) -> NSObjectProtocol {
    // Never block a background credential migration waiting for a main-queue observer that reads the vault.
    return NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { notification in
        if Thread.isMainThread {
            action(notification)
        } else {
            DispatchQueue.main.async { action(notification) }
        }
    }
}

final class WhitegramServiceProxyConnection {
    let account: WhitegramAccountServices
    private let authentication: WhitegramBackendAuthentication
    private var task: WhitegramBackendTask?
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var error: WhitegramBackendError?
    private(set) var isConnecting = false
    var changed: (() -> Void)?

    init(context: AccountContext) {
        self.account = WhitegramAccountServices(userId: context.account.peerId.id._internalGetInt64Value())
        self.authentication = WhitegramBackendAuthentication(context: context)
        for name in [whitegramBackendSessionUpdated, whitegramBackendAccessUpdated] {
            self.observers.append(whitegramServiceObserve(name) { [weak self] notification in
                guard let self, notification.userInfo?["userId"] as? Int64 == self.account.backend.userId else { return }
                self.error = nil
                self.changed?()
            })
        }
    }

    deinit {
        self.task?.cancel()
        self.observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    var status: String {
        if self.isConnecting { return "Connecting this Telegram account to Whitegram…" }
        if let error { return error.localizedDescription }
        do {
            guard try self.account.backend.hasSession() else { return WhitegramServiceError.originalProxyUnavailable.localizedDescription }
            switch self.account.backend.accessState {
            case .allowed: return "Whitegram proxy access verified for Telegram user \(self.account.backend.userId)."
            case .denied: return WhitegramServiceError.originalProxyAccessDenied.localizedDescription
            case .unknown: return WhitegramServiceError.originalProxyAccessUnverified.localizedDescription
            }
        } catch { return error.localizedDescription }
    }

    func connect() {
        guard !self.isConnecting else { return }
        self.generation += 1
        let generation = self.generation
        self.isConnecting = true
        self.error = nil
        self.changed?()
        let completed: (Result<Void, WhitegramBackendError>) -> Void = { [weak self] result in
            guard let self, generation == self.generation else { return }
            self.task = nil
            self.isConnecting = false
            if case let .failure(error) = result { self.error = error }
            self.changed?()
        }
        do {
            if try self.account.backend.hasSession() {
                self.task = self.account.backend.refreshAccess { result in
                    completed(result.flatMap { $0 == .allowed ? .success(Void()) : .failure(.betaAccessDenied) })
                }
            } else {
                self.authentication.connect(completion: completed)
            }
        } catch { completed(.failure(error as? WhitegramBackendError ?? .invalidResponse)) }
    }

    func cancel() {
        self.generation += 1
        self.authentication.cancel()
        self.task?.cancel()
        self.task = nil
        self.isConnecting = false
    }
}

/// Retained by the settings coordinator; UIKit's delegate references are weak.
final class WhitegramServicePresenter: NSObject, UIAdaptivePresentationControllerDelegate {
    weak var controller: ItemListController?
    var changed: (() -> Void)?
    private(set) var nativeController: UIViewController?
    var isPresenting: Bool { return self.nativeController != nil }

    deinit {
        if let nativeController = self.nativeController {
            DispatchQueue.main.async { nativeController.dismiss(animated: false, completion: nil) }
        }
    }

    @discardableResult
    func present(_ nativeController: UIViewController) -> Bool {
        guard self.nativeController == nil, var presenter = self.controller?.viewIfLoaded?.window?.rootViewController else { return false }
        while let next = presenter.presentedViewController { presenter = next }
        guard !presenter.isBeingDismissed, !presenter.isBeingPresented else { return false }
        self.nativeController = nativeController
        presenter.present(nativeController, animated: true, completion: nil)
        nativeController.presentationController?.delegate = self
        self.changed?()
        return true
    }

    func close() {
        let native = self.nativeController
        self.nativeController = nil
        if let alert = native as? UIAlertController {
            alert.textFields?.forEach { $0.text = nil }
        }
        native?.dismiss(animated: true, completion: nil)
        self.changed?()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard self.nativeController === presentationController.presentedViewController else { return }
        self.nativeController = nil
        self.changed?()
    }

    @discardableResult
    func editValue(title: String, message: String, value: String = "", placeholder: String, secure: Bool = false, saved: @escaping (String) -> Void) -> Bool {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = secure ? "" : value
            field.placeholder = placeholder
            field.isSecureTextEntry = secure
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.spellCheckingType = .no
            field.keyboardType = .asciiCapable
            field.textContentType = nil
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { [weak self] _ in self?.close() }))
        alert.addAction(UIAlertAction(title: "Save", style: .default, handler: { [weak self, weak alert] _ in
            let text = alert?.textFields?.first?.text ?? ""
            alert?.textFields?.first?.text = nil
            self?.close()
            saved(text)
        }))
        return self.present(alert)
    }

    @discardableResult
    func showText(title: String, text: String, editable: Bool = false, saved: ((String) -> Void)? = nil) -> Bool {
        let editor = WhitegramServiceTextController(title: title, text: text, editable: editable, saved: { [weak self] text in
            self?.close()
            saved?(text)
        }, closed: { [weak self] in self?.close() })
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .formSheet
        return self.present(navigation)
    }
}

private final class WhitegramServiceTextController: UIViewController, UITextViewDelegate {
    private let textView = UITextView()
    private let footer = UILabel()
    private let initialText: String
    private let editable: Bool
    private let saved: (String) -> Void
    private let closed: () -> Void
    private var keyboardObserver: NSObjectProtocol?
    private var bottomConstraint: NSLayoutConstraint?

    init(title: String, text: String, editable: Bool, saved: @escaping (String) -> Void, closed: @escaping () -> Void) {
        self.initialText = text
        self.editable = editable
        self.saved = saved
        self.closed = closed
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer = self.keyboardObserver { NotificationCenter.default.removeObserver(observer) } }

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 13.0, *) {
            self.view.backgroundColor = .systemBackground
            self.textView.textColor = .label
        } else {
            self.view.backgroundColor = .white
            self.textView.textColor = .black
        }
        self.textView.backgroundColor = .clear
        self.textView.text = self.initialText
        self.textView.isEditable = self.editable
        self.textView.isSelectable = true
        self.textView.dataDetectorTypes = []
        self.textView.delegate = self
        self.textView.font = UIFont.preferredFont(forTextStyle: .body)
        self.textView.adjustsFontForContentSizeCategory = true
        self.textView.alwaysBounceVertical = true
        self.footer.font = UIFont.preferredFont(forTextStyle: .footnote)
        self.footer.adjustsFontForContentSizeCategory = true
        self.footer.numberOfLines = 0
        self.footer.textColor = .gray
        self.textView.translatesAutoresizingMaskIntoConstraints = false
        self.footer.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(self.textView)
        self.view.addSubview(self.footer)
        let safe = self.view.safeAreaLayoutGuide
        let bottom = self.footer.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12)
        self.bottomConstraint = bottom
        NSLayoutConstraint.activate([
            self.textView.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            self.textView.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            self.textView.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            self.textView.bottomAnchor.constraint(equalTo: self.footer.topAnchor, constant: -8),
            self.footer.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            self.footer.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16), bottom
        ])
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: self.editable ? "Cancel" : "Done", style: .plain, target: self, action: #selector(self.closePressed))
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: self.editable ? "Use Text" : "Copy", style: .plain, target: self, action: #selector(self.actionPressed))
        self.updateFooter()
        self.keyboardObserver = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self, let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
            let local = self.view.convert(frame.cgRectValue, from: nil)
            let overlap = self.view.bounds.intersects(local) ? max(0, self.view.bounds.maxY - local.minY - self.view.safeAreaInsets.bottom) : 0
            self.bottomConstraint?.constant = -12 - overlap
            self.view.layoutIfNeeded()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if self.editable { self.textView.becomeFirstResponder() }
    }

    private func updateFooter() {
        if self.editable {
            let bytes = self.textView.text.utf8.count
            self.footer.text = "\(bytes) / \(WhitegramServiceLimits.maximumPromptBytes) UTF-8 bytes. Tap Send Prompt on the settings screen to submit this text."
            self.navigationItem.rightBarButtonItem?.isEnabled = bytes <= WhitegramServiceLimits.maximumPromptBytes
        } else {
            self.footer.text = "Plain text. Select text or tap Copy."
        }
    }

    func textViewDidChange(_ textView: UITextView) { self.updateFooter() }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard let range = Range(range, in: textView.text) else { return false }
        let bytes = textView.text.replacingCharacters(in: range, with: text).utf8.count
        return bytes <= WhitegramServiceLimits.maximumPromptBytes || bytes < textView.text.utf8.count
    }

    @objc private func closePressed() { self.view.endEditing(true); self.closed() }

    @objc private func actionPressed() {
        if self.editable {
            guard self.textView.text.utf8.count <= WhitegramServiceLimits.maximumPromptBytes else { return }
            self.view.endEditing(true)
            self.saved(self.textView.text)
        } else {
            whitegramServiceCopy(self.textView.text)
            self.footer.text = "Copied to this device's clipboard for one hour."
        }
    }
}
