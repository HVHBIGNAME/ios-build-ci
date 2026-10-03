import AccountContext
import CoreLocation
import Display
import LocationUI
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData

public func whitegramContentLocationPicker(context: AccountContext, completion: @escaping (Bool) -> Void) -> ViewController {
    let initial = WhitegramContentLocation.configured.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    let controller = LocationPickerController(context: context, style: .glass, mode: .pick, initialLocation: initial, completion: { location, _, _, _, _ in
        completion(WhitegramContentLocation.set(latitude: location.latitude, longitude: location.longitude))
    })
    controller.title = WhitegramLocalization.string("map.fakeLocation", baseLanguage: context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode })
    return controller
}
