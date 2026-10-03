import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData
import AccountContext

private final class WhitegramPluginControlTarget: NSObject, UITextFieldDelegate, UITextViewDelegate {
    var changed: ((Any) -> Void)?
    var submitted: ((Any) -> Void)?
    var tapped: (() -> Void)?

    @objc func tap() { self.tapped?() }
    @objc func change(_ sender: UIControl) {
        switch sender {
        case let value as UISwitch: self.changed?(value.isOn)
        case let value as UISlider: self.changed?(Double(value.value))
        case let value as UIStepper: self.changed?(value.value)
        case let value as UISegmentedControl: self.changed?(value.selectedSegmentIndex)
        case let value as UITextField: self.changed?(value.text ?? "")
        default: break
        }
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        self.submitted?(textField.text ?? "")
        textField.resignFirstResponder()
        return true
    }
    func textViewDidChange(_ textView: UITextView) { self.changed?(textView.text ?? "") }
}

private final class WhitegramPluginTreeRenderer {
    private let presentationData: PresentationData
    private let dispatch: (String, Any) -> Void
    var targets: [WhitegramPluginControlTarget] = []
    private var count = 0

    init(presentationData: PresentationData, dispatch: @escaping (String, Any) -> Void) {
        self.presentationData = presentationData
        self.dispatch = dispatch
    }

    private func target(_ props: [String: Any]) -> WhitegramPluginControlTarget {
        let target = WhitegramPluginControlTarget()
        for event in ["onChange", "onSubmit", "onTap", "onPress"] {
            guard let id = props[event] as? String, id.hasPrefix("__cb:") else { continue }
            let callback = String(id.dropFirst(5))
            let dispatch = self.dispatch
            if event == "onChange" { target.changed = { dispatch(callback, ["value": $0]) } }
            else if event == "onSubmit" { target.submitted = { dispatch(callback, ["value": $0]) } }
            else { target.tapped = { dispatch(callback, ["value": NSNull()]) } }
        }
        self.targets.append(target)
        return target
    }

    private func number(_ props: [String: Any], _ key: String, _ fallback: CGFloat, min lower: CGFloat = 0, max upper: CGFloat = 2048) -> CGFloat {
        guard let value = props[key] as? NSNumber, value.doubleValue.isFinite else { return fallback }
        return min(upper, max(lower, CGFloat(value.doubleValue)))
    }

    private func color(_ value: Any?) -> UIColor {
        switch value as? String {
        case "secondary": return self.presentationData.theme.list.itemSecondaryTextColor
        case "accent": return self.presentationData.theme.list.itemAccentColor
        case "destructive": return self.presentationData.theme.list.itemDestructiveColor
        default:
            if let value = value as? String, value.hasPrefix("#"), value.count == 7, let hex = UInt32(value.dropFirst(), radix: 16) {
                return UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
            }
            return self.presentationData.theme.list.itemPrimaryTextColor
        }
    }

