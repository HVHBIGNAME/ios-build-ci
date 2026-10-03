import Foundation

/// Original history is JSON Data under wg_customFontHistory with fileName/psName pairs.
public enum WhitegramFontHistory {
    public static func read(values: [String: Any], defaults: UserDefaults) -> [[String: String]] {
        if let history = values["fontHistory"] as? [[String: String]] { return history }
        guard values["fontHistory"] == nil,
              let data = defaults.data(forKey: "wg_customFontHistory") else { return [] }
        do {
            return try JSONDecoder().decode([[String: String]].self, from: data)
        } catch {
            NSLog("Whitegram: could not decode original font history (%@)", String(describing: type(of: error)))
            return []
        }
    }

    public static func name(in value: [String: String]) -> String? {
        return value["name"] ?? value["psName"]
    }

    public static func isFontFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains(":"), !name.contains("\0") else { return false }
        return ["ttf", "otf"].contains((name as NSString).pathExtension.lowercased())
    }
}
