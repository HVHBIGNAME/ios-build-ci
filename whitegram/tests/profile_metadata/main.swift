import Foundation
import CoreFoundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

let keys = ["showMutualContactsCard", "showRegistrationDateCard"]
let suiteName = "WhitegramProfileMetadataTests." + UUID().uuidString
let legacy = UserDefaults(suiteName: suiteName)!
defer { legacy.removePersistentDomain(forName: suiteName) }

func checkSettings(_ settings: WhitegramPeerMetadataSettings, _ expected: Bool) {
    check(settings.showMutualContactsCard == expected, "mutual setting")
    check(settings.showRegistrationDateCard == expected, "registration setting")
}

checkSettings(WhitegramPeerMetadataSettings(values: [:]), false)
for key in keys { legacy.set(true, forKey: "wg_" + key) }
checkSettings(WhitegramPeerMetadataSettings(values: [:], legacyDefaults: legacy), true)
checkSettings(WhitegramPeerMetadataSettings(values: Dictionary(uniqueKeysWithValues: keys.map { ($0, false) }), legacyDefaults: legacy), false)
for invalid in [1, 0, "true", "false", NSNull(), [true]] as [Any] {
    checkSettings(WhitegramPeerMetadataSettings(values: Dictionary(uniqueKeysWithValues: keys.map { ($0, invalid) }), legacyDefaults: legacy), false)
}
for key in keys {
    // Replace the value's type as well as its numeric equality to the old Bool.
    legacy.removeObject(forKey: "wg_" + key)
    legacy.set(1, forKey: "wg_" + key)
    let number = legacy.object(forKey: "wg_" + key) as! NSNumber
    check(CFGetTypeID(number) != CFBooleanGetTypeID(), "numeric legacy fixture type")
}
checkSettings(WhitegramPeerMetadataSettings(values: [:], legacyDefaults: legacy), false)
checkSettings(WhitegramPeerMetadataSettings(values: Dictionary(uniqueKeysWithValues: keys.map { ($0, true) }), legacyDefaults: legacy), true)

for invalid in [nil, "", "2.2020", "02.20", "00.2020", "13.2020", "02.2012", "02.10000", " 02.2020", "02.2020\n", "02-2020", "02.2020.01", "０２.２０２０", "+2.2020"] as [String?] {
    check(WhitegramPeerMetadataDate.telegramMonth(invalid) == nil, "malformed Telegram month: \(invalid ?? "nil")")
}
let telegram = WhitegramPeerMetadataDate.telegramMonth("02.2020")!
check(telegram.year == 2020 && telegram.month == 2 && telegram.day == 0 && telegram.exact, "Telegram date precision")

for (year, month, day) in [(0, 0, 0), (2012, 12, 31), (2020, 0, 1), (2019, 2, 29), (2020, 4, 31), (10000, 1, 1), (2020, 13, 0), (2020, -1, 0), (2020, 1, -1)] {
    check(WhitegramPeerMetadataDate(year: year, month: month, day: day, exact: true) == nil, "invalid calendar components")
}
for (year, month, day, exact, expected) in [
    (2020, 2, 29, true, "29.02.2020"),
    (2019, 0, 0, true, "2019"),
    (2019, 0, 0, false, "~ 2019"),
    (2020, 2, 0, true, "February 2020"),
    (2020, 2, 0, false, "~ February 2020"),
    (2020, 2, 29, false, "~ February 2020")
] {
    let value = WhitegramPeerMetadataDate(year: year, month: month, day: day, exact: exact)!
    let text = value.formatted { month, year in
        check(month == 2 && year == 2020, "one-based formatter arguments")
        return "February 2020"
    }
    check(text == expected, "original precision: \(text) != \(expected)")
}
check(telegram.formatted { _, _ in "Февраль 2020" } == "Февраль 2020", "localized month formatter")
print("Profile metadata policy regressions passed")
