// TovisTests/NotificationHrefShapeContractTests.swift
//
// Holds `PushDeepLink`'s href parser to the set of hrefs tovis-app ACTUALLY
// emits — not to the subset someone remembered when they wrote the assertions.
//
// ── The weakness this closes ───────────────────────────────────────────────
//
// A notification row's href is written on the server and consumed here. The
// previous pinning was 48 per-href assertions, hand-written: they proved the
// parser agrees with whoever typed them, which is not the same claim as "the
// parser agrees with the server". Nothing failed when web added a shape — the
// `/client/*` and `/pro/*` switches answer anything unrecognised with
// `.clientHome` / `.proHome`, which are NOT nil, so the notification centre
// DISMISSES ITSELF ONTO HOME. A dead tap that looks like a working one.
//
// `Fixtures/notificationHrefShapes.json` is GENERATED on the web side from the
// registry every notification href must reduce to (a runtime assertion at every
// write boundary throws outside production if one does not). The same bytes are
// committed here. This test drives the REAL parser over every row.
//
// ── surface ────────────────────────────────────────────────────────────────
//
// Each row says what the phone is supposed to do, and the three answers fail
// differently on purpose:
//
//   native  a real screen. NOT nil, and NOT `.clientHome` / `.proHome` —
//           because those two are exactly what a silently-unrouted href looks
//           like, and `!= nil` alone would accept them.
//   shell   the role's home IS the destination (a bare `/client`). Asserted
//           positively so a shape cannot drift into this answer unnoticed.
//   web     a token-bearing flow only the web page can complete. The parser
//           must answer NIL. 🔴 This is the load-bearing case: nil leaves the
//           tap harmless, `.clientHome` dismisses the notification centre onto
//           Home and the client never reaches the page the notice was sent to
//           deliver. Nothing in the parser distinguishes the two intentions, so
//           the fixture has to.

import Foundation
import Testing

@testable import Tovis

private struct HrefShapeRow: Decodable {
    let shape: String
    let surface: String
    /// A concrete href built on the WEB side by substituting each `{…}`
    /// placeholder. Generated there, not composed here: a probe composed on
    /// this side would be the client agreeing with itself again — testing the
    /// href the phone thinks the shape means, rather than the one web mints.
    let probe: String
    let target: String?
    let why: String
}

private struct HrefShapeFixture: Decodable {
    let shapes: [HrefShapeRow]
}

