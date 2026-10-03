import Foundation
import UIKit
import AsyncDisplayKit
import Display
import ItemListUI
import SwiftSignalKit
import TelegramPresentationData

final class WhitegramPhotoQualitySliderItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let title: String
    let value: Double
    let sectionId: ItemListSectionId
    let updated: (Double) -> Void

    init(presentationData: ItemListPresentationData, title: String, value: Double, sectionId: ItemListSectionId, updated: @escaping (Double) -> Void) {
        self.presentationData = presentationData
        self.title = title
        self.value = value.isFinite ? min(1.0, max(0.1, value)) : 0.7
        self.sectionId = sectionId
        self.updated = updated
    }

    var selectable: Bool { return false }
    func selected(listView: ListView) {}

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        Queue.mainQueue().async {
            let node = WhitegramPhotoQualitySliderItemNode()
            let layout = Self.layout(params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            completion(node, { (nil, { _ in node.apply(self, params: params) }) })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let node = node() as? WhitegramPhotoQualitySliderItemNode else { return }
            completion(Self.layout(params), { _ in node.apply(self, params: params) })
        }
    }

    private static func layout(_ params: ListViewItemLayoutParams) -> ListViewItemNodeLayout {
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: 96.0), insets: .zero)
    }
}

private final class WhitegramPhotoQualitySliderItemNode: ListViewItemNode {
    private let backgroundView = UIView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let slider = UISlider()
    private var savedValue: Double = 0.7
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
        // Original photo-quality slider 0xddc8c8: 10...100 percent.
        self.slider.minimumValue = 10.0
        self.slider.maximumValue = 100.0
        self.slider.isContinuous = true
        self.slider.addTarget(self, action: #selector(self.valueChanged), for: .valueChanged)
        self.slider.addTarget(self, action: #selector(self.commitValue), for: [.touchUpInside, .touchUpOutside])
        self.slider.addTarget(self, action: #selector(self.cancelTracking), for: .touchCancel)
    }

    func apply(_ item: WhitegramPhotoQualitySliderItem, params: ListViewItemLayoutParams) {
        self.savedValue = item.value
        self.updated = item.updated
        let theme = item.presentationData.theme
        self.backgroundView.backgroundColor = theme.list.itemBlocksBackgroundColor
        self.titleLabel.text = item.title
        self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        self.valueLabel.textColor = theme.list.itemSecondaryTextColor
        self.slider.minimumTrackTintColor = theme.list.itemAccentColor
        self.slider.maximumTrackTintColor = theme.list.itemSecondaryTextColor.withAlphaComponent(0.24)
        self.slider.accessibilityLabel = item.title
        if !self.slider.isTracking { self.slider.value = Float(item.value * 100.0) }
        self.updateLabel()
        let width = max(0.0, params.width - params.leftInset - params.rightInset)
        self.backgroundView.frame = CGRect(x: params.leftInset, y: 2.0, width: width, height: 92.0)
        self.titleLabel.frame = CGRect(x: 16.0, y: 10.0, width: max(0.0, width - 100.0), height: 26.0)
        self.valueLabel.frame = CGRect(x: max(16.0, width - 80.0), y: 10.0, width: 64.0, height: 26.0)
        self.slider.frame = CGRect(x: 16.0, y: 46.0, width: max(0.0, width - 32.0), height: 32.0)
    }

    private func updateLabel() {
        let text = "\(Int(self.slider.value.rounded()))%"
        self.valueLabel.text = text
        self.slider.accessibilityValue = text
    }

    @objc private func valueChanged() {
        self.updateLabel()
        if !self.slider.isTracking { self.commitValue() }
    }

    @objc private func commitValue() {
        let value = Double(min(100.0, max(10.0, self.slider.value.rounded()))) / 100.0
        self.slider.value = Float(value * 100.0)
        self.updateLabel()
        guard value != self.savedValue else { return }
        self.savedValue = value
        self.updated?(value)
    }

    @objc private func cancelTracking() {
        self.slider.value = Float(self.savedValue * 100.0)
        self.updateLabel()
    }
}
