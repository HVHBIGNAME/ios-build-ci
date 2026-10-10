import Foundation
import UIKit
import AsyncDisplayKit
import Display
import ItemListUI
import SwiftSignalKit
import TelegramPresentationData

final class WhitegramAppearanceSliderItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let title: String
    let range: ClosedRange<Double>
    let value: Double
    let suffix: String
    let step: Double
    let fractionDigits: Int
    let enabled: Bool
    let sectionId: ItemListSectionId
    let updated: (Double) -> Void

    init(presentationData: ItemListPresentationData, title: String, range: ClosedRange<Double>, value: Double, suffix: String, step: Double = 1.0, fractionDigits: Int = 0, enabled: Bool = true, sectionId: ItemListSectionId, updated: @escaping (Double) -> Void) {
        self.presentationData = presentationData
        self.title = title
        self.range = range
        self.value = min(range.upperBound, max(range.lowerBound, value))
        self.suffix = suffix
        precondition(step.isFinite && step > 0.0 && (0 ... 6).contains(fractionDigits))
        self.step = step
        self.fractionDigits = fractionDigits
        self.enabled = enabled
        self.sectionId = sectionId
        self.updated = updated
    }

    var selectable: Bool { return false }
    func selected(listView: ListView) {}

    private static func layout(_ params: ListViewItemLayoutParams) -> ListViewItemNodeLayout {
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: 100.0), insets: .zero)
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        Queue.mainQueue().async {
            let node = WhitegramAppearanceSliderNode()
            let layout = Self.layout(params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            completion(node, { (nil, { _ in node.apply(self, params: params) }) })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let node = node() as? WhitegramAppearanceSliderNode else { return }
            completion(Self.layout(params), { _ in node.apply(self, params: params) })
        }
    }
}

private final class WhitegramAppearanceSliderNode: ListViewItemNode {
    private let background = UIView()
    private let title = UILabel()
    private let valueLabel = UILabel()
    private let slider = UISlider()
    private var item: WhitegramAppearanceSliderItem?

    override init(layerBacked: Bool = false, rotated: Bool = false, seeThrough: Bool = false) {
        super.init(layerBacked: layerBacked, rotated: rotated, seeThrough: seeThrough)
        self.view.addSubview(self.background)
        self.background.layer.cornerRadius = 12.0
        self.background.addSubview(self.title)
        self.background.addSubview(self.valueLabel)
        self.background.addSubview(self.slider)
        self.title.numberOfLines = 2
        self.title.isAccessibilityElement = false
        self.valueLabel.isAccessibilityElement = false
        self.valueLabel.textAlignment = .right
        self.slider.addTarget(self, action: #selector(self.changed), for: .valueChanged)
        self.slider.addTarget(self, action: #selector(self.commit), for: [.touchUpInside, .touchUpOutside])
        self.slider.addTarget(self, action: #selector(self.cancel), for: .touchCancel)
    }

    func apply(_ item: WhitegramAppearanceSliderItem, params: ListViewItemLayoutParams) {
        self.item = item
        self.title.text = item.title
        self.title.font = Font.regular(17.0)
        self.valueLabel.font = Font.regular(15.0)
        self.title.textColor = item.presentationData.theme.list.itemPrimaryTextColor
        self.valueLabel.textColor = item.presentationData.theme.list.itemSecondaryTextColor
        self.background.backgroundColor = item.presentationData.theme.list.itemBlocksBackgroundColor
        self.slider.minimumTrackTintColor = item.presentationData.theme.list.itemAccentColor
        self.slider.maximumTrackTintColor = item.presentationData.theme.list.itemSecondaryTextColor.withAlphaComponent(0.24)
        self.slider.minimumValue = Float(item.range.lowerBound)
        self.slider.maximumValue = Float(item.range.upperBound)
        self.slider.isEnabled = item.enabled
        self.slider.accessibilityLabel = item.title
        if !self.slider.isTracking { self.slider.value = Float(item.value) }
        self.updateLabel()
        let width = max(0.0, params.width - params.leftInset - params.rightInset)
        self.background.frame = CGRect(x: params.leftInset, y: 2.0, width: width, height: 96.0)
        self.title.frame = CGRect(x: 16.0, y: 4.0, width: max(0.0, width - 120.0), height: 46.0)
        self.valueLabel.frame = CGRect(x: max(16.0, width - 100.0), y: 12.0, width: 84.0, height: 30.0)
        self.slider.frame = CGRect(x: 16.0, y: 52.0, width: max(0.0, width - 32.0), height: 32.0)
    }

    private func updateLabel() {
        guard let item = self.item else { return }
        let number = min(item.range.upperBound, max(item.range.lowerBound, (Double(self.slider.value) / item.step).rounded() * item.step))
        let value = String(format: "%.*f", item.fractionDigits, number) + item.suffix
        self.valueLabel.text = value
        self.slider.accessibilityValue = value
    }

    @objc private func changed() {
        self.updateLabel()
        if !self.slider.isTracking { self.commit() }
    }

    @objc private func commit() {
        guard let item = self.item, item.enabled else { return }
        let value = min(item.range.upperBound, max(item.range.lowerBound, (Double(self.slider.value) / item.step).rounded() * item.step))
        self.slider.value = Float(value)
        self.updateLabel()
        if value != item.value { item.updated(value) }
    }

    @objc private func cancel() {
        if let item = self.item { self.slider.value = Float(item.value) }
        self.updateLabel()
    }
}
