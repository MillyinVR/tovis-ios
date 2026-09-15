// The work-location rules shared by the two doors that can create a
// ProfessionalProfile: pro SIGNUP and "Offer services".
//
// 🔴 Why these are worth a test rather than a read-through: a confirmed location
// is a pair of COORDINATES, and everything downstream — the booking radius,
// "pros near you", the timezone every appointment is rendered in — is measured
// from them. The text in the field is not the location; it is what was typed
// before the coordinates were fetched. So the moment a character changes, the
// old confirmation is a lie, and this model's job is to make it impossible to
// submit one.
//
// Both screens now share this, which is the other half of the point: a fork in
// the location picker is how one signup door quietly stops asking.
import Foundation
import Testing
import TovisKit
@testable import Tovis

/// An offline Places stub: every request answers with no predictions. The
/// autocomplete path is debounced and fire-and-forget, so this exists to keep it
/// from reaching the network, not to be asserted on.
final class ProWorkLocationPlacesURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true,"predictions":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite @MainActor struct ProWorkLocationModelTests {
    private func offlinePlaces() -> PlacesService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProWorkLocationPlacesURLProtocol.self]
        return PlacesService(
            api: APIClient(
                config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
                session: URLSession(configuration: configuration),
                tokenStore: TokenStore(service: "me.tovis.app.session.workloc.tests")
            )
        )
    }

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

    @Test func anUnconfirmedLocationCannotBeSubmitted() {
        let model = ProWorkLocationModel()
        model.query = "1 Studio Way"

        #expect(model.isConfirmed == false)
        #expect(model.signupLocation() == nil)
        #expect(model.validate() == "Please choose your address from the list.")
    }

    @Test func aConfirmedSalonBecomesASalonPayload() throws {
        let model = ProWorkLocationModel()
        model.confirmedSalon = Self.salon

        #expect(model.isConfirmed)
        #expect(model.validate() == nil)

        guard case let .salon(resolved)? = model.signupLocation() else {
            Issue.record("expected a salon payload")
            return
        }
        #expect(resolved.placeId == "place_1")
        #expect(resolved.timeZoneId == "America/Los_Angeles")
    }

    @Test func aConfirmedZipBecomesAMobilePayloadWithItsRadius() {
        let model = ProWorkLocationModel()
        model.setMode(.mobile)
        model.confirmedMobile = Self.base
        model.radiusMiles = "25"

        #expect(model.validate() == nil)

        guard case let .mobile(resolved, miles)? = model.signupLocation() else {
            Issue.record("expected a mobile payload")
            return
        }
        #expect(resolved.postalCode == "92101")
        #expect(miles == 25)
    }

    /// 🔴 The case the whole model exists for. Typing after confirming leaves
    /// the field reading like a real address while the coordinates behind it
    /// belong to a DIFFERENT place. Submitting that is how a pro ends up taking
    /// bookings measured from somewhere they have never been.
    @Test func editingAfterConfirmingInvalidatesTheConfirmation() {
        let model = ProWorkLocationModel()
        model.confirmedSalon = Self.salon
        #expect(model.isConfirmed)

        model.queryChanged("1 Studio Way, Suite 4", places: offlinePlaces())

        #expect(model.isConfirmed == false)
        #expect(model.signupLocation() == nil)
    }

    /// Switching salon ⇄ mobile clears everything: a confirmed salon address is
    /// not a base ZIP, and carrying one across the toggle would submit the wrong
    /// kind of location under the right-looking label.
    @Test func switchingModeClearsTheOtherModesAnswer() {
        let model = ProWorkLocationModel()
        model.query = "1 Studio Way"
        model.confirmedSalon = Self.salon

        model.setMode(.mobile)

        #expect(model.query.isEmpty)
        #expect(model.confirmedSalon == nil)
        #expect(model.confirmedMobile == nil)
        #expect(model.isConfirmed == false)
    }

    @Test func settingTheSameModeChangesNothing() {
        let model = ProWorkLocationModel()
        model.confirmedSalon = Self.salon

        model.setMode(.salon)

        #expect(model.confirmedSalon != nil)
    }

    // MARK: - Radius

    /// The bounds the backend enforces. A radius outside them is refused here so
    /// the pro is told at the field rather than after a round trip.
    @Test func theRadiusMustBeBetweenOneAndTwoHundredMiles() {
        let model = ProWorkLocationModel()
        model.setMode(.mobile)
        model.confirmedMobile = Self.base

        for bad in ["0", "201", "", "fifteen", "-5"] {
            model.radiusMiles = bad
            #expect(
                model.validate() == "Please enter a mobile radius between 1 and 200 miles.",
                "expected \(bad) to be refused"
            )
            #expect(model.signupLocation() == nil, "expected \(bad) to build no payload")
        }

        for good in ["1", "15", "200"] {
            model.radiusMiles = good
            #expect(model.validate() == nil, "expected \(good) to pass")
        }
    }

    /// A salon has no radius, so a leftover value in the field must not leak
    /// into the payload or block a valid submit.
    @Test func aSalonIgnoresTheRadiusField() {
        let model = ProWorkLocationModel()
        model.confirmedSalon = Self.salon
        model.radiusMiles = "999"

        #expect(model.validate() == nil)
        guard case .salon? = model.signupLocation() else {
            Issue.record("expected a salon payload")
            return
        }
    }

    /// The mobile arm names the ZIP, not the address list — being told to "pick
    /// from the list" while looking at a ZIP field is an instruction that cannot
    /// be followed.
    @Test func theUnconfirmedMessageMatchesTheModeOnScreen() {
        let model = ProWorkLocationModel()
        model.setMode(.mobile)

        #expect(model.validate() == "Please confirm your base ZIP code.")
    }
}
