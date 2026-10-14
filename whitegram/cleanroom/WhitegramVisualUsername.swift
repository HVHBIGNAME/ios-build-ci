import Foundation

public enum WhitegramVisualUsername {
    public static func normalized(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@") { value.removeFirst() }
        if value.isEmpty { return "" }
        guard value.range(of: "^[A-Za-z][A-Za-z0-9_]{0,31}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    public static func display(actual: String?, isOwnProfile: Bool) -> String? {
        let policy = WhitegramAppearancePolicy.current
        guard isOwnProfile, policy.isEnabled("visualUsernameEnabled"),
              let value = normalized(policy.visualUsername), !value.isEmpty else { return actual }
        return value
    }
}
