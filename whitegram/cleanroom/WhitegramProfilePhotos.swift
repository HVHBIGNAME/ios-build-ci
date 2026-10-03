import Foundation

struct WhitegramProfilePhotosManifest: Decodable {
    struct Photo: Decodable { let slot: Int }
    let photos: [Photo]
}

final class WhitegramProfilePhotosService {
    let client: WhitegramBackendClient
    init(client: WhitegramBackendClient) { self.client = client }

    func slots(userId: Int64, completion: @escaping (Result<[Int], WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        return client.request(WhitegramProfilePhotosManifest.self, path: "/v1/profile/photos", query: [URLQueryItem(name: "user_id", value: String(userId))]) {
            completion($0.flatMap { result in
                let slots = result.photos.map { $0.slot }
                guard slots.allSatisfy({ (0..<3).contains($0) }), Set(slots).count == slots.count else { return .failure(.invalidResponse) }
                return .success(slots.sorted())
            })
        }
    }

    func photo(userId: Int64, slot: Int?, completion: @escaping (Result<Data, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        guard userId > 0, slot.map({ (0..<3).contains($0) }) ?? true else {
            let cancellation = WhitegramBackendCancellation()
            DispatchQueue.main.async { completion(.failure(cancellation.isCancelled ? .cancelled : .invalidRequest)) }
            return cancellation
        }
        var query = [URLQueryItem(name: "user_id", value: String(userId))]
        if let slot { query.append(URLQueryItem(name: "slot", value: String(slot))) }
        return client.raw(path: slot == nil ? "/v1/profile/photo-wall" : "/v1/profile/photos", query: query) { completion($0.map { $0.data }) }
    }

    func setPhoto(_ jpeg: Data?, slot: Int?, completion: @escaping (Result<Void, WhitegramBackendError>) -> Void) throws -> WhitegramBackendTask {
        guard slot.map({ (0..<3).contains($0) }) ?? true else { throw WhitegramBackendError.invalidRequest }
        if let jpeg {
            guard jpeg.count >= 3, jpeg.count <= WhitegramBackendProtocol.maximumResponseBytes,
                  jpeg.prefix(3) == Data([0xff, 0xd8, 0xff]) else { throw WhitegramBackendError.invalidRequest }
        }
        let query = slot.map { [URLQueryItem(name: "slot", value: String($0))] } ?? []
        return client.raw(path: slot == nil ? "/v1/profile/photo-wall" : "/v1/profile/photos", query: query,
            method: jpeg == nil ? "DELETE" : "POST", body: jpeg, contentType: "image/jpeg") { completion($0.map { _ in Void() }) }
    }
}
