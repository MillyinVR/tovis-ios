import Foundation
import Testing
@testable import TovisKit

// "Offer services" — POST /api/v1/pro/upgrade, the client → pro door.
//
// The route has existed since web #987; native had no caller at all, so a client
// on the phone who decided to start taking bookings had to find a browser.
//
// Two things are only true here, and both are load-bearing:
//
//   1. The body carries what REGISTRATION's pro branch carries, minus what the
//      account already has. Those fields decide whether somebody may legally
//      take bookings, so a field silently dropped is a pro listed without a
//      credential nobody noticed was missing.
//   2. The re-minted token is PERSISTED. The upgrade flips the account's home
//      role to PRO and returns a fresh ACTIVE session saying so; the old JWT
//      still says CLIENT, and keeping it means the app goes on acting as a
//      client until it expires.

/// Its own capture protocol + statics, so this suite can't clobber a sibling's.
final class ProUpgradeURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var status = 201
    nonisolated(unsafe) static var responseBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedBody = Self.readBody(request)

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

@Suite(.serialized) struct ProUpgradeServiceTests {
    private static let okJSON = Data("""
    {"ok":true,"professionalId":"pro_new_1","token":"jwt.pro.minted",
     "verificationStatus":"PENDING","licenseVerified":false,
     "needsManualLicenseUpload":true,"manualLicensePendingReview":false,
     "nextUrl":"/pro/calendar"}
    """.utf8)

    private static let salon = ProSalonLocation(
        placeId: "place_1",
        formattedAddress: "1 Studio Way, San Diego, CA 92101",
        city: "San Diego",
        state: "CA",
        postalCode: "92101",
        countryCode: "US",
        lat: 32.7157,
        lng: -117.1611,
        timeZoneId: "America/Los_Angeles"
    )

    private static let base = ClientSignupLocation(
        postalCode: "92101",
        city: "San Diego",
        state: "CA",
        countryCode: "US",
        lat: 32.7157,
        lng: -117.1611,
        timeZoneId: "America/Los_Angeles"
    )

