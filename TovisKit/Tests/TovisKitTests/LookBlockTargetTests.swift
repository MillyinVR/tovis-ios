import Foundation
import Testing
@testable import TovisKit

// Pins WHO "block this person" means for a given look (App Store guideline 1.2).
//
// 🔴 This is the ambiguity the whole feature turns on. A look carries up to two
// people, and `professional` is the ORIGIN pro — it stays set even on a
// client-authored look. So the obvious implementation ("block the look's pro")
// blocks the wrong person on exactly the posts where a viewer is most likely to
// want the control: a stranger's client-authored post. These tests fail if that
// precedence is ever flipped.
@Suite struct LookBlockTargetTests {

    private func item(professionalId: String?, clientAuthorHandle: String?) throws -> LooksFeedItem {
        let pro = professionalId.map {
            """
            {
              "id": "\($0)",
              "businessName": "Noor Haddad",
              "firstName": null, "lastName": null, "handle": "demo-noor",
              "nameDisplay": null, "professionType": null, "professionLabel": null,
              "avatarUrl": null, "location": null, "followerCount": 0
            }
            """
        } ?? "null"
        let author = clientAuthorHandle.map {
            #"{ "handle": "\#($0)", "avatarUrl": null, "profileHref": null }"#
        } ?? "null"

        let json = """
        {
          "id": "look_1",
          "url": "https://example.test/a.jpg",
          "thumbUrl": null,
          "mediaType": "IMAGE",
          "caption": null,
          "createdAt": "2026-08-20T00:00:00.000Z",
          "professional": \(pro),
          "clientAuthor": \(author),
          "_count": { "likes": 0, "comments": 0 },
          "viewerLiked": false,
          "viewerSaved": false,
          "viewerFollows": false,
          "serviceId": null,
          "serviceName": null,
          "category": null,
          "priceStartingAt": null,
          "focalX": null,
          "focalY": null,
          "before": null,
          "tags": null
        }
        """
        return try JSONDecoder().decode(LooksFeedItem.self, from: Data(json.utf8))
    }

    @Test func proAuthoredLookTargetsTheProfessionalById() throws {
        let look = try item(professionalId: "pro_1", clientAuthorHandle: nil)
        #expect(look.blockTarget == .professional(id: "pro_1"))
        #expect(look.blockTargetName == "Noor Haddad")
    }

    /// 🔴 THE regression guard. Both are present — the publisher must win.
    @Test func clientAuthoredLookTargetsTheCLIENT_notTheOriginPro() throws {
        let look = try item(professionalId: "pro_1", clientAuthorHandle: "maya-reyes")

        // Blocking the pro here would block someone the viewer never chose, and
        // leave the person who actually posted still visible.
        #expect(look.blockTarget == .handle("maya-reyes"))
        #expect(look.blockTarget != .professional(id: "pro_1"))
        #expect(look.blockTargetName == "@maya-reyes")
    }

    /// The control is hidden rather than sending a request that names nobody.
    @Test func aLookWithNeitherAuthorHasNoTarget() throws {
        let look = try item(professionalId: nil, clientAuthorHandle: nil)
        #expect(look.blockTarget == nil)
        #expect(look.blockTargetName == nil)
    }

    /// The request body carries exactly one key, and the right one.
    @Test func targetSerializesToExactlyOneKey() {
        #expect(BlockTarget.professional(id: "pro_1").requestBody == ["professionalId": "pro_1"])
        #expect(BlockTarget.handle("maya-reyes").requestBody == ["handle": "maya-reyes"])
    }
}
