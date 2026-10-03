import Foundation

struct WhitegramProfileRegistrationDate: Codable, Equatable, WhitegramBackendValidatable {
    let userId: Int64
    let year: Int
    let month: Int
    let day: Int
    let exact: Bool

    enum CodingKeys: String, CodingKey { case userId = "user_id", year, month, day, exact }

    var isEmpty: Bool { return year == 0 }

    func validateResponse() throws {
        guard userId > 0, Self.validDate(year: year, month: month, day: day) else { throw WhitegramBackendError.invalidResponse }
    }

    static func validDate(year: Int, month: Int, day: Int) -> Bool {
        if year == 0 { return month == 0 && day == 0 }
        guard (2013...9999).contains(year), (0...12).contains(month), (0...31).contains(day), month != 0 || day == 0 else { return false }
        guard day != 0 else { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return false }
        let result = calendar.dateComponents([.year, .month, .day], from: date)
        return result.year == year && result.month == month && result.day == day
    }

    var displayText: String {
        if isEmpty { return "Not provided" }
        let value = day > 0 ? String(format: "%04d-%02d-%02d", year, month, day) : (month > 0 ? String(format: "%04d-%02d", year, month) : String(year))
        return exact ? value : "≈ " + value
    }
}

extension WhitegramProfileService {
    private struct RegistrationUpdate: Encodable { let year: Int; let month: Int; let day: Int }

    func registrationDate(userId: Int64, force: Bool = false,
                          completion: @escaping (Result<WhitegramProfileRegistrationDate, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        return fetch(WhitegramProfileRegistrationDate.self, resource: .registration, userId: userId, force: force) { result in
            completion(result.flatMap { $0.userId == userId ? .success($0) : .failure(.invalidResponse) })
        }
    }

    func saveRegistrationDate(year: Int, month: Int, day: Int,
                              completion: @escaping (Result<Void, WhitegramBackendError>) -> Void) throws -> WhitegramBackendTask {
        guard WhitegramProfileRegistrationDate.validDate(year: year, month: month, day: day),
              year <= Calendar(identifier: .gregorian).component(.year, from: Date()) else { throw WhitegramBackendError.invalidRequest }
        return save(RegistrationUpdate(year: year, month: month, day: day), path: "/v1/registration-date", completion: completion)
    }
}
