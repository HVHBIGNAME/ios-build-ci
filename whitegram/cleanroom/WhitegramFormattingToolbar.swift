import Foundation
import UIKit
import TelegramCore
import TelegramPresentationData
import GlassBackgroundComponent
import ComponentFlow

enum WhitegramFormattingAction: Int, CaseIterable {
    case clear, selectAll, speak, bold, italic, strike, monospace, underline, spoiler, link, quote, collapsedQuote, codeBlock, clearFormatting, undo, redo

    var symbol: String {
        switch self {
        case .clear: return "trash"
        case .selectAll: return "selection.pin.in.out"
        case .speak: return "megaphone"
        case .bold: return "bold"
        case .italic: return "italic"
        case .strike: return "strikethrough"
        case .monospace: return "chevron.left.forwardslash.chevron.right"
        case .underline: return "underline"
        case .spoiler: return "eye.slash"
        case .link: return "link"
        case .quote: return "text.quote"
        case .collapsedQuote: return "rectangle.compress.vertical"
        case .codeBlock: return "curlybraces.square"
        case .clearFormatting: return "textformat"
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        }
    }

    var fallbackTitle: String {
        switch self {
        case .clear: return "×"
        case .selectAll: return "All"
        case .speak: return "▶"
        case .bold: return "B"
        case .italic: return "I"
        case .strike: return "S̶"
        case .monospace: return "</>"
        case .underline: return "U̲"
        case .spoiler: return "•••"
        case .link: return "↗"
        case .quote: return "❞"
        case .collapsedQuote: return "❞…"
        case .codeBlock: return "{}"
        case .clearFormatting: return "Tx"
        case .undo: return "↶"
        case .redo: return "↷"
        }
    }

    func title(strings: PresentationStrings) -> String {
        switch self {
        case .clear: return strings.Common_Delete
        case .selectAll: return strings.TextSelection_SelectAll
        case .speak: return strings.Conversation_ContextMenuSpeak
        case .bold: return strings.TextFormat_Bold
        case .italic: return strings.TextFormat_Italic
        case .strike: return strings.TextFormat_Strikethrough
        case .monospace: return strings.TextFormat_Monospace
        case .underline: return strings.TextFormat_Underline
        case .spoiler: return strings.TextFormat_Spoiler
        case .link: return strings.TextFormat_Link
        case .quote: return strings.TextFormat_Quote
        case .codeBlock: return strings.TextFormat_Code
        case .collapsedQuote: return WhitegramComposerStrings.string("composer.collapsedQuote", baseLanguage: strings.baseLanguageCode)
        case .clearFormatting: return WhitegramComposerStrings.string("composer.clearFormatting", baseLanguage: strings.baseLanguageCode)
        case .undo: return WhitegramComposerStrings.string("composer.undo", baseLanguage: strings.baseLanguageCode)
        case .redo: return WhitegramComposerStrings.string("composer.redo", baseLanguage: strings.baseLanguageCode)
        }
    }
}

private final class WhitegramFormattingButton: UIButton {
    let glass = GlassBackgroundView(frame: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.glass.isUserInteractionEnabled = false
        self.insertSubview(self.glass, at: 0)
        self.layer.cornerRadius = 16.0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.15, delay: 0.0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.9, y: 0.9) : .identity
            })
        }
    }
}

final class WhitegramFormattingToolbar: UIView {
    var action: ((WhitegramFormattingAction) -> Void)?
    private let scrollView = UIScrollView()
    private var buttons: [WhitegramFormattingButton] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.scrollView.showsHorizontalScrollIndicator = false
        self.scrollView.alwaysBounceHorizontal = true
        self.scrollView.delaysContentTouches = false
        self.addSubview(self.scrollView)
        for action in WhitegramFormattingAction.allCases {
            let button = WhitegramFormattingButton(frame: .zero)
            button.tag = action.rawValue
            if let image = UIImage(systemName: action.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .medium)) {
                button.setImage(image, for: .normal)
            } else {
                button.setTitle(action.fallbackTitle, for: .normal)
                button.titleLabel?.font = UIFont.systemFont(ofSize: 15.0, weight: .medium)
            }
            button.addTarget(self, action: #selector(self.pressed(_:)), for: .touchUpInside)
            self.scrollView.addSubview(button)
            self.buttons.append(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(theme: PresentationTheme, strings: PresentationStrings, enabled: Set<WhitegramFormattingAction>, selected: Set<WhitegramFormattingAction>) {
        for (index, button) in self.buttons.enumerated() {
            let action = WhitegramFormattingAction.allCases[index]
            button.isEnabled = enabled.contains(action)
            button.isSelected = selected.contains(action)
            button.alpha = button.isEnabled ? 1.0 : 0.35
            button.tintColor = theme.chat.inputPanel.panelControlAccentColor
            button.setTitleColor(button.tintColor, for: .normal)
            button.accessibilityLabel = action.title(strings: strings)
            button.accessibilityTraits = button.isSelected ? [.button, .selected] : [.button]
            if !button.isEnabled { button.accessibilityTraits.insert(.notEnabled) }
            button.glass.frame = CGRect(x: 6.0, y: 6.0, width: 32.0, height: 32.0)
            button.glass.layer.cornerRadius = 16.0
            button.glass.layer.borderWidth = button.isSelected ? 1.0 : 0.0
            button.glass.layer.borderColor = button.tintColor.cgColor
            button.glass.update(size: CGSize(width: 32.0, height: 32.0), cornerRadius: 16.0, isDark: theme.overallDarkAppearance, tintColor: .init(kind: .panel), transition: .immediate)
        }
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.scrollView.frame = self.bounds
        for (index, button) in self.buttons.enumerated() {
            button.bounds = CGRect(x: 0.0, y: 0.0, width: 44.0, height: 44.0)
            button.center = CGPoint(x: 28.0 + CGFloat(index) * 44.0, y: self.bounds.midY)
        }
        self.scrollView.contentSize = CGSize(width: 24.0 + CGFloat(self.buttons.count) * 44.0 - 12.0, height: self.bounds.height)
    }

    @objc private func pressed(_ button: UIButton) {
        guard let action = WhitegramFormattingAction(rawValue: button.tag) else { return }
        self.action?(action)
    }
}
