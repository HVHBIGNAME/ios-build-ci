import Foundation

/// Client-owned labels; the recovered original localization table stays separate.
public enum WhitegramComposerStrings {
    private static let values: [String: [String]] = [
        "composer.sendOnReturn": ["Отправлять клавишей Enter", "Надсилати клавішею Enter", "Send with Return"],
        "composer.collapsedQuote": ["Свёрнутая цитата", "Згорнута цитата", "Collapsed quote"],
        "composer.clearFormatting": ["Убрать форматирование", "Прибрати форматування", "Clear formatting"],
        "composer.undo": ["Отменить", "Скасувати", "Undo"],
        "composer.redo": ["Повторить", "Повторити", "Redo"],
        "composer.saveFailed": ["Не удалось сохранить настройку.", "Не вдалося зберегти налаштування.", "Could not save preference."]
    ]

    public static func string(_ key: String, baseLanguage: String = "", store: WhitegramLocalizationStore = .shared) -> String {
        let language = WhitegramLocalization.selectedLanguage(baseLanguage: baseLanguage)
        let index = WhitegramLocalization.builtInLanguages.firstIndex(of: language) ?? 2
        return WhitegramLocalization.string(key, baseLanguage: baseLanguage, fallback: values[key]?[index], store: store)
    }
}
