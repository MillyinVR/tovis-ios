// Native "Submit a viral look" — the counterpart to the web SubmitViralLookForm
// (app/client/(gated)/_components/SubmitViralLookForm.tsx), which web renders as
// the third cell of the Viral Looks band. POSTs to /api/v1/viral-service-requests
// via ViralRequestsService; the created row comes back as REQUESTED and shows up
// in the band's "Your request" pipeline on the next home refresh.
//
// Deliberate deviation from web: web keeps the form inline in the band and shows
// an in-place "Submitted — our team is reviewing it now." notice. On iOS the band
// is the LAST section of a long home ScrollView that reloads itself every 30s
// (HomeView.poll), so an inline two-field form would put a keyboard over a list
// that moves underneath it. The band therefore carries a CTA card that presents
// this sheet, and the success confirmation is the band itself — dismissing lands
// on the freshly-loaded "Your request · Submitted" pipeline, a stronger receipt
// than a text notice. Same reasoning shape as the step-4 report confirmation.
import SwiftUI
import TovisKit

struct SubmitViralLookView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Called after a successful submit so the host can refresh home — the band's
    /// pending pipeline is where the person sees what they just submitted.
    let onSubmitted: () async -> Void

    @State private var draft = ViralLookDraft()
    @State private var submitting = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    intro

                    if let errorText {
                        Text(errorText)
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(BrandColor.ember)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(BrandColor.ember.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    // Web's field order: the link first, then the name.
                    sourceUrlField
                    nameField

                    // Web parity, and the only honest option here: web's button is
                    // disabled *only* while submitting — a blank name is refused on
                    // press with copy, not by greying out. SignupPrimaryButton has
                    // no visual disabled state (it renders full-accent either way),
                    // so gating on `canSubmit` would show a live-looking button that
                    // silently does nothing.
                    SignupPrimaryButton(
                        title: "Submit for review",
                        isLoading: submitting
                    ) {
                        Task { await submit() }
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Submit a viral look")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(BrandColor.textSecondary)
                        .disabled(submitting)
                }
            }
        }
        .tint(BrandColor.accent)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spotted a new one?".uppercased())
                .font(BrandFont.mono(10)).tracking(1.6)
                .foregroundStyle(BrandColor.textMuted)
            Text("Paste the link and name it. Our team vets it and shares it with pros before it goes live.")
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    private var sourceUrlField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SignupFieldLabel("Link")
                Text("optional")
                    .font(BrandFont.body(11))
                    .foregroundStyle(BrandColor.textMuted)
            }
            TextField(
                "",
                text: $draft.sourceUrl,
                prompt: Text("Paste TikTok / Instagram / Pinterest link…")
                    .foregroundStyle(BrandColor.textMuted)
            )
            .font(BrandFont.body(16))
            .foregroundStyle(BrandColor.textPrimary)
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .modifier(ViralFieldChrome())
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SignupFieldLabel("Name this look")
            TextField(
                "",
                text: $draft.name,
                prompt: Text("Glazed donut bob").foregroundStyle(BrandColor.textMuted)
            )
            .font(BrandFont.body(16))
            .foregroundStyle(BrandColor.textPrimary)
            .modifier(ViralFieldChrome())
            // Web gets this cap free from the input's maxLength={160}; SwiftUI has
            // no equivalent, so clamp as typed rather than let the server 400.
            .onChange(of: draft.name) { _, newValue in
                let clamped = ViralLookDraft.clampedName(newValue)
                if clamped != newValue { draft.name = clamped }
            }
            Text("Pros search by name — “Cherry cola balayage” beats “brown hair”.")
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textMuted)
        }
    }

    /// The route has no idempotency key and no rate limit (verified by driving it),
    /// so a double-tap would create a second request an admin has to moderate
    /// twice. `submitting` is the only thing preventing that — guard on it here as
    /// well as disabling the button, since the button is not the only way in.
    private func submit() async {
        guard !submitting else { return }
        // Web's own pre-flight refusal, same copy — the name is the one field the
        // server requires, and saying so beats a round trip to read it back.
        guard draft.canSubmit else {
            errorText = "Name the look so pros know what to match."
            return
        }
        submitting = true
        errorText = nil
        defer { submitting = false }

        do {
            guard try await session.client.viralRequests.submit(draft: draft) != nil else { return }
            await onSubmitted()
            dismiss()
        } catch let error as APIError {
            // Server validation copy is already user-facing ("sourceUrl must be a
            // valid URL." etc) — show it rather than a generic message.
            errorText = error.userMessage
        } catch {
            errorText = "Couldn’t submit your look. Try again."
        }
    }
}

/// The shared text-field chrome for this form (surface fill + hairline border),
/// matching the CreateBoardView fields.
private struct ViralFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16).padding(.vertical, 15)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
            )
    }
}