    private func label(_ text: String, props: [String: Any] = [:]) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.textColor = self.color(props["color"] ?? (props["secondary"] as? Bool == true ? "secondary" : nil))
        let sizes: [String: CGFloat] = ["title": 26, "title2": 22, "headline": 17, "body": 17, "subheadline": 15, "caption": 12, "footnote": 13]
        let size = self.number(props, "fontSize", sizes[(props["font"] as? String) ?? "body"] ?? 17, min: 8, max: 72)
        label.font = UIFont.systemFont(ofSize: size, weight: props["bold"] as? Bool == true ? .semibold : .regular)
        if props["alignment"] as? String == "center" { label.textAlignment = .center }
        if props["alignment"] as? String == "trailing" { label.textAlignment = .right }
        return label
    }

    private func row(_ control: UIView, props: [String: Any]) -> UIView {
        guard let title = props["title"] as? String, !title.isEmpty else { return control }
        let stack = UIStackView(arrangedSubviews: [self.label(title), control])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        control.setContentHuggingPriority(.required, for: .horizontal)
        return stack
    }

    func render(_ value: Any, depth: Int = 0) throws -> UIView {
        self.count += 1
        guard depth <= 24, self.count <= 256 else { throw WhitegramPluginError("QUOTA_EXCEEDED", "UI tree exceeds 256 nodes or 24 levels") }
        if value is NSNull { return UIView() }
        guard let node = value as? [String: Any], let type = node["type"] as? String else { throw WhitegramPluginError("INVALID_UI", "Expected a normalized SDK UI node") }
        let props = (node["props"] as? [String: Any]) ?? [:]
        let children = (node["children"] as? [Any]) ?? []
        let view: UIView
        switch type {
        case "vstack", "hstack", "list", "scroll", "section", "card", "glass", "blur", "zstack":
            let stack = UIStackView()
            stack.axis = type == "hstack" ? .horizontal : .vertical
            stack.spacing = self.number(props, "spacing", 10, max: 64)
            if type == "hstack" { stack.alignment = .center }
            if props["distribution"] as? String == "equal" { stack.distribution = .fillEqually }
            if type == "section", let header = props["header"] as? String { stack.addArrangedSubview(self.label(header, props: ["bold": true])) }
            for child in children { stack.addArrangedSubview(try self.render(child, depth: depth + 1)) }
            if type == "section", let footer = props["footer"] as? String { stack.addArrangedSubview(self.label(footer, props: ["secondary": true, "font": "footnote"])) }
            if type == "zstack" { throw WhitegramPluginError("UNSUPPORTED_UI", "ZStack layering is not implemented") }
            if ["card", "glass", "blur"].contains(type) {
                stack.isLayoutMarginsRelativeArrangement = true
                let padding = self.number(props, "padding", 14, max: 64)
                stack.layoutMargins = UIEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
                let background: UIView
                let container: UIView
                if type == "glass" || type == "blur" {
                    let effect: UIBlurEffect
                    if #available(iOS 13.0, *) { effect = UIBlurEffect(style: .systemMaterial) }
                    else { effect = UIBlurEffect(style: self.presentationData.theme.overallDarkAppearance ? .dark : .light) }
                    let effectView = UIVisualEffectView(effect: effect)
                    background = effectView
                    container = effectView.contentView
                } else {
                    background = UIView()
                    background.backgroundColor = self.presentationData.theme.list.itemBlocksBackgroundColor
                    container = background
                }
                background.layer.cornerRadius = 12
                background.clipsToBounds = true
                stack.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(stack)
                NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: container.leadingAnchor), stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    stack.topAnchor.constraint(equalTo: container.topAnchor), stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
                view = background
            } else { view = stack }
        case "text": view = self.label(String(describing: props["text"] ?? ""), props: props)
        case "button", "row":
            let button = UIButton(type: .system)
            button.setTitle((props["title"] as? String) ?? "", for: .normal)
            button.setTitleColor(self.color(props["color"] ?? "accent"), for: .normal)
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .medium)
            button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
            button.addTarget(self.target(props), action: #selector(WhitegramPluginControlTarget.tap), for: .touchUpInside)
            view = button
        case "toggle":
            let control = UISwitch()
            control.isOn = (props["value"] as? Bool) ?? false
            control.onTintColor = self.presentationData.theme.list.itemAccentColor
            control.addTarget(self.target(props), action: #selector(WhitegramPluginControlTarget.change(_:)), for: .valueChanged)
            view = self.row(control, props: props)
        case "slider":
            let control = UISlider()
            control.minimumValue = Float(self.number(props, "min", 0, min: -1000000, max: 1000000))
            control.maximumValue = max(control.minimumValue, Float(self.number(props, "max", 1, min: -1000000, max: 1000000)))
            control.value = Float(self.number(props, "value", 0, min: CGFloat(control.minimumValue), max: CGFloat(control.maximumValue)))
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
            control.addTarget(self.target(props), action: #selector(WhitegramPluginControlTarget.change(_:)), for: .valueChanged)
            view = self.row(control, props: props)
        case "stepper":
            let control = UIStepper()
            control.minimumValue = Double(self.number(props, "min", 0, min: -1000000, max: 1000000))
            control.maximumValue = max(control.minimumValue, Double(self.number(props, "max", 100, min: -1000000, max: 1000000)))
            control.stepValue = Double(self.number(props, "step", 1, min: 0.001, max: 1000000))
            control.value = Double(self.number(props, "value", 0, min: CGFloat(control.minimumValue), max: CGFloat(control.maximumValue)))
            control.addTarget(self.target(props), action: #selector(WhitegramPluginControlTarget.change(_:)), for: .valueChanged)
            view = self.row(control, props: props)
        case "textfield":
            let control = UITextField()
            let target = self.target(props)
            control.borderStyle = .roundedRect
            control.text = (props["value"] as? String) ?? ""
            control.placeholder = props["placeholder"] as? String
            control.isSecureTextEntry = (props["secure"] as? Bool) ?? false
            control.textColor = self.presentationData.theme.list.itemPrimaryTextColor
            control.backgroundColor = self.presentationData.theme.list.itemBlocksBackgroundColor
            control.returnKeyType = .done
            switch props["keyboard"] as? String {
            case "number", "numberPad": control.keyboardType = .numberPad
            case "decimal": control.keyboardType = .decimalPad
            case "email": control.keyboardType = .emailAddress
            case "url": control.keyboardType = .URL
            default: break
            }
            control.delegate = target
            control.addTarget(target, action: #selector(WhitegramPluginControlTarget.change(_:)), for: .editingChanged)
            control.accessibilityIdentifier = (props["id"] as? String) ?? (props["bind"] as? String)
            view = control
        case "textarea":
            let control = UITextView()
            control.text = (props["value"] as? String) ?? ""
            control.font = UIFont.systemFont(ofSize: 16)
            control.textColor = self.presentationData.theme.list.itemPrimaryTextColor
            control.backgroundColor = self.presentationData.theme.list.itemBlocksBackgroundColor
            control.delegate = self.target(props)
            control.accessibilityIdentifier = (props["id"] as? String) ?? (props["bind"] as? String)
            control.heightAnchor.constraint(equalToConstant: self.number(props, "height", 120, min: 44, max: 800)).isActive = true
            view = control
        case "segmented":
            guard let options = props["options"] as? [String], !options.isEmpty, options.count <= 12 else { throw WhitegramPluginError("INVALID_UI", "Segmented options must be 1–12 strings") }
            let control = UISegmentedControl(items: options)
            control.selectedSegmentIndex = Int(self.number(props, "value", 0, max: CGFloat(options.count - 1)))
            control.addTarget(self.target(props), action: #selector(WhitegramPluginControlTarget.change(_:)), for: .valueChanged)
            view = control
        case "progress":
            let control = UIProgressView(progressViewStyle: .default)
            control.progress = Float(self.number(props, "value", 0, max: 1))
            view = control
        case "spinner":
            let control: UIActivityIndicatorView
            if #available(iOS 13.0, *) { control = UIActivityIndicatorView(style: .medium) }
            else { control = UIActivityIndicatorView(style: .gray) }
            control.startAnimating()
            view = control
        case "spacer":
            let spacer = UIView()
            spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: self.number(props, "minLength", 8, max: 800)).isActive = true
            view = spacer
        case "divider":
            let divider = UIView()
            divider.backgroundColor = self.presentationData.theme.list.itemSecondaryTextColor.withAlphaComponent(0.2)
            divider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
            view = divider
        case "icon", "image":
            let image: UIImage?
            if type == "icon" {
                if #available(iOS 13.0, *) { image = UIImage(systemName: (props["symbol"] as? String) ?? "") }
                else { image = nil }
            } else if let encoded = props["__imageBase64"] as? String, let data = Data(base64Encoded: encoded) { image = UIImage(data: data) }
            else { image = nil }
            guard let actualImage = image, actualImage.size.width * actualImage.size.height * actualImage.scale * actualImage.scale <= 16777216 else {
                throw WhitegramPluginError("INVALID_UI", "Image or SF Symbol is unavailable or exceeds 16 megapixels")
            }
            let imageView = UIImageView(image: actualImage)
            imageView.contentMode = .scaleAspectFit
            imageView.tintColor = self.color(props["color"] ?? "accent")
            imageView.heightAnchor.constraint(equalToConstant: self.number(props, "height", type == "icon" ? 28 : 180, min: 1, max: 800)).isActive = true
            view = imageView
        default: throw WhitegramPluginError("UNSUPPORTED_UI", "UI node '\(type)' is not supported")
        }
        if let enabled = props["enabled"] as? Bool { view.isUserInteractionEnabled = enabled; view.alpha = enabled ? 1 : 0.5 }
        if let hidden = props["hidden"] as? Bool { view.isHidden = hidden }
        return view
    }
}

final class WhitegramPluginSurfaceController: ViewController {
    private let scrollView = UIScrollView()
    private let content = UIStackView()
    private var renderer: WhitegramPluginTreeRenderer?
    private let presentationData: PresentationData
    var removed: (() -> Void)?
    var closedByHost = false
    private var wasVisible = false

    init(presentationData: PresentationData, title: String) {
        self.presentationData = presentationData
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentationData))
        self.title = title
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(self.donePressed))
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func donePressed() { self.removed?() }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.presentationData.theme.list.blocksBackgroundColor
        self.displayNode.view.addSubview(self.scrollView)
        self.scrollView.keyboardDismissMode = .interactive
        self.content.axis = .vertical
        self.content.spacing = 12
        self.content.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView.addSubview(self.content)
        NSLayoutConstraint.activate([
            self.content.leadingAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            self.content.trailingAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            self.content.topAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.topAnchor, constant: 16),
            self.content.bottomAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            self.content.widthAnchor.constraint(equalTo: self.scrollView.frameLayoutGuide.widthAnchor, constant: -32)
        ])
        self.displayNodeDidLoad()
    }

    func update(tree: Any, dispatch: @escaping (String, Any) -> Void) throws {
        let renderer = WhitegramPluginTreeRenderer(presentationData: self.presentationData, dispatch: dispatch)
        let view = try renderer.render(tree)
        self.loadViewIfNeeded()
        let focused = self.focused(in: self.content)?.accessibilityIdentifier
        for child in self.content.arrangedSubviews { self.content.removeArrangedSubview(child); child.removeFromSuperview() }
        self.content.addArrangedSubview(view)
        self.renderer = renderer
        if let focused = focused { self.find(focused, in: view)?.becomeFirstResponder() }
    }

    private func focused(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews { if let result = self.focused(in: child) { return result } }
        return nil
    }

    private func find(_ id: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == id { return view }
        for child in view.subviews { if let result = self.find(id, in: child) { return result } }
        return nil
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        let bottom = max(layout.intrinsicInsets.bottom, layout.inputHeight ?? 0)
        self.scrollView.frame = CGRect(x: layout.safeInsets.left, y: top, width: layout.size.width - layout.safeInsets.left - layout.safeInsets.right, height: max(0, layout.size.height - top - bottom))
    }

    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); self.wasVisible = true }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.wasVisible, !self.closedByHost else { return }
            if let navigation = self.navigationController as? NavigationController, navigation.viewControllers.contains(where: { $0 === self }) { return }
            self.removed?()
        }
    }
}

