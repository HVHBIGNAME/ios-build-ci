import Foundation

enum WhitegramTrafficPolicy {
    static let delay: ClosedRange<TimeInterval> = 60...180
    static let endpoints = [
        "https://cdnjs.cloudflare.com", "https://ajax.googleapis.com", "https://fonts.gstatic.com",
        "https://www.bing.com", "https://www.microsoft.com", "https://cdn.jsdelivr.net",
        "https://unpkg.com", "https://maxcdn.bootstrapcdn.com"
    ]
    static let userAgents = [
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/148.0.7778.92 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"
    ]

    enum Suspension: Equatable { case disabled, background, lowPower, lowBattery }

    static func suspension(enabled: Bool, foreground: Bool, lowPower: Bool, battery: Float) -> Suspension? {
        if !enabled { return .disabled }
        if !foreground { return .background }
        if lowPower { return .lowPower }
        if battery >= 0 && battery < 0.2 { return .lowBattery }
        return nil
    }

    static func request(endpoint: String, userAgent: String, head: Bool) -> URLRequest? {
        guard endpoints.contains(endpoint), userAgents.contains(userAgent), let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = head ? "HEAD" : "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        return request
    }
}