    private func makeAuth(
        tokenStoreService: String
    ) -> (AuthService, TokenStore) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProUpgradeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: tokenStoreService)
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return (AuthService(api: api, tokenStore: tokenStore), tokenStore)
    }

    private func reset(status: Int = 201, body: Data = okJSON) {
        ProUpgradeURLProtocol.capturedPath = nil
        ProUpgradeURLProtocol.capturedMethod = nil
        ProUpgradeURLProtocol.capturedBody = nil
        ProUpgradeURLProtocol.status = status
        ProUpgradeURLProtocol.responseBody = body
    }

    private func capturedJSON() throws -> [String: Any] {
        let data = try #require(ProUpgradeURLProtocol.capturedBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func aSalonUpgradeSendsTheProSalonLocationAndNoRadius() async throws {
        reset()
        let (auth, _) = makeAuth(tokenStoreService: "me.tovis.app.session.upgrade.salon")

        _ = try await auth.upgradeToPro(
            professionType: .cosmetologist,
            licenseState: "CA",
            businessName: "Studio Tori",
            handle: "tori",
            licenseNumber: "C123456",
            licenseExpiry: "2027-04-30",
            location: .salon(Self.salon)
        )

        #expect(ProUpgradeURLProtocol.capturedPath == "/api/v1/pro/upgrade")
        #expect(ProUpgradeURLProtocol.capturedMethod == "POST")

        let json = try capturedJSON()
        #expect(json["professionType"] as? String == "COSMETOLOGIST")
        #expect(json["licenseState"] as? String == "CA")
        #expect(json["businessName"] as? String == "Studio Tori")
        #expect(json["handle"] as? String == "tori")
        #expect(json["licenseNumber"] as? String == "C123456")
        #expect(json["licenseExpiry"] as? String == "2027-04-30")
        // A salon has no travel radius, and the route refuses a location it
        // cannot make sense of rather than coercing one.
        #expect(json["mobileRadiusMiles"] == nil)

        let location = try #require(json["signupLocation"] as? [String: Any])
        #expect(location["kind"] as? String == "PRO_SALON")
        #expect(location["placeId"] as? String == "place_1")
        #expect(location["formattedAddress"] as? String == "1 Studio Way, San Diego, CA 92101")
        #expect(location["timeZoneId"] as? String == "America/Los_Angeles")
    }

    @Test func aMobileUpgradeSendsTheBaseZipAndTheRadius() async throws {
        reset()
        let (auth, _) = makeAuth(tokenStoreService: "me.tovis.app.session.upgrade.mobile")

        _ = try await auth.upgradeToPro(
            professionType: .lashTechnician,
            licenseState: "CA",
            businessName: nil,
            handle: nil,
            licenseNumber: nil,
            licenseExpiry: nil,
            location: .mobile(Self.base, radiusMiles: 25)
        )

        let json = try capturedJSON()
        #expect(json["mobileRadiusMiles"] as? Int == 25)
        // nil omits the key entirely — the route treats an absent optional and
        // an empty string differently (a blank handle is not a handle claim).
        #expect(json["businessName"] == nil)
        #expect(json["handle"] == nil)
        #expect(json["licenseNumber"] == nil)
        #expect(json["licenseExpiry"] == nil)

        let location = try #require(json["signupLocation"] as? [String: Any])
        #expect(location["kind"] as? String == "PRO_MOBILE")
        #expect(location["postalCode"] as? String == "92101")
        #expect(location["placeId"] == nil)
    }

    /// 🔴 The one that decides whether the upgrade APPEARS to work. The route
    /// re-mints the session with the PRO acting role; drop the save and every
    /// following request replays a JWT that still says CLIENT, so the pro shell
    /// mounts and then 403s on everything inside it.
    @Test func theReMintedProTokenIsPersisted() async throws {
        reset()
        let (auth, tokenStore) = makeAuth(
            tokenStoreService: "me.tovis.app.session.upgrade.token"
        )
        await tokenStore.save("jwt.client.old")

        let response = try await auth.upgradeToPro(
            professionType: .barber,
            licenseState: "NY",
            businessName: nil,
            handle: nil,
            licenseNumber: "B99",
            licenseExpiry: nil,
            location: .salon(Self.salon)
        )

        #expect(response.professionalId == "pro_new_1")
        #expect(response.token == "jwt.pro.minted")
        #expect(await tokenStore.token() == "jwt.pro.minted")

        await tokenStore.clear()
    }

    @Test func theResponseCarriesTheLicenceReviewState() async throws {
        reset()
        let (auth, tokenStore) = makeAuth(
            tokenStoreService: "me.tovis.app.session.upgrade.licence"
        )

        let response = try await auth.upgradeToPro(
            professionType: .cosmetologist,
            licenseState: "CA",
            businessName: nil,
            handle: nil,
            licenseNumber: "C1",
            licenseExpiry: nil,
            location: .salon(Self.salon)
        )

        #expect(response.verificationStatus == "PENDING")
        #expect(response.licenseVerified == false)
        #expect(response.needsManualLicenseUpload == true)
        #expect(response.manualLicensePendingReview == false)

        await tokenStore.clear()
    }

    /// 🔴 ALREADY_PRO is the one refusal a retry cannot fix, so the CODE has to
    /// reach the caller — not just the sentence. The caller uses it to stop
    /// offering the form and move the person into the workspace that already
    /// exists; matching on the message instead would break on a copy edit.
    @Test func theAlreadyProCodeReachesTheCaller() async throws {
        reset(
            status: 409,
            body: Data(
                #"{"ok":false,"error":"This account already has a professional profile.","code":"ALREADY_PRO"}"#
                    .utf8
            )
        )
        let (auth, _) = makeAuth(tokenStoreService: "me.tovis.app.session.upgrade.already")

        do {
            _ = try await auth.upgradeToPro(
                professionType: .cosmetologist,
                licenseState: "CA",
                businessName: nil,
                handle: nil,
                licenseNumber: "C1",
                licenseExpiry: nil,
                location: .salon(Self.salon)
            )
            Issue.record("expected the 409 to throw")
        } catch let error as APIError {
            guard case let .server(status, message, code) = error else {
                Issue.record("expected .server, got \(error)")
                return
            }
            #expect(status == 409)
            #expect(code == "ALREADY_PRO")
            #expect(message == "This account already has a professional profile.")
        }
    }

    /// A refusal must NOT overwrite the client session. The old token is still
    /// the only one this person has.
    @Test func aRefusalLeavesTheExistingSessionAlone() async throws {
        reset(
            status: 409,
            body: Data(#"{"ok":false,"error":"That handle is taken.","code":"HANDLE_TAKEN"}"#.utf8)
        )
        let (auth, tokenStore) = makeAuth(
            tokenStoreService: "me.tovis.app.session.upgrade.refusal"
        )
        await tokenStore.save("jwt.client.old")

        _ = try? await auth.upgradeToPro(
            professionType: .cosmetologist,
            licenseState: "CA",
            businessName: nil,
            handle: "taken",
            licenseNumber: "C1",
            licenseExpiry: nil,
            location: .salon(Self.salon)
        )

        #expect(await tokenStore.token() == "jwt.client.old")

        await tokenStore.clear()
    }
}