struct WhitegramPluginSettingsItem: Equatable {
    let id: String
    let kind: String
    let title: String
    let subtitle: String
    let token: String

    var key: String { return self.kind + ":" + self.id }
}

// Main-thread-only UIKit owner. Callback payloads contain no JSValue objects.
final class WhitegramPluginUI {
    private struct Surface {
        let controller: WhitegramPluginSurfaceController
        let kind: String
        var options: [String: Any]
        var visible: Bool
    }
    private struct Toast {
        let view: UIView
        let timer: DispatchWorkItem
        let target: WhitegramPluginControlTarget
        let callback: String?
    }
    private weak var context: AccountContext?
    private weak var navigation: NavigationController?
    private var surfaces: [String: Surface] = [:]
    private var toasts: [String: Toast] = [:]
    private var activeDialog: UIAlertController?
    private var keyboardHeight: CGFloat = 0
    private var keyboardObserver: NSObjectProtocol?
    private var registeredSettings: [WhitegramPluginSettingsItem] = []
    var dispatch: ((String, String, Any) -> Void)?
    var settingsChanged: (() -> Void)?

    var settingsItems: [WhitegramPluginSettingsItem] {
        dispatchPrecondition(condition: .onQueue(.main))
        return self.registeredSettings
    }

    func activateSettingsItem(_ key: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let item = self.registeredSettings.first(where: { $0.key == key }) else { return }
        self.dispatch?("__settings", item.token, ["id": item.id, "kind": item.kind])
    }

