import Foundation
import UIKit
import AsyncDisplayKit
import Display
import ItemListUI
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData

extension WhitegramVoiceControl {
    var title: String {
        switch self {
        case .pitch: return "Pitch"
        case .timbre: return "Timbre"
        case .echo: return "Echo"
        case .clarity: return "Clarity"
        }
    }

    func displayValue(_ value: Double) -> String {
        switch self {
        case .pitch: return String(format: "%+.1f st", value)
        case .echo: return String(format: "%.0f%%", value)
        case .timbre, .clarity: return String(format: "%+.0f%%", value)
        }
    }
}

final class WhitegramVoiceSliderItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let control: WhitegramVoiceControl
    let value: Double
    let enabled: Bool
    let sectionId: ItemListSectionId
    let updated: (Double) -> Void

    init(presentationData: ItemListPresentationData, control: WhitegramVoiceControl, value: Double, enabled: Bool, sectionId: ItemListSectionId, updated: @escaping (Double) -> Void) {
        self.presentationData = presentationData
        self.control = control
        self.value = control.constrained(value)
        self.enabled = enabled
        self.sectionId = sectionId
        self.updated = updated
    }

    var selectable: Bool { return false }

    func selected(listView: ListView) {
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        // UIKit controls must be created on main, even when the list asks for
        // asynchronous node configuration. This row has no expensive layout.
        Queue.mainQueue().async {
            let node = WhitegramVoiceSliderItemNode()
            let layout = Self.layout(params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            completion(node, {
                return (nil, { _ in node.apply(self, params: params) })
            })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let node = node() as? WhitegramVoiceSliderItemNode else { return }
            completion(Self.layout(params), { _ in node.apply(self, params: params) })
        }
    }

    private static func layout(_ params: ListViewItemLayoutParams) -> ListViewItemNodeLayout {
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: 96.0), insets: .zero)
    }
}

private final class WhitegramVoiceSliderItemNode: ListViewItemNode {
    private let backgroundView = UIView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let slider = UISlider()
    private var control: WhitegramVoiceControl = .pitch
    private var savedValue = 0.0
    private var updated: ((Double) -> Void)?

    override init(layerBacked: Bool = false, rotated: Bool = false, seeThrough: Bool = false) {
        super.init(layerBacked: layerBacked, rotated: rotated, seeThrough: seeThrough)
        self.backgroundView.layer.cornerRadius = 12.0
        self.view.addSubview(self.backgroundView)
        self.titleLabel.font = Font.regular(17.0)
        self.valueLabel.font = Font.regular(15.0)
        self.valueLabel.textAlignment = .right
        self.titleLabel.isAccessibilityElement = false
        self.valueLabel.isAccessibilityElement = false
        self.backgroundView.addSubview(self.titleLabel)
        self.backgroundView.addSubview(self.valueLabel)
        self.backgroundView.addSubview(self.slider)
        self.slider.isContinuous = true
        self.slider.addTarget(self, action: #selector(self.valueChanged), for: .valueChanged)
        self.slider.addTarget(self, action: #selector(self.commitValue), for: [.touchUpInside, .touchUpOutside])
        self.slider.addTarget(self, action: #selector(self.cancelTracking), for: .touchCancel)
    }

    func apply(_ item: WhitegramVoiceSliderItem, params: ListViewItemLayoutParams) {
        self.control = item.control
        self.savedValue = item.value
        self.updated = item.updated
        let theme = item.presentationData.theme
        self.backgroundView.backgroundColor = theme.list.itemBlocksBackgroundColor
        self.titleLabel.text = item.control.title
        self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        self.valueLabel.textColor = theme.list.itemSecondaryTextColor
        self.titleLabel.alpha = item.enabled ? 1.0 : 0.45
        self.valueLabel.alpha = item.enabled ? 1.0 : 0.45
        self.slider.minimumValue = Float(item.control.range.lowerBound)
        self.slider.maximumValue = Float(item.control.range.upperBound)
        self.slider.minimumTrackTintColor = theme.list.itemAccentColor
        self.slider.maximumTrackTintColor = theme.list.itemSecondaryTextColor.withAlphaComponent(0.24)
        self.slider.isEnabled = item.enabled
        self.slider.accessibilityLabel = item.control.title
        if !self.slider.isTracking {
            self.slider.value = Float(item.value)
        }
        self.updateLabel()

        let width = max(0.0, params.width - params.leftInset - params.rightInset)
        self.backgroundView.frame = CGRect(x: params.leftInset, y: 2.0, width: width, height: 92.0)
        self.titleLabel.frame = CGRect(x: 16.0, y: 10.0, width: max(0.0, width - 120.0), height: 26.0)
        self.valueLabel.frame = CGRect(x: max(16.0, width - 100.0), y: 10.0, width: 84.0, height: 26.0)
        self.slider.frame = CGRect(x: 16.0, y: 46.0, width: max(0.0, width - 32.0), height: 32.0)
    }

    private func updateLabel() {
        let text = self.control.displayValue(self.control.quantized(Double(self.slider.value)))
        self.valueLabel.text = text
        self.slider.accessibilityValue = text
    }

    @objc private func valueChanged() {
        self.updateLabel()
        // VoiceOver adjustments do not produce touch-up events.
        if !self.slider.isTracking { self.commitValue() }
    }

    @objc private func commitValue() {
        guard self.slider.isEnabled else { return }
        let value = self.control.quantized(Double(self.slider.value))
        self.slider.value = Float(value)
        self.updateLabel()
        guard value != self.savedValue else { return }
        self.savedValue = value
        self.updated?(value)
    }

    @objc private func cancelTracking() {
        self.slider.value = Float(self.savedValue)
        self.updateLabel()
    }
}