@Suite struct NotificationHrefShapeContractTests {
    private static let fixture: HrefShapeFixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/notificationHrefShapes.json")
        // force-try: a missing fixture is a broken checkout, and failing loudly
        // beats every test below passing on zero rows.
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode(HrefShapeFixture.self, from: data)
    }()

    /// The two targets that mean "the parser did not recognise this".
    private static func isShell(_ target: PushDeepLink.Target) -> Bool {
        target == .clientHome || target == .proHome
    }

    /// 🔴 Guard the guard. Every other test here is a loop over `shapes`; an
    /// empty fixture would make all of them pass having checked nothing.
    @Test("The generated fixture is present and covers all three surfaces")
    func fixtureLoaded() {
        let rows = Self.fixture.shapes
        #expect(rows.count >= 30)
        #expect(Set(rows.map(\.shape)).count == rows.count, "duplicate shape in fixture")

        let surfaces = Set(rows.map(\.surface))
        #expect(surfaces == ["native", "shell", "web"], "unexpected surfaces: \(surfaces)")
        for required in ["native", "shell", "web"] {
            #expect(rows.contains { $0.surface == required }, "no \(required) rows")
        }
        // Every row explains itself; an unreasoned row is a guess the tests
        // below would then enshrine.
        for row in rows {
            #expect(!row.why.isEmpty, "\(row.shape) has no reason")
            #expect(row.probe.hasPrefix("/"), "\(row.shape) probe is not a path")
        }
    }

    /// 🔴 The assertion the whole contract exists for.
    ///
    /// A `native` shape must reach a real screen. `!= nil` is NOT enough: the
    /// parser's `default` arms return `.clientHome` / `.proHome`, so an
    /// unrouted `/client/whatever` is non-nil and would sail through a
    /// nil-check while dismissing the notification centre onto Home.
    @Test("Every native shape resolves to a real screen, not the home shell")
    func nativeShapesResolve() {
        for row in Self.fixture.shapes where row.surface == "native" {
            guard let link = PushDeepLink(href: row.probe) else {
                Issue.record(
                    """
                    \(row.shape) is declared `native` but the parser returned nil \
                    for \(row.probe). Expected \(row.target ?? "a screen"). \
                    Why web sends it: \(row.why)
                    """
                )
                continue
            }
            #expect(
                !Self.isShell(link.target),
                """
                \(row.shape) is declared `native` but \(row.probe) fell through to \
                \(String(describing: link.target)) — the home shell. A notification \
                carrying this href DISMISSES the notification centre onto Home \
                instead of opening \(row.target ?? "its destination"). \
                Why web sends it: \(row.why)
                """
            )
        }
    }

    /// 🔴 The other half, and the one a nil-check would never catch.
    ///
    /// A `web` shape is a tokenised flow the app cannot complete. The parser
    /// must decline it — returning `.clientHome` here is not a harmless
    /// approximation, it is the dead tap, because it closes the notification
    /// centre and drops the client on Home with no explanation.
    @Test("Every web-only shape is refused, so the tap stays harmless")
    func webOnlyShapesAreRefused() {
        for row in Self.fixture.shapes where row.surface == "web" {
            let link = PushDeepLink(href: row.probe)
            #expect(
                link == nil,
                """
                \(row.shape) is declared `web` — the phone must NOT claim it — but \
                the parser answered \(String(describing: link?.target)) for \
                \(row.probe). If that is the home shell, the notification centre \
                dismisses onto Home and the client never reaches the page. \
                Why it is web-only: \(row.why)
                """
            )
        }
    }

    /// `shell` asserted positively, so a shape cannot quietly become one.
    @Test("Every shell shape resolves to the role home, deliberately")
    func shellShapesResolveToHome() {
        for row in Self.fixture.shapes where row.surface == "shell" {
            guard let link = PushDeepLink(href: row.probe) else {
                Issue.record("\(row.shape) is declared `shell` but the parser returned nil")
                continue
            }
            #expect(
                Self.isShell(link.target),
                "\(row.shape) is declared `shell` but resolved to \(String(describing: link.target))"
            )
        }
    }

    /// The probes carry distinct ids per placeholder position (`id1`, `id2`, …)
    /// so a parser that grabbed the WRONG path segment produces a visibly wrong
    /// id rather than one that happens to look right. Check the ids actually
    /// land where the shape says they do, for the shapes that carry one.
    @Test("A parsed id comes from the placeholder position, not a neighbouring segment")
    func idsComeFromTheRightSegment() {
        let expectations: [(href: String, target: PushDeepLink.Target)] = [
            ("/client/bookings/id1", .booking(id: "id1", step: nil)),
            ("/client/bookings/id1?step=aftercare", .booking(id: "id1", step: "aftercare")),
            ("/client/bookings/id1#review", .booking(id: "id1", step: "review")),
            ("/client/consult/id1", .clientConsult(id: "id1")),
            ("/client/consult/id1/results", .clientConsult(id: "id1")),
            ("/client/boards/id1", .board(id: "id1")),
            ("/client/offers?accept=id1", .offers(accept: "id1")),
            ("/offerings/id1?openingId=id2", .opening(openingId: "id2")),
            ("/messages/thread/id1", .thread(id: "id1")),
            ("/looks/id1", .look(id: "id1", book: false)),
            ("/professionals/id1", .publicPro(professionalId: "id1")),
            ("/pro/bookings/id1", .proBooking(id: "id1", step: nil)),
            ("/pro/consults/id1", .proConsult(id: "id1")),
            ("/pro/reviews/id1", .proReviews(id: "id1")),
            ("/pro/reviews#review-id1", .proReviews(id: "id1")),
            ("/pro/clients/id1", .proClient(clientId: "id1")),
        ]
        for (href, target) in expectations {
            #expect(PushDeepLink(href: href)?.target == target, "\(href)")
        }
        // 🔴 /offerings takes its id from the QUERY, not the path — the probe's
        // distinct ids are what makes that visible. id2, never id1.
        #expect(PushDeepLink(href: "/offerings/id1?openingId=id2")?.target == .opening(openingId: "id2"))
    }
}
