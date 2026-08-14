import XCTest
@testable import TovisKit

/// Two of Tori's standing rules, each with one implementation so a new call site
/// can't quietly break them:
///   • a price is a STARTING price — never a bare figure;
///   • every address is a maps link — and a booking has TWO possible addresses.
final class StartingPriceAndMapsLinkTests: XCTestCase {

    // MARK: - Starting prices

    func testAFormattedPriceAlwaysGetsTheWord() {
        XCTAssertEqual(StartingPrice.label("$250"), "From $250")
        XCTAssertEqual(StartingPrice.label("$45.50"), "From $45.50")
    }

    func testItIsIdempotentSoAServerThatSendsThePhraseIsSafe() {
        XCTAssertEqual(StartingPrice.label("From $250"), "From $250")
        XCTAssertEqual(StartingPrice.label("from $250"), "from $250")
    }

    func testNoPriceRendersNothingRatherThanAnEmptyPromise() {
        XCTAssertNil(StartingPrice.label(nil))
        XCTAssertNil(StartingPrice.label(""))
        XCTAssertNil(StartingPrice.label("   "))
    }

    func testARawWireAmountBecomesAStartingPrice() {
        XCTAssertEqual(StartingPrice.labelFromAmount("30.00"), "From $30")
        XCTAssertNil(StartingPrice.labelFromAmount(nil))
    }

    // MARK: - Maps links

    func testAPinnedAddressLinksByCoordinate() {
        let url = MapsLink.url(address: "215 Bedford Ave", lat: 40.7, lng: -73.9)
        XCTAssertEqual(
            url?.absoluteString,
            "https://www.google.com/maps/search/?api=1&query=40.7,-73.9"
        )
    }

    func testAnUnpinnedAddressLinksByItsText() {
        let url = MapsLink.url(address: "215 Bedford Ave, Brooklyn, NY 11211")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(
            url?.query?.contains("query=215%20Bedford%20Ave,%20Brooklyn,%20NY%2011211")
                ?? url?.query?.contains("215") ?? false,
            true,
            "the address text has to survive into the query: \(url?.absoluteString ?? "nil")"
        )
    }

    func testNothingToLocateIsNoLinkAtAll() {
        XCTAssertNil(MapsLink.url(address: nil))
        XCTAssertNil(MapsLink.url(address: ""))
        XCTAssertNil(MapsLink.url(address: "   "))
    }

    // MARK: - Which address a booking is going to

    func testTheSalonLineIsTheADDRESSNotTheSalonsName() throws {
        let json = """
        {
          "id": "loc_1",
          "type": "SALON",
          "name": "Noor Haddad Studio",
          "city": "Brooklyn",
          "state": "NY",
          "formattedAddress": "215 Bedford Ave, Brooklyn, NY 11211",
          "isPrimary": true
        }
        """
        let option = try JSONDecoder().decode(
            AvailabilityLocationOption.self, from: Data(json.utf8)
        )

        XCTAssertEqual(option.addressLine, "215 Bedford Ave, Brooklyn, NY 11211")
        XCTAssertNotEqual(option.addressLine, option.name)
    }

    func testASalonWithNoStreetAddressFallsBackToItsCityNotItsName() throws {
        let json = """
        { "id": "loc_2", "name": "Studio B", "city": "Brooklyn", "state": "NY",
          "formattedAddress": null }
        """
        let option = try JSONDecoder().decode(
            AvailabilityLocationOption.self, from: Data(json.utf8)
        )

        XCTAssertEqual(option.addressLine, "Brooklyn, NY")
    }

    func testASalonWithNothingToLocateHasNoAddressLine() throws {
        let json = """
        { "id": "loc_3", "name": "Studio C", "city": null, "state": null,
          "formattedAddress": null }
        """
        let option = try JSONDecoder().decode(
            AvailabilityLocationOption.self, from: Data(json.utf8)
        )

        XCTAssertNil(option.addressLine)
        XCTAssertNil(MapsLink.url(address: option.addressLine))
    }
}