    private func registerSettings(_ kind: String, arguments: [Any]) throws -> String {
        guard arguments.count == 1, let config = arguments[0] as? [String: Any], let id = config["id"] as? String,
              let title = config["title"] as? String, let token = config["token"] as? String,
              !id.isEmpty, id.utf8.count <= 128, !title.isEmpty, title.utf8.count <= 512,
              !token.isEmpty, token.utf8.count <= 128 else { throw WhitegramPluginError("INVALID_ARGUMENT", "Invalid settings registration") }
        let subtitle = (config["subtitle"] as? String) ?? ""
        guard subtitle.utf8.count <= 2048 else { throw WhitegramPluginError("QUOTA_EXCEEDED", "Settings subtitle is too long") }
        let item = WhitegramPluginSettingsItem(id: id, kind: kind, title: title, subtitle: subtitle, token: token)
        if let index = self.registeredSettings.firstIndex(where: { $0.key == item.key }) { self.registeredSettings[index] = item }
        else {
            guard self.registeredSettings.filter({ $0.kind == kind }).count < (kind == "page" ? 8 : 32) else {
                throw WhitegramPluginError("QUOTA_EXCEEDED", "At most eight settings pages and 32 action rows per plugin")
            }
            self.registeredSettings.append(item)
        }
        self.settingsChanged?()
        return id
    }

