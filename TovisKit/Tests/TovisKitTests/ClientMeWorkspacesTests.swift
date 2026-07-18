import Foundation
import Testing
@testable import TovisKit

// `ClientMeUser.availableWorkspaces` is the ONLY signal that tells a dual-role
// pro browsing as a client from a client-only account: the payload's `role` is
// the ACTING role (always "CLIENT" here) and the session JWT carries only that
// acting role too. It gates the client shell's "Switch to pro" row — the sole
// route back to the pro shell, which previously did not exist at all.
//
// The user objects below are VERBATIM captures from GET /api/v1/me against the
// local server on web #669 (a dual-role pro that had switched to the client
// workspace, and a client-only account), not hand-written guesses.

/// Captured: pro@tovis.app after POST /workspace/switch {"workspace":"CLIENT"}.
private let dualRoleUserJSON = """
{
  "id": "cmrbry4430001po0dc88meui6",
  "email": "pro@tovis.app",
  "phone": null,
  "role": "CLIENT",
  "availableWorkspaces": ["PRO", "CLIENT"],
  "createdAt": "2026-01-02T03:04:05.000Z",
  "phoneVerifiedAt": null,
  "emailVerifiedAt": null,
  "clientProfile": null
}
"""

/// Captured: client@tovis.app (no professional profile).
private let clientOnlyUserJSON = """
{
  "id": "client_1",
  "email": "client@tovis.app",
  "phone": null,
  "role": "CLIENT",
  "availableWorkspaces": ["CLIENT"],
  "createdAt": "2026-01-02T03:04:05.000Z",
  "phoneVerifiedAt": null,
  "emailVerifiedAt": null,
  "clientProfile": null
}
"""

/// The shape served by any deploy older than web #669 — the key is simply absent.
private let preFieldUserJSON = """
{
  "id": "client_1",
  "email": "client@tovis.app",
  "phone": null,
  "role": "CLIENT",
  "createdAt": "2026-01-02T03:04:05.000Z",
  "phoneVerifiedAt": null,
  "emailVerifiedAt": null,
  "clientProfile": null
}
"""

private func decodeUser(_ json: String) throws -> ClientMeUser {
    try JSONDecoder().decode(ClientMeUser.self, from: Data(json.utf8))
}

@Suite("ClientMeUser workspace entitlement")
struct ClientMeWorkspacesTests {
    @Test("a dual-role account acting as client is offered the pro switch")
    func dualRoleOffersPro() throws {
        let user = try decodeUser(dualRoleUserJSON)

        #expect(user.availableWorkspaces == [.pro, .client])
        #expect(user.canSwitchToPro)
    }

    @Test("a client-only account is not offered the pro switch")
    func clientOnlyWithholdsPro() throws {
        let user = try decodeUser(clientOnlyUserJSON)

        #expect(user.availableWorkspaces == [.client])
        #expect(user.canSwitchToPro == false)
    }

    @Test("an absent field decodes and hides the row, rather than throwing")
    func absentFieldDegradesQuietly() throws {
        // The row stays inert until web #669 deploys. The failure mode that
        // matters is the OTHER one: a non-optional field here would throw and
        // take the entire Me tab down against current production.
        let user = try decodeUser(preFieldUserJSON)

        #expect(user.availableWorkspaces == nil)
        #expect(user.canSwitchToPro == false)
    }

    @Test("an unrecognized workspace decodes to .unknown instead of throwing")
    func futureWorkspaceIsSurvivable() throws {
        let json = clientOnlyUserJSON.replacingOccurrences(
            of: "[\"CLIENT\"]",
            with: "[\"CLIENT\", \"AGENCY\"]"
        )

        let user = try decodeUser(json)

        #expect(user.availableWorkspaces == [.client, .unknown])
        // The unknown value must not be mistaken for pro entitlement.
        #expect(user.canSwitchToPro == false)
    }

    @Test("an ADMIN grant does not by itself unlock the pro row")
    func adminGrantAloneIsNotProEntitlement() throws {
        let json = clientOnlyUserJSON.replacingOccurrences(
            of: "[\"CLIENT\"]",
            with: "[\"ADMIN\", \"CLIENT\"]"
        )

        let user = try decodeUser(json)

        #expect(user.availableWorkspaces == [.admin, .client])
        #expect(user.canSwitchToPro == false)
    }
}
