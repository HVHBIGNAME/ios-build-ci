import Foundation
import UIKit
import AccountContext
import Camera
import Display
import ItemListUI
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData

private struct WhitegramMediaEntry: ItemListNodeEntry {
    enum Content: Equatable {
        case header(String)
        case text(String)
        case toggle(String, Bool)
        case choice(String, String, Bool)
        case reset(String)
    }
    let stableId: String
    let order: Int
    let section: ItemListSectionId
    let content: Content

    static func < (lhs: Self, rhs: Self) -> Bool { return lhs.order < rhs.order }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let coordinator = arguments as! WhitegramMediaCoordinator
        switch content {
        case let .header(text): return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .text(text): return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section, style: .blocks)
        case let .toggle(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: section, style: .blocks, updated: { coordinator.save([self.stableId: $0]) })
        case let .choice(title, label, enabled):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, enabled: enabled, label: label, sectionId: section, style: .blocks, action: { coordinator.choose(self.stableId, title: title) })
        case let .reset(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: section, style: .blocks, action: { coordinator.save(WhitegramMediaSettings.resetValues) })
        }
    }
}

private final class WhitegramMediaCoordinator {
    let updates = ValuePromise<Int>(0, ignoreRepeated: true)
    weak var controller: ItemListController?
    private var revision = 0
    private var observer: NSObjectProtocol?
    private(set) var error: String?

