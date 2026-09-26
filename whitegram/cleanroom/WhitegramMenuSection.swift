import Foundation
import UIKit

/// One row of the Whitegram main menu. Mirrors the recovered `WGMenuSection` shape:
/// icon, title, description and the settings sections it owns.
public struct WhitegramMenuSection: Hashable {
    public let id: String
    public let icon: String
    public let ruTitle: String
    public let ruDescription: String
    public let enTitle: String
    public let enDescription: String

    public init(
        id: String,
        icon: String,
        ruTitle: String,
        ruDescription: String,
        enTitle: String,
        enDescription: String
    ) {
        self.id = id
        self.icon = icon
        self.ruTitle = ruTitle
        self.ruDescription = ruDescription
        self.enTitle = enTitle
        self.enDescription = enDescription
    }

    public func title(russian: Bool) -> String {
        return russian ? ruTitle : enTitle
    }

    public func description(russian: Bool) -> String {
        return russian ? ruDescription : enDescription
    }

    public func image() -> UIImage? {
        return UIImage(systemName: icon)
    }
}

/// Order and wording follow the reference client's main menu.
public enum WhitegramMenuCatalog {
    public static let sections: [WhitegramMenuSection] = [
        WhitegramMenuSection(
            id: "about",
            icon: "person.crop.circle",
            ruTitle: "О Whitegram",
            ruDescription: "Версия, канал, разработчик",
            enTitle: "About Whitegram",
            enDescription: "Version, channel, developer"
        ),
        WhitegramMenuSection(
            id: "apiStatus",
            icon: "waveform.path.ecg",
            ruTitle: "Статус Whitegram API",
            ruDescription: "Доступность сервера, нагрузка и запросы приложения",
            enTitle: "Whitegram API status",
            enDescription: "Server availability, load and app requests"
        ),
        WhitegramMenuSection(
            id: "donate",
            icon: "heart.fill",
            ruTitle: "Поддержать разработку",
            ruDescription: "Whitegram делается без рекламы и подписок",
            enTitle: "Support development",
            enDescription: "Whitegram is built without ads or subscriptions"
        ),
        WhitegramMenuSection(
            id: "search",
            icon: "magnifyingglass",
            ruTitle: "Поиск настроек",
            ruDescription: "Найти опцию Whitegram",
            enTitle: "Settings search",
            enDescription: "Find a Whitegram option"
        ),
        WhitegramMenuSection(
            id: "appearance",
            icon: "paintbrush.pointed.fill",
            ruTitle: "Внешний вид",
            ruDescription: "Аватарки, пузыри сообщений, эффекты",
            enTitle: "Appearance",
            enDescription: "Avatars, message bubbles, effects"
        ),
        WhitegramMenuSection(
            id: "notifications",
            icon: "bell.fill",
            ruTitle: "Уведомления",
            ruDescription: "Локальные уведомления",
            enTitle: "Notifications",
            enDescription: "Local notifications"
        ),
        WhitegramMenuSection(
            id: "liquidGlass",
            icon: "drop.fill",
            ruTitle: "Liquid Glass",
            ruDescription: "Стеклянные панели и размытие",
            enTitle: "Liquid Glass",
            enDescription: "Glass panels and blur"
        ),
        WhitegramMenuSection(
            id: "messages",
            icon: "message.fill",
            ruTitle: "Сообщения",
            ruDescription: "Удалённые, изменённые, кэш",
            enTitle: "Messages",
            enDescription: "Deleted, edited, cache"
        ),
        WhitegramMenuSection(
            id: "camera",
            icon: "camera.fill",
            ruTitle: "Камера",
            ruDescription: "Зум, HD-отправка, кружки",
            enTitle: "Camera",
            enDescription: "Zoom, HD sending, video messages"
        ),
        WhitegramMenuSection(
            id: "ghost",
            icon: "eye.slash.fill",
            ruTitle: "Режим призрака",
            ruDescription: "Скрыть онлайн, прочтение и набор",
            enTitle: "Ghost mode",
            enDescription: "Hide online, read receipts and typing"
        ),
        WhitegramMenuSection(
            id: "privacy",
            icon: "lock.fill",
            ruTitle: "Конфиденциальность",
            ruDescription: "Защита контента и звонков",
            enTitle: "Privacy",
            enDescription: "Content and call protection"
        ),
        WhitegramMenuSection(
            id: "info",
            icon: "info.circle.fill",
            ruTitle: "Информация",
            ruDescription: "ID, дата-центр, дата создания",
            enTitle: "Information",
            enDescription: "ID, data center, creation date"
        ),
        WhitegramMenuSection(
            id: "misc",
            icon: "slider.horizontal.3",
            ruTitle: "Дополнительно",
            ruDescription: "Вибрация, реакции, ускорение",
            enTitle: "Additional",
            enDescription: "Vibration, reactions, acceleration"
        ),
        WhitegramMenuSection(
            id: "interface",
            icon: "eye.fill",
            ruTitle: "Разделы меню",
            ruDescription: "Что показывать в меню Telegram",
            enTitle: "Menu sections",
            enDescription: "What to show in the Telegram menu"
        ),
        WhitegramMenuSection(
            id: "tabs",
            icon: "rectangle.grid.2x2.fill",
            ruTitle: "Вкладки",
            ruDescription: "Нижняя панель и её вкладки",
            enTitle: "Tabs",
            enDescription: "Bottom bar and its tabs"
        ),
        WhitegramMenuSection(
            id: "localStars",
            icon: "star.fill",
            ruTitle: "Локальные звёзды",
            ruDescription: "Свой баланс звёзд на экране",
            enTitle: "Local stars",
            enDescription: "Own star balance on screen"
        ),
        WhitegramMenuSection(
            id: "fonts",
            icon: "textformat",
            ruTitle: "Шрифты",
            ruDescription: "Свой шрифт для всего приложения",
            enTitle: "Fonts",
            enDescription: "Own font for the whole app"
        ),
        WhitegramMenuSection(
            id: "translation",
            icon: "globe.europe.africa.fill",
            ruTitle: "Перевод",
            ruDescription: "Перевод входящих и исходящих",
            enTitle: "Translation",
            enDescription: "Translation of incoming and outgoing"
        ),
        WhitegramMenuSection(
            id: "traffic",
            icon: "globe.badge.chevron.backward",
            ruTitle: "Улучшенный трафик",
            ruDescription: "Маскировка трафика Telegram",
            enTitle: "Improved traffic",
            enDescription: "Masking Telegram traffic"
        ),
        WhitegramMenuSection(
            id: "virusTotal",
            icon: "checkmark.shield.fill",
            ruTitle: "VirusTotal",
            ruDescription: "Проверка ссылок и файлов",
            enTitle: "VirusTotal",
            enDescription: "Link and file checking"
        ),
        WhitegramMenuSection(
            id: "voiceChanger",
            icon: "waveform",
            ruTitle: "Смена голоса",
            ruDescription: "Изменение своего голоса в записях",
            enTitle: "Voice changer",
            enDescription: "Changing your own voice in voice messages"
        ),
        WhitegramMenuSection(
            id: "player",
            icon: "music.note",
            ruTitle: "Плеер",
            ruDescription: "Скорость, кроссфейд, эквалайзер",
            enTitle: "Player",
            enDescription: "Speed, crossfade, equalizer"
        ),
        WhitegramMenuSection(
            id: "radio",
            icon: "antenna.radiowaves.left.and.right",
            ruTitle: "Радио",
            ruDescription: "Сейчас никто не слушает",
            enTitle: "Radio",
            enDescription: "Nobody is listening right now"
        ),
        WhitegramMenuSection(
            id: "features",
            icon: "bolt.horizontal.circle.fill",
            ruTitle: "Функции Whitegram",
            ruDescription: "Стена, спецэффекты, значок в профиле",
            enTitle: "Whitegram features",
            enDescription: "Wall, special effects, profile badge"
        ),
        WhitegramMenuSection(
            id: "icons",
            icon: "square.grid.2x2.fill",
            ruTitle: "Иконки",
            ruDescription: "Наборы иконок, замена значков интерфейса",
            enTitle: "Icons",
            enDescription: "Icon sets, interface glyph replacement"
        ),
        WhitegramMenuSection(
            id: "plugins",
            icon: "puzzlepiece.extension.fill",
            ruTitle: "Плагины",
            ruDescription: "JS-плагины расширяют функциональность Whitegram без пересборки. Плагины выполняются в изолированной среде JavaScriptCore.",
            enTitle: "Plugins",
            enDescription: "JS plugins extend Whitegram without a rebuild. Plugins run in an isolated JavaScriptCore."
        ),
        WhitegramMenuSection(
            id: "localization",
            icon: "character.bubble.fill",
            ruTitle: "Локализация",
            ruDescription: "Свой перевод меню Whitegram: экспорт и импорт",
            enTitle: "Localization",
            enDescription: "Own translation of the Whitegram menu: export and import"
        ),
        WhitegramMenuSection(
            id: "sessions",
            icon: "clock.fill",
            ruTitle: "Сессии",
            ruDescription: "Сохранение входов в Keychain",
            enTitle: "Sessions",
            enDescription: "Saving logins in Keychain"
        ),
        WhitegramMenuSection(
            id: "allSettings",
            icon: "list.bullet",
            ruTitle: "Все настройки",
            ruDescription: "Полный список настроек",
            enTitle: "All settings",
            enDescription: "Full settings list"
        )
    ]

    /// Sections that open a dedicated screen; the rest show a placeholder until ported.
    public static let implemented: Set<String> = ["about", "privacy", "allSettings"]
}
