import UIKit

final class WhitegramProfileTextEditor: UIViewController, UITextViewDelegate {
    private let input = UITextView()
    private let countLabel = UILabel()
    private let initialText: String
    private let maximumLength: Int
    private let message: String
    private let saved: (String) -> Void
    private let cancelled: () -> Void
    private var bottom: NSLayoutConstraint?
    private var observer: NSObjectProtocol?

    init(title: String, text: String, maximumLength: Int, message: String, saved: @escaping (String) -> Void, cancelled: @escaping () -> Void) {
        self.initialText = text
        self.maximumLength = maximumLength
        self.message = message
        self.saved = saved
        self.cancelled = cancelled
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        input.font = .preferredFont(forTextStyle: .body)
        input.adjustsFontForContentSizeCategory = true
        input.delegate = self
        input.text = initialText
        input.alwaysBounceVertical = true
        countLabel.font = .preferredFont(forTextStyle: .footnote)
        countLabel.numberOfLines = 0
        countLabel.textColor = .secondaryLabel
        for subview in [input, countLabel] { subview.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(subview) }
        let bottom = countLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        self.bottom = bottom
        NSLayoutConstraint.activate([
            input.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            input.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            input.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            input.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -12),
            countLabel.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            countLabel.trailingAnchor.constraint(equalTo: input.trailingAnchor), bottom
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(save))
        observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let local = view.convert(frame, from: nil)
            let overlap = view.bounds.intersection(local).height
            bottom.constant = -12 - max(0, overlap - view.safeAreaInsets.bottom)
            view.layoutIfNeeded()
        }
        updateCount()
    }

    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); input.becomeFirstResponder() }
    func textViewDidChange(_ textView: UITextView) { updateCount() }
    private func updateCount() {
        countLabel.text = "\(input.text.count) / \(maximumLength)\n" + message
        navigationItem.rightBarButtonItem?.isEnabled = input.text.count <= maximumLength
    }
    @objc private func cancel() { view.endEditing(true); cancelled() }
    @objc private func save() {
        guard input.text.count <= maximumLength else { return }
        view.endEditing(true)
        saved(input.text)
    }
}
