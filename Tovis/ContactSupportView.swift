// Native port of the web support form (app/support/supportForm.tsx), backed by
// POST /api/v1/support/tickets via SupportService. Collects the same two fields
// the web form does — subject + message.
//
// This is a native form rather than a `SafariView` on `/support` (the way the
// Legal links work) because native auth is bearer-token and cookieless BY
// DESIGN: the web page attributes a ticket from its session cookie, which an
// in-app browser can never present, so every ticket filed that way would be
// anonymous — and `SupportTicket` has no contact column, leaving the admin queue
// with no way to reply. Filing through the API is what attaches the real user.
//
// Web also shows a contact-details block (business name / location / support
// email) sourced from `lib/brand`; the app has no brand-config counterpart, and
// hardcoding those strings would break the white-label rules, so it is omitted.
import SwiftUI
import TovisKit

struct ContactSupportView: View {
    @Environment(SessionModel.self) private var session

    @State private var subject = ""
    @State private var message = ""
    @State private var sending = false
    @State private var banner: Banner?

    /// Mirrors the backend's caps (lib/support/createSupportTicket.ts), so the
    /// server's SUBJECT_TOO_LONG / MESSAGE_TOO_LONG stay backstops rather than
    /// something a person can actually hit by typing.
    private let maxSubjectLength = 200
    private let maxMessageLength = 5000

    private struct Banner: Equatable {
        enum Kind { case success, error }
        let kind: Kind
        let text: String
    }

    private var canSubmit: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        form
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Get in touch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Report an issue, ask about your account, or get help with a booking. We respond to all inquiries.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)

                if let banner {
                    Text(banner.text)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(banner.kind == .success ? BrandColor.accent : BrandColor.ember)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background((banner.kind == .success ? BrandColor.accent : BrandColor.ember).opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                field("Subject") {
                    BrandField(
                        placeholder: "e.g. Booking not confirming",
                        text: $subject,
                        isSecure: false
                    )
                    .onChange(of: subject) {
                        if subject.count > maxSubjectLength {
                            subject = String(subject.prefix(maxSubjectLength))
                        }
                    }
                }

                field("Message") {
                    TextEditor(text: $message)
                        .frame(minHeight: 160)
                        .padding(8)
                        .scrollContentBackground(.hidden)
                        .background(BrandColor.bgSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .font(BrandFont.body(15))
                        .foregroundStyle(BrandColor.textPrimary)
                        .onChange(of: message) {
                            if message.count > maxMessageLength {
                                message = String(message.prefix(maxMessageLength))
                            }
                        }

                    Text("\(message.count)/\(maxMessageLength)")
                        .font(BrandFont.mono(11))
                        .foregroundStyle(BrandColor.textMuted)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                SignupPrimaryButton(
                    title: "Send request",
                    isLoading: sending,
                    isDisabled: !canSubmit
                ) {
                    Task { await send() }
                }

                Text("Please don’t include passwords, verification codes, or secret keys. We’ll get back to you as soon as we can, but response times may vary based on the volume of requests.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func field<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SignupFieldLabel(label)
            content()
        }
    }

    // MARK: - Submit

    private func send() async {
        guard !sending, canSubmit else { return }
        sending = true
        banner = nil
        defer { sending = false }

        do {
            _ = try await session.client.support.createTicket(
                subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
                message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            // Clear on success so the confirmation can't be mistaken for a draft
            // still waiting to send.
            subject = ""
            message = ""
            banner = Banner(kind: .success, text: "Thanks — your request is with our team.")
        } catch let error as APIError {
            banner = Banner(kind: .error, text: error.userMessage)
        } catch {
            banner = Banner(kind: .error, text: "Failed to send your request.")
        }
    }
}