    init(context: AccountContext) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.context = context
        self.keyboardObserver = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self, let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, let view = self.navigation?.view else { return }
            self.keyboardHeight = max(0, view.bounds.intersection(view.convert(frame, from: nil)).height)
        }
    }

    deinit { if let observer = self.keyboardObserver { NotificationCenter.default.removeObserver(observer) } }

    func attach(_ controller: UIViewController) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.navigation = (controller as? NavigationController) ?? (controller.navigationController as? NavigationController)
    }

    private func presentationData() throws -> PresentationData {
        guard let context = self.context else { throw WhitegramPluginError("ACCOUNT_UNAVAILABLE", "Account is no longer available") }
        return context.sharedContext.currentPresentationData.with { $0 }
    }

    private func navigationController() throws -> NavigationController {
        guard let navigation = self.navigation, navigation.isViewLoaded, navigation.view.window != nil else {
            throw WhitegramPluginError("NO_PRESENTATION_CONTEXT", "Open the plugin manager before presenting plugin UI")
        }
        return navigation
    }

    func call(_ path: String, arguments: [Any]) throws -> Any {
        dispatchPrecondition(condition: .onQueue(.main))
        switch path {
        case "ui.registerSettingsPage": return try self.registerSettings("page", arguments: arguments)
        case "ui.addSettingsRow": return try self.registerSettings("row", arguments: arguments)
        case "ui.theme":
            let theme = try self.presentationData().theme
            func hex(_ color: UIColor) -> String {
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                return String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
            }
            return ["dark": theme.overallDarkAppearance, "background": hex(theme.list.blocksBackgroundColor),
                    "text": hex(theme.list.itemPrimaryTextColor), "secondaryText": hex(theme.list.itemSecondaryTextColor), "accent": hex(theme.list.itemAccentColor)]
        case "ui.keyboardHeight": return Double(self.keyboardHeight)
        case "ui.haptic":
            let style = (arguments.first as? String) ?? "light"
            switch style {
            case "light": UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
            case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
            case "selection": UISelectionFeedbackGenerator().selectionChanged()
            default: throw WhitegramPluginError("INVALID_ARGUMENT", "Unknown haptic style")
            }
            return NSNull()
        case "ui.createSurface":
            guard self.surfaces.count < 8, arguments.count == 3, let options = arguments[1] as? [String: Any] else { throw WhitegramPluginError("QUOTA_EXCEEDED", "Invalid surface arguments or more than eight surfaces") }
            let kind = try whitegramPluginString(arguments, 0)
            guard ["window", "sheet", "screen"].contains(kind) else { throw WhitegramPluginError("UNSUPPORTED_UI", "Surface kind \(kind) is not implemented") }
            _ = try self.navigationController()
            let controller = WhitegramPluginSurfaceController(presentationData: try self.presentationData(), title: (options["title"] as? String) ?? "Plugin")
            let id = UUID().uuidString
            try controller.update(tree: arguments[2], dispatch: { [weak self] callback, payload in self?.dispatch?(id, callback, payload) })
            controller.removed = { [weak self] in self?.close(id) }
            self.surfaces[id] = Surface(controller: controller, kind: kind, options: options, visible: false)
            if kind != "screen" { try self.show(id, modal: true) }
            return id
        case "ui.toast":
            try self.toast(whitegramPluginString(arguments, 0), options: arguments.count > 1 ? ((arguments[1] as? [String: Any]) ?? [:]) : [:])
            return NSNull()
        default:
            let id = try whitegramPluginString(arguments, 0)
            guard var surface = self.surfaces[id] else { throw WhitegramPluginError("SURFACE_NOT_FOUND", "Surface has closed") }
            switch path {
            case "ui.updateSurface":
                guard arguments.count == 2 else { throw WhitegramPluginError("INVALID_UI", "Missing UI tree") }
                try surface.controller.update(tree: arguments[1], dispatch: { [weak self] callback, payload in self?.dispatch?(id, callback, payload) })
            case "ui.setSurfaceOptions":
                guard arguments.count == 2, let options = arguments[1] as? [String: Any] else { throw WhitegramPluginError("INVALID_UI", "Expected surface options") }
                surface.options.merge(options, uniquingKeysWith: { _, new in new })
                if let title = options["title"] as? String { surface.controller.title = title }
                self.surfaces[id] = surface
            case "ui.pushScreen": try self.show(id, modal: arguments.count > 1 && arguments[1] as? Bool == true)
            case "ui.setSurfaceVisible":
                if arguments.count > 1 && arguments[1] as? Bool == true { try self.show(id, modal: surface.kind != "screen") }
                else {
                    surface.controller.closedByHost = true
                    surface.controller.dismiss(animated: true)
                    surface.visible = false
                    self.surfaces[id] = surface
                }
            case "ui.closeSurface": self.close(id)
            case "ui.surfaceInfo": return ["id": id, "kind": surface.kind, "visible": surface.visible, "title": surface.controller.title ?? ""]
            default: throw WhitegramPluginError("UNSUPPORTED_API", path)
            }
            return true
        }
    }

    private func show(_ id: String, modal: Bool) throws {
        guard var surface = self.surfaces[id] else { throw WhitegramPluginError("SURFACE_NOT_FOUND", id) }
        if surface.visible { return }
        let navigation = try self.navigationController()
        surface.controller.closedByHost = false
        surface.controller.navigationPresentation = modal ? .modal : .default
        surface.visible = true
        self.surfaces[id] = surface
        navigation.pushViewController(surface.controller)
    }

    private func close(_ id: String) {
        guard let surface = self.surfaces.removeValue(forKey: id) else { return }
        surface.controller.closedByHost = true
        surface.controller.removed = nil
        if surface.visible { surface.controller.dismiss(animated: true) }
        self.dispatch?(id, "__closed", NSNull())
    }

    private func finishToast(_ id: String, action: Bool) {
        guard let toast = self.toasts.removeValue(forKey: id) else { return }
        toast.timer.cancel()
        toast.view.removeFromSuperview()
        if let callback = toast.callback { self.dispatch?("__toast", callback, ["dismissed": !action]) }
    }

    private func toast(_ text: String, options: [String: Any]) throws {
        guard self.toasts.count < 4 else { throw WhitegramPluginError("QUOTA_EXCEEDED", "Only four toasts can be visible") }
        let navigation = try self.navigationController()
        let presentationData = try self.presentationData()
        let id = UUID().uuidString
        let button = UIButton(type: .system)
        button.setTitle(text + ((options["action"] as? String).map { "   " + $0 } ?? ""), for: .normal)
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        button.setTitleColor(presentationData.theme.list.itemPrimaryTextColor, for: .normal)
        button.backgroundColor = presentationData.theme.list.itemBlocksBackgroundColor
        button.layer.cornerRadius = 12
        button.layer.shadowOpacity = 0.18
        button.layer.shadowRadius = 10
        let target = WhitegramPluginControlTarget()
        target.tapped = { [weak self] in self?.finishToast(id, action: true) }
        button.addTarget(target, action: #selector(WhitegramPluginControlTarget.tap), for: .touchUpInside)
        button.frame = CGRect(x: 16, y: navigation.view.safeAreaInsets.top + 52 + CGFloat(self.toasts.count) * 68, width: max(1, navigation.view.bounds.width - 32), height: 60)
        button.autoresizingMask = [.flexibleWidth]
        navigation.view.addSubview(button)
        let timer = DispatchWorkItem { [weak self] in self?.finishToast(id, action: false) }
        self.toasts[id] = Toast(view: button, timer: timer, target: target, callback: options["actionCallback"] as? String)
        let duration = (options["duration"] as? NSNumber)?.doubleValue ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + (duration.isFinite ? min(15, max(1, duration)) : 4), execute: timer)
    }

    func dialog(path: String, arguments: [Any], completion: @escaping (Result<Any, WhitegramPluginError>) -> Void) throws -> () -> Void {
        dispatchPrecondition(condition: .onQueue(.main))
        guard self.activeDialog == nil else { throw WhitegramPluginError("UI_BUSY", "A plugin dialog is already open") }
        let navigation = try self.navigationController()
        let title = try whitegramPluginString(arguments, 0)
        let message = try whitegramPluginString(arguments, 1)
        let isConfirm = path == "ui.confirm"
        let alert = UIAlertController(title: title, message: message, preferredStyle: isConfirm ? .alert : .actionSheet)
        let finish: (Any) -> Void = { [weak self, weak alert] value in
            guard let self = self, let alert = alert, self.activeDialog === alert else { return }
            self.activeDialog = nil
            completion(.success(value))
        }
        if isConfirm {
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in finish(true) }))
        } else {
            guard arguments.count == 3, let items = arguments[2] as? [String], !items.isEmpty, items.count <= 30 else { throw WhitegramPluginError("INVALID_ARGUMENT", "Menu requires 1–30 titles") }
            for (index, item) in items.enumerated() { alert.addAction(UIAlertAction(title: item, style: .default, handler: { _ in finish(index) })) }
        }
        alert.addAction(UIAlertAction(title: try self.presentationData().strings.Common_Cancel, style: .cancel, handler: { _ in finish(isConfirm ? false as Any : -1 as Any) }))
        alert.popoverPresentationController?.sourceView = navigation.view
        alert.popoverPresentationController?.sourceRect = CGRect(x: navigation.view.bounds.midX, y: navigation.view.bounds.midY, width: 1, height: 1)
        guard var presenter = navigation.view.window?.rootViewController else { throw WhitegramPluginError("NO_PRESENTATION_CONTEXT", "No window for dialog") }
        while let next = presenter.presentedViewController { presenter = next }
        guard !(presenter is UIAlertController), !presenter.isBeingDismissed else { throw WhitegramPluginError("UI_BUSY", "Another dialog is open") }
        self.activeDialog = alert
        presenter.present(alert, animated: true)
        return { [weak self, weak alert] in
            dispatchPrecondition(condition: .onQueue(.main))
            guard let self = self, let alert = alert, self.activeDialog === alert else { return }
            self.activeDialog = nil
            alert.dismiss(animated: false)
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        self.dispatch = nil
        self.registeredSettings.removeAll()
        self.settingsChanged?()
        self.settingsChanged = nil
        for id in Array(self.surfaces.keys) { self.close(id) }
        for id in Array(self.toasts.keys) { self.finishToast(id, action: false) }
        self.activeDialog?.dismiss(animated: false)
        self.activeDialog = nil
        if let observer = self.keyboardObserver { NotificationCenter.default.removeObserver(observer); self.keyboardObserver = nil }
    }
}
