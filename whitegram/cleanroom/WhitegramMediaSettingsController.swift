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

private struct WhitegramMediaStrings {
    let baseLanguage: String

    func string(_ key: String) -> String {
        return WhitegramLocalization.string(key, baseLanguage: self.baseLanguage)
    }

    func supplemental(_ english: String, _ russian: String, _ ukrainian: String) -> String {
        switch WhitegramLocalization.selectedLanguage(baseLanguage: self.baseLanguage) {
        case "ru": return russian
        case "uk": return ukrainian
        default: return english
        }
    }

    func downloadMode(_ mode: WhitegramTransferSettings.DownloadMode, maximumSpeed: Bool) -> String {
        switch mode {
        case .telegram:
            if maximumSpeed {
                return self.string("accel.16") + self.supplemental(" (maximum-speed switch)", " (максимальная скорость)", " (максимальна швидкість)")
            }
            return self.string("accel.off")
        case .conservative: return self.string("accel.4")
        case .balanced: return self.string("accel.8")
        case .maximum: return self.string("accel.16")
        }
    }
}

private struct WhitegramMediaEntry: ItemListNodeEntry {
    enum Content: Equatable {
        case header(String)
        case text(String)
        case toggle(String, Bool, Bool)
        case quality(String, Double)
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
        case let .toggle(title, value, enabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, enabled: enabled, sectionId: section, style: .blocks, updated: { coordinator.save([self.stableId: $0]) })
        case let .quality(title, value):
            return WhitegramPhotoQualitySliderItem(presentationData: presentationData, title: title, value: value, sectionId: section, updated: { coordinator.save(["photoCompressionQuality": $0]) })
        case let .choice(title, label, enabled):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, enabled: enabled, label: label, sectionId: section, style: .blocks, action: { coordinator.choose(self.stableId, title: title) })
        case let .reset(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: section, style: .blocks, action: { coordinator.save(self.stableId == "resetTransfer" ? WhitegramTransferSettings.resetValues : WhitegramMediaSettings.resetValues) })
        }
    }
}

private final class WhitegramMediaCoordinator {
    let updates = ValuePromise<Int>(0, ignoreRepeated: true)
    weak var controller: ItemListController?
    private var revision = 0
    private var observers: [NSObjectProtocol] = []
    private(set) var error: String?
    var strings = WhitegramMediaStrings(baseLanguage: "")