    init() {
        observer = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func refresh() { revision += 1; updates.set(revision) }

    func save(_ values: [String: Any]) {
        error = WhitegramPreferences.update(values) ? nil : "Could not save media settings."
        refresh()
    }

    func choose(_ key: String, title: String) {
        guard let controller, controller.viewIfLoaded?.window != nil, controller.presentedViewController == nil else { return }
        let settings = WhitegramMediaSettings.current
        var choices: [(String, Any, Bool)] = []
        switch key {
        case "photoCompressionQuality":
            choices = [10, 25, 50, 60, 70, 80, 90, 95, 100].map { ("\($0)%", Double($0) / 100, true) }
        case "videoMessageCamera":
            choices = [("Front", 0, true), ("Back", 1, true), ("Ask Every Time", 2, true)]
        case "backCameraPreset", "frontCameraPreset":
            let front = key == "frontCameraPreset"
            let fps = front ? settings.frontCameraFPS : settings.backCameraFPS
            choices = [("Telegram", "", true)] + WhitegramCameraConfiguration.presets.map {
                ($0.title, $0.value, WhitegramCameraConfiguration.supported(front: front, preset: $0.value, fps: fps))
            }
        case "backCameraFPS", "frontCameraFPS":
            let front = key == "frontCameraFPS"
            let preset = front ? settings.frontCameraPreset : settings.backCameraPreset
            choices = [("Telegram", 0, true)] + WhitegramCameraConfiguration.frameRates.map {
                ("\($0) fps", $0, WhitegramCameraConfiguration.supported(front: front, preset: preset, fps: $0))
            }
        case "roundVideoBitrate":
            choices = [("Telegram (1 Mbps)", "", true)] + [500_000, 1_000_000, 2_000_000, 4_000_000, 8_000_000].map {
                (String(format: "%.1f Mbps", Double($0) / 1_000_000), String($0), true)
            }
        default: return
        }
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        for (label, value, enabled) in choices {
            let action = UIAlertAction(title: label, style: .default, handler: { [weak self] _ in self?.save([key: value]) })
            action.isEnabled = enabled
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        controller.present(alert, animated: true)
    }
}

private func whitegramMediaEntries(_ data: PresentationData, error: String?) -> [WhitegramMediaEntry] {
    let settings = WhitegramMediaSettings.current
    let russian = data.strings.baseLanguageCode.hasPrefix("ru")
    func text(_ english: String, _ russianText: String) -> String { return russian ? russianText : english }
    var rows: [WhitegramMediaEntry] = []
    func add(_ id: String, _ section: Int32, _ content: WhitegramMediaEntry.Content) {
        rows.append(WhitegramMediaEntry(stableId: id, order: rows.count, section: section, content: content))
    }
    if let error { add("error", 0, .text(error)) }
    add("photos", 0, .header(text("PHOTOS", "ФОТОГРАФИИ")))
    add("sendLargePhotos", 0, .toggle(text("Large Photos", "Большие фотографии"), settings.sendLargePhotos))
    add("alwaysSendHD", 0, .toggle(text("Always Send HD", "Всегда отправлять HD"), settings.alwaysSendHD))
    add("photoCompressionQuality", 0, .choice(text("Large-photo JPEG Quality", "Качество JPEG больших фото"), "\(Int((settings.photoCompressionQuality * 100).rounded()))%", settings.sendLargePhotos))
    add("photoInfo", 0, .text(text("Large photos use up to 4096 pixels on the longest side; HD uses 2560. Small images are not enlarged. Quality applies to the large-photo path. Choices are captured in queued resources.", "Большие фото: до 4096 пикселей по длинной стороне; HD: 2560. Маленькие фото не увеличиваются. Качество применяется к режиму больших фото. Параметры сохраняются в ресурсах очереди.")))
    add("cleanMetadataOnSend", 1, .toggle(text("Clean Still-image File Metadata", "Удалять метаданные файлов фото"), settings.cleanMetadataOnSend))
    add("metadataInfo", 1, .text(text("Cleans selected temporary JPEG/PNG/HEIC/HEIF files up to 128 MiB, preserving orientation and color profile. The original file is unchanged. A failed cleaning operation cancels this selection. Other document formats and the filename are unaffected.", "Очищает выбранные временные файлы JPEG/PNG/HEIC/HEIF до 128 МиБ, сохраняя ориентацию и цветовой профиль. Оригинал не меняется. Ошибка очистки отменяет эту выборку. Другие форматы документов и имя файла не меняются.")))
    add("camera", 2, .header(text("CAMERA", "КАМЕРА")))
    let camera = settings.videoMessageCamera ?? 0
    let cameraNames = [text("Front", "Фронтальная"), text("Back", "Задняя"), text("Ask", "Спрашивать")]
    add("videoMessageCamera", 2, .choice(text("Video-message Camera", "Камера видеосообщений"), cameraNames.indices.contains(camera) ? cameraNames[camera] : "Telegram", true))
    add("rememberLastCamera", 2, .toggle(text("Remember Last Video-message Camera", "Запоминать камеру видеосообщений"), settings.rememberLastCamera))
    add("useTelegramCameraSettings", 2, .toggle(text("Use Telegram Capture Settings", "Использовать настройки камеры Telegram"), settings.useTelegramCameraSettings))
    for front in [false, true] {
        let prefix = front ? "front" : "back"
        let name = front ? text("Front", "Фронтальная") : text("Back", "Задняя")
        let preset = front ? settings.frontCameraPreset : settings.backCameraPreset
        let fps = front ? settings.frontCameraFPS : settings.backCameraFPS
        let presetName = WhitegramCameraConfiguration.presets.first(where: { $0.value == preset })?.title ?? "Telegram"
        add(prefix + "CameraPreset", 2, .choice(name + text(" Capture Resolution", ": разрешение захвата"), presetName, !settings.useTelegramCameraSettings))
        add(prefix + "CameraFPS", 2, .choice(name + " FPS", fps == 0 ? "Telegram" : String(fps), !settings.useTelegramCameraSettings))
    }
    add("roundVideoBitrate", 2, .choice(text("Video-message Bitrate", "Битрейт видеосообщений"), settings.roundVideoBitrateValue.map { String(format: "%.1f Mbps", Double($0) / 1_000_000) } ?? "Telegram", !settings.useTelegramCameraSettings))
    add("captureInfo", 2, .text(text("Reopen the camera after changing capture settings. Custom capture formats apply to single-camera mode only; unsupported sensor/MultiCam formats retain Telegram's configuration. Capture resolution does not change the final square video-message dimensions.", "После изменения параметров откройте камеру заново. Пользовательский формат применяется в режиме одной камеры; неподдерживаемые форматы сенсора/MultiCam сохраняют конфигурацию Telegram. Разрешение захвата не меняет размер итогового квадратного видеосообщения.")))
    add("reset", 3, .reset(text("Reset These Media Settings", "Сбросить эти настройки медиа")))
    return rows
}

public func whitegramMediaSettingsController(context: AccountContext) -> ViewController {
    let coordinator = WhitegramMediaCoordinator()
    let signal = combineLatest(context.sharedContext.presentationData, coordinator.updates.get())
    |> deliverOnMainQueue
    |> map { data, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let presentation = ItemListPresentationData(data)
        let state = ItemListControllerState(presentationData: presentation, title: .text(data.strings.baseLanguageCode.hasPrefix("ru") ? "Медиа и камера" : "Media and Camera"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: data.strings.Common_Back), animateChanges: false)
        return (state, (ItemListNodeState(presentationData: presentation, entries: whitegramMediaEntries(data, error: coordinator.error), style: .blocks, animateChanges: false), coordinator))
    }
    let controller = ItemListController(context: context, state: signal)
    coordinator.controller = controller
    return controller
}
