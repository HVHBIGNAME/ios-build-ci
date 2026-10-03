import Foundation
import CryptoKit
import XCTest
@testable import WhitegramBackendHost

final class WhitegramBackendProtocolTests: XCTestCase {
    func testRecoveredSigningVectorsAndAccountHeaders() throws {
        struct Evidence: Decodable {
            struct Vector: Decodable { let message: String; let signature: String; let session_signature: String }
            let synthetic_vectors: [Vector]
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "protocol-evidence", withExtension: "json"))
        let evidence = try JSONDecoder().decode(Evidence.self, from: Data(contentsOf: url))
        for vector in evidence.synthetic_vectors {
            XCTAssertEqual(WhitegramBackendProtocol.signature(message: vector.message, key: BackendFixture.applicationKey), vector.signature)
            XCTAssertEqual(WhitegramBackendProtocol.signature(message: vector.message, key: Data(0..<32)), vector.session_signature)
        }
        let fixture = BackendFixture()
        let (request, session) = try fixture.client.makeRequest(path: "/v1/profile/about", query: [URLQueryItem(name: "user_id", value: "42")])
        XCTAssertEqual(session?.userId, 42)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Whitegram synthetic-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-WG-Timestamp"), "1700000000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-WG-Sig"), evidence.synthetic_vectors[0].signature)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-WG-Session-Sig"), evidence.synthetic_vectors[0].session_signature)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-WG-Device-Sig"), "synthetic-device-signature:" + evidence.synthetic_vectors[0].message)
    }

    func testCanonicalQueryIsNotDecodedOrReordered() throws {
        let url = try XCTUnwrap(URL(string: WhitegramBackendProtocol.baseURL.absoluteString + "/v1/lyrics/search?q=a%2Bb%20c"))
        XCTAssertEqual(WhitegramBackendProtocol.canonicalMessage(url: url, method: "get", timestamp: 1700000000),
            "1700000000:GET:/v1/lyrics/search?q=a%2Bb%20c")
    }

    func testApplicationKeyConfigurationRequiresCanonicalBase64AndExactLength() throws {
        let encoded = BackendFixture.applicationKey.base64EncodedString()
        XCTAssertEqual(try WhitegramBackendProtocol.configuredApplicationKey(encoded: encoded), BackendFixture.applicationKey)
        let invalid: [Any?] = [nil, "", true, "invalid-private-key", encoded + "\n",
            Data(repeating: 1, count: 31).base64EncodedString(), Data(repeating: 1, count: 33).base64EncodedString()]
        for value in invalid {
            XCTAssertThrowsError(try WhitegramBackendProtocol.configuredApplicationKey(encoded: value)) { error in
                XCTAssertEqual(error as? WhitegramBackendError, .missingApplicationKey)
                XCTAssertFalse(error.localizedDescription.contains("invalid-private-key"))
            }
        }
    }

    func testMissingApplicationKeyStopsTheRequestBeforeTransport() {
        let fixture = BackendFixture()
        let client = WhitegramBackendClient(userId: 42, sessions: fixture.sessions, http: fixture.http,
            now: { fixture.date }, access: fixture.access, recordUsage: { _ in XCTFail("Unsent request counted as traffic") },
            applicationKey: { throw WhitegramBackendError.missingApplicationKey }, deviceSignature: { _ in nil })
        let done = expectation(description: "missing application key")
        client.raw(path: "/v1/profile/about") { result in
            XCTAssertEqual(result.failure, .missingApplicationKey)
            done.fulfill()
        }
        waitForExpectations(timeout: 3)
        XCTAssertTrue(fixture.http.calls.isEmpty)
    }

    func testRequestsRejectOffOriginTraversalAndHeaderInjection() throws {
        for path in ["https://other.example/v1/profile/about", "/v1/../auth", "/v1/./auth", "/v1//auth", "/v1/%2e%2e/auth", "/v1/auth?token=x", "/v1/auth#x", "/v1/\\auth"] {
            XCTAssertThrowsError(try WhitegramBackendProtocol.url(path: path))
        }
        let fixture = BackendFixture()
        XCTAssertThrowsError(try fixture.client.makeRequest(path: "/v1/profile/about", providerKey: "secret"))
        XCTAssertThrowsError(try fixture.client.makeRequest(path: "/v1/proxy/groq/openai/v1/models", providerKey: "key\r\nAuthorization: changed"))
        let request = try fixture.client.makeRequest(path: "/v1/proxy/groq/openai/v1/models", accept: "text/event-stream", providerKey: "provider-fixture").0
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Provider-Key"), "provider-fixture")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Whitegram synthetic-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    func testAuthInitDataIsDecodedOnceAndMustBeUnambiguous() throws {
        let url = "https://example.invalid/auth#tgWebAppData=user%3D%257B%2522id%2522%253A42%257D%26hash%3Dabc&tgWebAppVersion=8.0"
        XCTAssertEqual(try WhitegramBackendProtocol.webAppInitData(from: url), "user=%7B%22id%22%3A42%7D&hash=abc")
        XCTAssertThrowsError(try WhitegramBackendProtocol.webAppInitData(from: "https://example.invalid/?tgWebAppData=x#tgWebAppData=y"))
        XCTAssertThrowsError(try WhitegramBackendProtocol.webAppInitData(from: "https://example.invalid/#tgWebAppData="))
    }

    func testSessionResponseRejectsOtherAccountsMalformedKeysAndExpiry() throws {
        let good = Data(#"{"access_token":"fixture","expires_in":300,"user":{"id":42},"session_key":"AAECAwQ="}"#.utf8)
        let decoded = try JSONDecoder().decode(WhitegramBackendSessionResponse.self, from: good)
        XCTAssertEqual(try decoded.session(for: 42, now: Date(timeIntervalSince1970: 100)).expiresAt, Date(timeIntervalSince1970: 400))
        XCTAssertThrowsError(try decoded.session(for: 43, now: Date())) { XCTAssertEqual($0 as? WhitegramBackendError, .accountMismatch) }
        for (name, body) in [
            ("zero expiry", #"{"access_token":"fixture","expires_in":0,"user":{"id":42}}"#),
            ("malformed key", #"{"access_token":"fixture","expires_in":300,"user":{"id":42},"session_key":"not-base64"}"#),
            ("CR token", #"{"access_token":"bad\rtoken","expires_in":300,"user":{"id":42}}"#),
            ("LF token", #"{"access_token":"bad\ntoken","expires_in":300,"user":{"id":42}}"#),
            ("CRLF token", #"{"access_token":"bad\r\ntoken","expires_in":300,"user":{"id":42}}"#)
        ] {
            let response = try JSONDecoder().decode(WhitegramBackendSessionResponse.self, from: Data(body.utf8))
            XCTAssertThrowsError(try response.session(for: 42, now: Date()), name)
        }
    }

    func testSignedBetaVerdictChecksSignatureNonceIdentityAndTime() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(1...32))
        let nonce = String(repeating: "a", count: 32)
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        func verdict(allowed: Bool = true, issued: Int64 = 1_700_000_000, expires: Int64 = 1_700_000_300) throws -> WhitegramBackendAccessVerdict {
            let unsigned = WhitegramBackendAccessVerdict(userId: 42, allowed: allowed, issuedAt: issued, expiresAt: expires, nonce: nonce, signature: "")
            return WhitegramBackendAccessVerdict(userId: 42, allowed: allowed, issuedAt: issued, expiresAt: expires, nonce: nonce,
                signature: try key.signature(for: Data(unsigned.signedPayload.utf8)).base64EncodedString())
        }
        let value = try verdict()
        XCTAssertEqual(value.signedPayload, "whitegram.beta.status.v1|42|1|1700000000|1700000300|" + nonce)
        XCTAssertNoThrow(try value.validate(userId: 42, nonce: nonce, now: time, publicKey: key.publicKey.rawRepresentation))
        XCTAssertNoThrow(try verdict(allowed: false).validate(userId: 42, nonce: nonce, now: time, publicKey: key.publicKey.rawRepresentation))
        XCTAssertThrowsError(try value.validate(userId: 42, nonce: nonce, now: time)) // Test key is not the original trust anchor.
        XCTAssertThrowsError(try value.validate(userId: 43, nonce: nonce, now: time, publicKey: key.publicKey.rawRepresentation))
        XCTAssertThrowsError(try value.validate(userId: 42, nonce: String(repeating: "b", count: 32), now: time, publicKey: key.publicKey.rawRepresentation))
        XCTAssertThrowsError(try value.validate(userId: 42, nonce: nonce, now: time.addingTimeInterval(300), publicKey: key.publicKey.rawRepresentation))
        XCTAssertThrowsError(try verdict(issued: 1_700_000_121).validate(userId: 42, nonce: nonce, now: time, publicKey: key.publicKey.rawRepresentation))
        XCTAssertThrowsError(try verdict(expires: 1_700_000_601).validate(userId: 42, nonce: nonce, now: time, publicKey: key.publicKey.rawRepresentation))
    }

    func testBetaUnknownDeniedAndExpiryRemainDistinct() throws {
        let fixture = BackendFixture(allowed: nil)
        XCTAssertThrowsError(try fixture.client.makeRequest(path: "/v1/profile/about")) { XCTAssertEqual($0 as? WhitegramBackendError, .betaAccessUnknown) }
        XCTAssertNoThrow(try fixture.client.makeRequest(path: "/v1/status", authenticated: false))
        XCTAssertNoThrow(try fixture.client.makeRequest(path: "/v1/beta/status", authenticated: false))
        fixture.grantFixtureAccess(allowed: false)
        XCTAssertThrowsError(try fixture.client.makeRequest(path: "/v1/profile/about")) { XCTAssertEqual($0 as? WhitegramBackendError, .betaAccessDenied) }
        XCTAssertEqual(fixture.access.state(userId: 42, now: fixture.date.addingTimeInterval(31)), .unknown)
        fixture.grantFixtureAccess()
        XCTAssertNoThrow(try fixture.client.makeRequest(path: "/v1/profile/about"))
        fixture.date.addTimeInterval(601)
        XCTAssertEqual(fixture.access.state(userId: 42, now: fixture.date), .unknown)
        XCTAssertEqual(fixture.access.state(userId: 43, now: fixture.date), .unknown)
    }
}