    init() {
        for name in [WhitegramPreferences.updatedNotification, WhitegramLocalizationStore.changedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    private func refresh() { revision += 1; updates.set(revision) }

    func save(_ values: [String: Any]) {
        error = WhitegramPreferences.update(values) ? nil : strings.supplemental("Could not save media settings.", "Не удалось сохранить настройки медиа.", "Не вдалося зберегти налаштування медіа.")
        refresh()
    }

    func choose(_ key: String, title: String) {
        guard let controller, controller.viewIfLoaded?.window != nil, controller.presentedViewController == nil else { return }
        let settings = WhitegramMediaSettings.current
        let localized = strings.string
        let text = strings.supplemental
        var choices: [(String, Any, Bool)] = []
        switch key {
        case "videoMessageCamera":
            choices = [(localized("s.cameraFront"), 0, true), (localized("s.cameraBack"), 1, true), (text("Ask Every Time", "Спрашивать каждый раз", "Запитувати щоразу"), 2, true)]
        case "backCameraPreset", "frontCameraPreset":
            let front = key == "frontCameraPreset"
            let fps = front ? settings.frontCameraFPS : settings.backCameraFPS
            choices = WhitegramCameraConfiguration.presets.map {
                ($0.title, $0.value, WhitegramCameraConfiguration.supported(front: front, preset: $0.value, fps: fps))
            }
        case "backCameraFPS", "frontCameraFPS":
            let front = key == "frontCameraFPS"
            let preset = front ? settings.frontCameraPreset : settings.backCameraPreset
            choices = WhitegramCameraConfiguration.frameRates.map {
                ("\($0) fps", $0, WhitegramCameraConfiguration.supported(front: front, preset: preset, fps: $0))
            }
        case "roundVideoBitrate":
            choices = [(localized("camera.settings.bitrateLow") + " · 0.5 Mbps", "low", true), (localized("camera.settings.bitrateMed") + " · 1 Mbps", "medium", true), (localized("camera.settings.bitrateHigh") + " · 3 Mbps", "high", true)]
        case "downloadAccelMode":
            let transfer = WhitegramTransferSettings.current
            choices = WhitegramTransferSettings.DownloadMode.allCases.map { (strings.downloadMode($0, maximumSpeed: transfer.maxDownloadSpeed), $0.rawValue, true) }
        default: return
        }
        let message = choices.contains(where: { !$0.2 }) ? text("Unavailable choices are not supported by this camera at the selected resolution/FPS. Reset media settings if a saved combination is unavailable.", "Недоступные варианты не поддерживаются этой камерой при выбранном разрешении/FPS. Сбросьте настройки медиа, если сохранённая комбинация недоступна.", "Недоступні варіанти не підтримуються цією камерою за вибраної роздільної здатності/FPS. Скиньте налаштування медіа, якщо збережена комбінація недоступна.") : nil
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        for (label, value, enabled) in choices {
            let action = UIAlertAction(title: label, style: .default, handler: { [weak self] _ in self?.save([key: value]) })
            action.isEnabled = enabled
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: localized("common.cancel"), style: .cancel))
        controller.present(alert, animated: true)
    }
}

private func whitegramMediaEntries(_ data: PresentationData, error: String?) -> [WhitegramMediaEntry] {
    let settings = WhitegramMediaSettings.current
    let strings = WhitegramMediaStrings(baseLanguage: data.strings.baseLanguageCode)
    let text = strings.supplemental
    let localized = strings.string
    var rows: [WhitegramMediaEntry] = []
    func add(_ id: String, _ section: Int32, _ content: WhitegramMediaEntry.Content) {
        rows.append(WhitegramMediaEntry(stableId: id, order: rows.count, section: section, content: content))
    }
    if let error { add("error", 0, .text(error)) }
    add("photos", 0, .header(text("PHOTOS", "ФОТОГРАФИИ", "ФОТОГРАФІЇ")))
    add("sendLargePhotos", 0, .toggle(localized("s.sendLargePhotos"), settings.sendLargePhotos, true))
    add("alwaysSendHD", 0, .toggle(localized("s.alwaysHD"), settings.alwaysSendHD, true))
    add("photoCompressionQuality", 0, .quality(localized("s.photoQuality"), settings.photoCompressionQuality))
    add("photoInfo", 0, .text(text("Large photos and HD use up to 2560 pixels on the longest side; standard photos use 1280. JPEG quality applies to Photos-library images in both modes. Small images are not enlarged. Queued resources keep their size and quality choices.", "Большие фото и HD: до 2560 пикселей по длинной стороне; обычные фото: 1280. Качество JPEG применяется к фото из медиатеки в обоих режимах. Маленькие фото не увеличиваются. Ресурсы очереди сохраняют выбранные размер и качество.", "Великі фото та HD: до 2560 пікселів за довшою стороною; звичайні фото: 1280. Якість JPEG застосовується до фото з медіатеки в обох режимах. Маленькі фото не збільшуються. Ресурси черги зберігають вибрані розмір і якість.")))
    add("cleanMetadataOnSend", 1, .toggle(localized("s.cleanMetadata"), settings.cleanMetadataOnSend, true))
    add("metadataInfo", 1, .text(text("Cleans supported single-image files up to 128 MiB while preserving orientation and color. Video files selected from Photos use Telegram's conversion pipeline instead of copying the original; this can change their size and quality. A failed image cleanup cancels the selection. Animated/multipage images and other document types use their normal path.", "Очищает поддерживаемые файлы с одним изображением до 128 МиБ, сохраняя ориентацию и цвет. Видеофайлы из медиатеки проходят конвертацию Telegram вместо копирования оригинала; размер и качество могут измениться. Ошибка очистки фото отменяет выборку. Анимации, многостраничные изображения и другие документы обрабатываются обычным способом.", "Очищає підтримувані файли з одним зображенням до 128 МіБ, зберігаючи орієнтацію та колір. Відеофайли з медіатеки проходять конвертацію Telegram замість копіювання оригіналу; розмір і якість можуть змінитися. Помилка очищення фото скасовує вибір. Анімації, багатосторінкові зображення та інші документи обробляються звичайним способом.")))
    add("camera", 2, .header(localized("s.cameraSettings")))
    let camera = settings.videoMessageCamera ?? 0
    let cameraNames = [localized("s.cameraFront"), localized("s.cameraBack"), text("Ask", "Спрашивать", "Запитувати")]
    add("videoMessageCamera", 2, .choice(text("Video-message Camera", "Камера видеосообщений", "Камера відеоповідомлень"), cameraNames.indices.contains(camera) ? cameraNames[camera] : "Telegram", true))
    add("rememberLastCamera", 2, .toggle(localized("s.rememberCamera"), settings.rememberLastCamera, true))
    add("staticZoomEnabled", 2, .toggle(localized("s.staticZoom"), settings.staticZoomEnabled, true))
    add("useTelegramCameraSettings", 2, .toggle(localized("camera.settings.stock"), settings.useTelegramCameraSettings, true))
    for front in [false, true] {
        let prefix = front ? "front" : "back"
        let name = front ? localized("camera.settings.front") : localized("camera.settings.back")
        let preset = front ? settings.frontCameraPreset : settings.backCameraPreset
        let fps = front ? settings.frontCameraFPS : settings.backCameraFPS
        let presetName = WhitegramCameraConfiguration.presets.first(where: { $0.value == preset })?.title ?? preset
        add(prefix + "CameraPreset", 2, .choice(name + ": " + localized("camera.settings.quality"), presetName, !settings.useTelegramCameraSettings))
        add(prefix + "CameraFPS", 2, .choice(name + ": " + localized("camera.settings.fps"), String(fps), !settings.useTelegramCameraSettings))
        if !settings.useTelegramCameraSettings && !WhitegramCameraConfiguration.supported(front: front, preset: preset, fps: fps) {
            add(prefix + "Unsupported", 2, .text(name + text(": saved format is unavailable on this device; native capture settings will be used.", ": сохранённый формат недоступен на этом устройстве; используются штатные параметры захвата.", ": збережений формат недоступний на цьому пристрої; використовуються штатні параметри захоплення.")))
        }
    }
    add("roundCameraWideAngle", 2, .toggle(localized("camera.settings.wideAngle"), settings.roundCameraWideAngle, !settings.useTelegramCameraSettings))
    if !WhitegramCameraConfiguration.wideAngleAvailable {
        add("wideUnavailable", 2, .text(text("Ultra-wide capture is unavailable on this device.", "Широкоугольный захват недоступен на этом устройстве.", "Ширококутне захоплення недоступне на цьому пристрої.")))
    }
    add("roundVideoBitrate", 2, .choice(localized("camera.settings.bitrate"), settings.roundVideoBitrateValue.map { String(format: "%.1f Mbps", Double($0) / 1_000_000) } ?? "Telegram", !settings.useTelegramCameraSettings))
    add("captureInfo", 2, .text(text("Reopen the camera after changing capture settings. The list checks sensor capability; actual format/FPS also depends on the capture session. As in the original client, round capture keeps its native sensor limits and 400 × 400 output; dual/additional cameras are limited to 30 FPS. Custom 4K, 60 FPS or ultra-wide preferences select a single-camera round session.", "После изменения параметров откройте камеру заново. Список проверяет возможности сенсора; фактические формат/FPS зависят также от сессии захвата. Как в оригинальном клиенте, видеосообщения сохраняют штатные ограничения захвата и итоговые 400 × 400; две камеры ограничены 30 FPS. Пользовательские 4K, 60 FPS или широкий угол переключают видеосообщения в режим одной камеры.", "Після зміни параметрів відкрийте камеру знову. Список перевіряє можливості сенсора; фактичні формат/FPS залежать також від сесії захоплення. Як в оригінальному клієнті, відеоповідомлення зберігають штатні обмеження захоплення та підсумкові 400 × 400; дві камери обмежені 30 FPS. Користувацькі 4K, 60 FPS або широкий кут перемикають відеоповідомлення в режим однієї камери.")))
    add("reset", 3, .reset(text("Reset Media and Camera Settings", "Сбросить настройки медиа и камеры", "Скинути налаштування медіа та камери")))
    let transfer = WhitegramTransferSettings.current
    add("transfers", 4, .header(text("TRANSFERS", "ПЕРЕДАЧА ФАЙЛОВ", "ПЕРЕДАВАННЯ ФАЙЛІВ")))
    add("maxDownloadSpeed", 4, .toggle(text("Maximum Transfer Speed", "Максимальная скорость передачи", "Максимальна швидкість передавання"), transfer.maxDownloadSpeed, true))
    add("sendAccelerationEnabled", 4, .toggle(localized("s.sendAccel"), transfer.sendAccelerationEnabled, true))
    let modeName = strings.downloadMode(transfer.downloadMode, maximumSpeed: transfer.maxDownloadSpeed)
    add("downloadAccelMode", 4, .choice(localized("s.downloadAccel"), modeName, true))
    add("transferInfo", 4, .text(text("Explicit download modes use 4, 8 or 16 parallel parts and override the maximum-speed switch. That switch also accelerates uploads. Send acceleration uses 16 upload parts; Telegram's special 30-part upload requests retain priority. Server rate limits still apply. Changes affect newly created transfer states.", "Явные режимы загрузки используют 4, 8 или 16 параллельных частей и имеют приоритет над переключателем максимальной скорости. Этот переключатель ускоряет также отправку. Ускорение отправки использует 16 частей; специальные запросы Telegram на 30 частей сохраняют приоритет. Серверные ограничения сохраняются. Изменения действуют для новых состояний передачи.", "Явні режими завантаження використовують 4, 8 або 16 паралельних частин і мають пріоритет над перемикачем максимальної швидкості. Цей перемикач прискорює також надсилання. Прискорення надсилання використовує 16 частин; спеціальні запити Telegram на 30 частин зберігають пріоритет. Серверні обмеження зберігаються. Зміни діють для нових станів передавання.")))
    add("resetTransfer", 5, .reset(text("Reset Transfer Settings", "Сбросить настройки передачи", "Скинути налаштування передавання")))
    return rows
}

public func whitegramMediaSettingsController(context: AccountContext) -> ViewController {
    let coordinator = WhitegramMediaCoordinator()
    let signal = combineLatest(context.sharedContext.presentationData, coordinator.updates.get())
    |> deliverOnMainQueue
    |> map { data, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        coordinator.strings = WhitegramMediaStrings(baseLanguage: data.strings.baseLanguageCode)
        let presentation = ItemListPresentationData(data)
        let state = ItemListControllerState(presentationData: presentation, title: .text(coordinator.strings.string("camera.settings.title")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: data.strings.Common_Back), animateChanges: false)
        return (state, (ItemListNodeState(presentationData: presentation, entries: whitegramMediaEntries(data, error: coordinator.error), style: .blocks, animateChanges: false), coordinator))
    }
    let controller = ItemListController(context: context, state: signal)
    coordinator.controller = controller
    return controller
}
