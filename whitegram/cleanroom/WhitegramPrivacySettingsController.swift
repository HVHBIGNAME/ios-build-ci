import Display
import AccountContext

public func whitegramPrivacySettingsController(context: AccountContext) -> ViewController {
    return whitegramGeneratedSettingsController(context: context, sections: [12, 13], title: "Приватность / Privacy", availableOnly: true)
}
