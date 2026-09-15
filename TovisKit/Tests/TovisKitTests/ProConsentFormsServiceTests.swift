import Foundation
import Testing
@testable import TovisKit

// The pro's consent form LIBRARY:
//   • library        → GET   /pro/consent-forms
//   • create         → POST  /pro/consent-forms       { kind, title, body }
//   • adoptTemplate  → POST  /pro/consent-forms       { sourceTemplateId }
//   • publishVersion → POST  /pro/consent-forms/{id}/versions { title, body }
//   • setActive      → PATCH /pro/consent-forms/{id}  { isActive }
//
// K14 shipped those three write routes and NO read route, so the whole
// authoring surface lived inside one web page — the app could attach a form to
// a chart and text a signing link, and could not create one anywhere.
//
// 🔴 The pair of cases that carry the model: `adoptTemplate` must send
// `sourceTemplateId` and NOTHING else (the route branches on that key alone — a
// stray `kind` alongside it is a different request), and `publishVersion` must
// go to the `/versions` child, never `PATCH` the form. Publishing into the form
// itself is the one thing the whole append-only design exists to prevent.

/// Own statics, so this suite can't collide with a sibling suite's mock.
final class ProConsentFormsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedBody = request.httpBody
            ?? request.httpBodyStream.map { stream in
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

        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct ProConsentFormsServiceTests {
    private func makeService() async -> ProConsentFormsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProConsentFormsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.proconsentforms.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProConsentFormsService(api: api)
    }

    private func reset(status: Int = 200, body: String = "{\"ok\":true}") {
        ProConsentFormsURLProtocol.capturedPath = nil
        ProConsentFormsURLProtocol.capturedMethod = nil
        ProConsentFormsURLProtocol.capturedBody = nil
        ProConsentFormsURLProtocol.status = status
        ProConsentFormsURLProtocol.responseBody = Data(body.utf8)
    }

    private func capturedJSON() throws -> [String: Any] {
        let data = try #require(ProConsentFormsURLProtocol.capturedBody)
        return try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    // MARK: - Read

    @Test func libraryDecodesTheServedFixture() async throws {
        reset(body: String(decoding: try fixture("proConsentForms"), as: UTF8.self))

        let library = try await makeService().library()

        #expect(ProConsentFormsURLProtocol.capturedPath == "/api/v1/pro/consent-forms")
        #expect(ProConsentFormsURLProtocol.capturedMethod == "GET")

        #expect(library.forms.count == 3)
        #expect(library.templates.count == 2)
        // On the wire, not a Swift constant — a device holding its own copy of
        // these disagrees with the server the day one moves.
        #expect(library.limits.titleMax == 200)
        #expect(library.limits.bodyMax == 20_000)

        let waiver = try #require(library.forms.first)
        #expect(waiver.kind == "SERVICE_WAIVER")
        #expect(waiver.isActive)
        #expect(waiver.originLabel == "Written by you")
        #expect(waiver.versionCount == 2)
        #expect(waiver.signatureCount == 3)
        #expect(waiver.currentVersion?.version == 2)
        #expect(waiver.currentVersion?.title == "Corrective colour waiver")
    }

    /// 🔴 The flat-shape case. A template is a FORM object with one extra key,
    /// and `ProConsentFormTemplate` decodes the shared fields through
    /// `ProConsentFormLibraryItem` from the same container. Get that wrong and
    /// `form` decodes empty or `adopted` is lost — and a lost `adopted` re-offers
    /// a template the pro already holds, which the route then 409s.
    @Test func aTemplateCarriesBothItsFormAndWhetherItWasAdopted() async throws {
        reset(body: String(decoding: try fixture("proConsentForms"), as: UTF8.self))

        let library = try await makeService().library()
        let adopted = try #require(library.templates.first { $0.adopted })
        let offered = try #require(library.templates.first { !$0.adopted })

        #expect(adopted.form.origin == "PLATFORM_TEMPLATE")
        #expect(adopted.form.currentVersion?.title == "General consent")
        #expect(adopted.id == adopted.form.id)

        #expect(offered.form.kind == "PATCH_TEST")
        #expect(offered.form.currentVersion?.version == 2)
    }

    /// The gate, not a fault. An empty library is a 200 with empty arrays; a
    /// surface that showed the 404 the same way would tell an ungated pro they
    /// have no forms rather than that the feature is off.
    @Test func the404WhileTheGateIsOffSurfacesAsAServerError() async throws {
        reset(status: 404, body: #"{"ok":false,"error":"Not found."}"#)

        await #expect(throws: APIError.self) {
            _ = try await makeService().library()
        }
    }

    @Test func anEmptyLibraryIsAnAnswer() async throws {
        reset(body: #"{"ok":true,"forms":[],"templates":[],"limits":{"titleMax":200,"bodyMax":20000}}"#)

        let library = try await makeService().library()
        #expect(library.forms.isEmpty)
        #expect(library.templates.isEmpty)
        #expect(library.limits.bodyMax == 20_000)
    }

    // MARK: - Writes

    @Test func createPostsTheKindAndTheTextAsTyped() async throws {
        reset()

        try await makeService().create(
            kind: "SERVICE_WAIVER",
            title: "  Corrective colour waiver  ",
            body: "Line one\r\nLine two"
        )

        #expect(ProConsentFormsURLProtocol.capturedPath == "/api/v1/pro/consent-forms")
        #expect(ProConsentFormsURLProtocol.capturedMethod == "POST")

        let json = try capturedJSON()
        #expect(json["kind"] as? String == "SERVICE_WAIVER")
        // 🔴 Sent VERBATIM. The server canonicalizes (line endings, surrounding
        // blank lines, the title flattened to one line) and that is where the
        // rule lives — a client that pre-trimmed would be a second, drifting
        // copy of it, and indentation inside a numbered clause is meaningful.
        #expect(json["title"] as? String == "  Corrective colour waiver  ")
        #expect(json["body"] as? String == "Line one\r\nLine two")
        #expect(json["sourceTemplateId"] == nil)
    }

    /// 🔴 `sourceTemplateId` and nothing else. The create route branches on that
    /// key alone — with it present it adopts and ignores the rest, so a body
    /// carrying a `kind` too is a request that reads as something it isn't.
    @Test func adoptSendsOnlyTheTemplateId() async throws {
        reset()

        try await makeService().adoptTemplate(templateId: "tpl_1")

        #expect(ProConsentFormsURLProtocol.capturedPath == "/api/v1/pro/consent-forms")
        #expect(ProConsentFormsURLProtocol.capturedMethod == "POST")

        let json = try capturedJSON()
        #expect(json["sourceTemplateId"] as? String == "tpl_1")
        #expect(json["kind"] == nil)
        #expect(json["title"] == nil)
        #expect(json["body"] == nil)
    }

    /// 🔴 The one that protects the whole model. "Editing" a form is a POST to
    /// its `/versions` child, which publishes n+1 and leaves every earlier
    /// version alone. A PATCH at the form itself would be an attempt to rewrite
    /// words a client has already signed.
    @Test func publishingAVersionPostsToTheVersionsChild() async throws {
        reset()

        try await makeService().publishVersion(
            formId: "form_1", title: "Corrective colour waiver", body: "New words."
        )

        #expect(
            ProConsentFormsURLProtocol.capturedPath
                == "/api/v1/pro/consent-forms/form_1/versions"
        )
        #expect(ProConsentFormsURLProtocol.capturedMethod == "POST")

        let json = try capturedJSON()
        #expect(json["title"] as? String == "Corrective colour waiver")
        #expect(json["body"] as? String == "New words.")
    }

    @Test func retiringPatchesTheFormItself() async throws {
        reset()

        try await makeService().setActive(formId: "form_1", isActive: false)

        #expect(ProConsentFormsURLProtocol.capturedPath == "/api/v1/pro/consent-forms/form_1")
        #expect(ProConsentFormsURLProtocol.capturedMethod == "PATCH")
        #expect(try capturedJSON()["isActive"] as? Bool == false)
    }

    @Test func puttingAFormBackInUseSendsTrue() async throws {
        reset()

        try await makeService().setActive(formId: "form_9", isActive: true)

        #expect(ProConsentFormsURLProtocol.capturedPath == "/api/v1/pro/consent-forms/form_9")
        #expect(try capturedJSON()["isActive"] as? Bool == true)
    }

    /// "Nothing changed — this is already the current text." is the server's
    /// sentence, and it has to reach the pro intact: it is the only thing that
    /// explains why a save did nothing.
    @Test func aRefusedRepublishCarriesTheServersOwnSentence() async throws {
        reset(
            status: 409,
            body: #"{"ok":false,"error":"Nothing changed — this is already the current text."}"#
        )

        do {
            try await makeService().publishVersion(
                formId: "form_1", title: "Same", body: "Same"
            )
            Issue.record("expected the 409 to throw")
        } catch let error as APIError {
            #expect(error.userMessage == "Nothing changed — this is already the current text.")
        }
    }
}
