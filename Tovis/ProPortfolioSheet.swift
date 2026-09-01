// One tap on a tile opens the sheet that matches its STATE, so the pro never
// meets a control the server would refuse:
//
//   held    → the consent sheet (names the client, offers the only real action)
//   private → the publish sheet (states where it lands before it lands there)
//   public  → the manage sheet (its numbers, then take-down)
//
// Take-down costs one more deliberate tap than putting something up, so it is
// reached FROM manage rather than sitting beside it.
//
// Native twin of web `ProPortfolioSheets.tsx`; both drive the same endpoints
// (`POST`/`DELETE /api/v1/pro/media/{id}/portfolio`, `POST
// /api/v1/pro/bookings/{id}/aftercare/nudge`).
import SwiftUI
import TovisKit

struct ProPortfolioSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let tile: ProLibraryTile
    /// The taggable taxonomy the editor offers, carried by the library page so
    /// opening this sheet costs no round-trip.
    let serviceOptions: [ProLibraryServiceOption]
    var onChanged: () -> Void

    @State private var busy = false
    @State private var error: String?
    @State private var sent = false
    @State private var retracting = false
    @State private var editing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let hold = tile.hold {
                        consent(hold)
                    } else if !tile.isPublic {
                        publish
                    } else if retracting {
                        retract
                    } else {
                        manage
                    }

                    // Editing the asset is not publishing it, so it is offered
                    // on every face — including a held photo, whose caption and
                    // tags are the pro's own while they wait on the client.
                    if !retracting { editDetailsButton }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // 🔴 A drag inside the sheet SCROLLS its content instead of resizing the
        // sheet. Without this, the default (`.resizes`) swallows the gesture at
        // the medium detent, and "Edit details" — which now sits below Make
        // private — could not be reached at all without first grabbing the tiny
        // drag indicator. Verified in the simulator: with `.resizes`, neither a
        // content drag nor a grabber drag got to it.
        .presentationContentInteraction(.scrolls)
        .sheet(isPresented: $editing) {
            ProMediaEditSheet(tile: tile, serviceOptions: serviceOptions) {
                // A caption, tag, cover or delete change moves the library.
                onChanged()
                dismiss()
            }
        }
        .tint(BrandColor.accent)
    }

    /// What "My media" used to be a whole second screen for. Secondary styling
    /// throughout: the sheet's first job is the decision it was opened for.
    private var editDetailsButton: some View {
        Button { editing = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 13))
                Text("Edit details").font(BrandFont.body(13, .semibold))
            }
            .foregroundStyle(BrandColor.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    // MARK: - Header

    private func head(eyebrow: String, tint: Color, title: String, meta: String, dimmed: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 13) {
            MediaGridCell(aspectRatio: 3.0 / 4.0, cornerRadius: 13) {
                if let url = URL(string: tile.src) {
                    MediaGridImage(url: url)
                        .saturation(dimmed ? 0 : 1)
                        .opacity(dimmed ? 0.6 : 1)
                }
            }
            .frame(width: 74)

            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow.uppercased())
                    .font(BrandFont.mono(9))
                    .foregroundStyle(tint)
                Text(title)
                    .font(BrandFont.display(19, .bold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text(meta)
                    .font(BrandFont.body(12.5))
                    .foregroundStyle(BrandColor.textMuted)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Publish

    /// The three destinations are the actual consequence — the system welds
    /// portfolio-visibility and Looks-eligibility together anyway, so showing
    /// them as two independent toggles (as "My media" did) was a lie.
    @ViewBuilder
    private var publish: some View {
        head(
            eyebrow: "Publish",
            tint: BrandColor.accent,
            title: "This goes public.",
            meta: tile.caption ?? "Your work, out where clients can find it."
        )

        VStack(alignment: .leading, spacing: 0) {
            Text("WHERE IT APPEARS")
                .font(BrandFont.mono(9))
                .foregroundStyle(BrandColor.textMuted)
                .padding(.bottom, 6)
            destination("Your profile grid", "Anyone who opens your profile.")
            destination("The Looks feed & search", "Clients who’ve never heard of you can find it.")
            destination("Client boards", "They can save it and bring it to a booking.")
        }

        errorBanner

        primaryButton(busy ? "Publishing…" : "Publish to my portfolio") {
            await run { try await session.client.proProfile.setMediaFeaturedInPortfolio(mediaId: tile.id, featured: true) }
        }

        // Reversibility said at the point of the tap.
        Text("You can take it back down any time.")
            .font(BrandFont.body(12))
            .foregroundStyle(BrandColor.textMuted)
            .frame(maxWidth: .infinity)
    }

    private func destination(_ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Circle().fill(BrandColor.accent).frame(width: 6, height: 6).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(BrandFont.body(13.5, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text(body).font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .overlay(alignment: .top) { Rectangle().fill(BrandColor.textPrimary.opacity(0.10)).frame(height: 1) }
    }

    // MARK: - Consent

    /// A blocked photo names a PERSON, not a rule. The only honest action is to
    /// re-issue the aftercare — that is where the client ticks media use, so in
    /// this product "ask for permission" and "send the aftercare again" are the
    /// same act, and drawing them as two buttons would be a lie.
    @ViewBuilder
    private func consent(_ hold: ProLibraryConsentHold) -> some View {
        head(
            eyebrow: "Waiting on \(hold.clientFirstName)",
            tint: BrandColor.gold,
            title: "\(hold.clientFirstName) hasn’t said yes to this one.",
            meta: tile.caption ?? "Taken during their appointment.",
            dimmed: true
        )

        Text("Photos taken at the chair stay between you and your client. It becomes yours to publish the moment \(hold.clientFirstName) adds it to a review, or ticks media use in their aftercare.")
            .font(BrandFont.body(13))
            .foregroundStyle(BrandColor.textSecondary)
            .padding(15)
            .background(BrandColor.gold.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

        errorBanner

        // 🔴 One gate, computed server-side. The write boundary refuses for more
        // than one reason (no aftercare to re-send, and no email or phone on the
        // client — the ordinary shape of an unclaimed client a pro created by
        // hand), so re-deriving "can I nudge?" here would offer a button that
        // 500s for a whole class of real clients.
        if hold.canNudge, let bookingId = hold.bookingId {
            if sent {
                Text("Sent — it’s with \(hold.clientFirstName) now")
                    .font(BrandFont.body(14.5, .semibold))
                    .foregroundStyle(BrandColor.emerald)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(BrandColor.emerald.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                primaryButton(busy ? "Sending…" : "Send \(hold.clientFirstName) their aftercare again", dismissOnSuccess: false) {
                    try await session.client.proBookings.nudgeAftercare(bookingId: bookingId)
                    sent = true
                }
            }
        } else {
            Text(blockedCopy(hold))
                .font(BrandFont.body(12.5))
                .foregroundStyle(BrandColor.textMuted)
        }

        Text("Nothing is public until \(hold.clientFirstName) allows it.")
            .font(BrandFont.body(12))
            .foregroundStyle(BrandColor.textMuted)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }

    /// Each line names something the pro can go and DO — a generic refusal would
    /// leave them staring at a dimmed photo with no next step.
    private func blockedCopy(_ hold: ProLibraryConsentHold) -> String {
        switch hold.nudgeBlock {
        case .noContact:
            return "\(hold.clientFirstName) has no email or phone on file, so their aftercare can’t be sent. Add one to their client record first."
        case .noBooking:
            return "This one is private until your client releases it. There is no appointment attached, so there is nothing to re-send from here."
        default:
            return "Send \(hold.clientFirstName) their aftercare first — the media-use tick lives there."
        }
    }

    // MARK: - Manage

    /// 🔴 Six stats, not seven — "Remixes" is deliberately absent. Remix-clicks
    /// are explicitly UNTRACKED in this product, so a Remixes tile would be a
    /// number we invented. Views are job-incremented and therefore LAG, so the
    /// label stays plain.
    @ViewBuilder
    private var manage: some View {
        head(
            eyebrow: "Public",
            tint: BrandColor.accent,
            title: tile.caption ?? "Untitled photo",
            meta: "On your profile and in the Looks feed."
        )

        if let e = tile.engagement {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                statTile("Views", e.views)
                statTile("Likes", e.likes)
                statTile("Saves", e.saves)
                statTile("Comments", e.comments)
                statTile("Shares", e.shares)
                statTile("Booked", e.booked, gold: true)
            }
            Text("Booked means a client opened this photo and then booked you.")
                .font(BrandFont.body(11.5))
                .foregroundStyle(BrandColor.textMuted)
        }

        Button { retracting = true } label: {
            Text("Make private — take it off my profile")
                .font(BrandFont.body(14, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(BrandColor.textPrimary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func statTile(_ label: String, _ value: Int, gold: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(BrandFont.mono(8)).foregroundStyle(BrandColor.textMuted)
            Text("\(value)")
                .font(BrandFont.display(19, .bold))
                .foregroundStyle(gold ? BrandColor.gold : BrandColor.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BrandColor.textPrimary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Retract

    /// Counts what taking it down COSTS, in the client's terms rather than the
    /// database's — the saves are other people's boards, and they lose it.
    @ViewBuilder
    private var retract: some View {
        head(
            eyebrow: "Take down",
            tint: BrandColor.ember,
            title: "Take this back to only you?",
            meta: tile.caption ?? "It leaves everywhere clients can see it."
        )

        VStack(alignment: .leading, spacing: 0) {
            consequence("It leaves your profile grid and the Looks feed.", danger: true)
            if let saves = tile.engagement?.saves, saves > 0 {
                consequence("The \(saves) \(saves == 1 ? "client who saved" : "clients who saved") it to a board lose it.", danger: true)
            }
            consequence("The photo itself stays here, private. Nothing is deleted.", danger: false)
        }

        errorBanner

        HStack(spacing: 10) {
            Button { retracting = false } label: {
                Text("Keep it public")
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(BrandColor.textPrimary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                Task {
                    await run { try await session.client.proProfile.setMediaFeaturedInPortfolio(mediaId: tile.id, featured: false) }
                }
            } label: {
                Text(busy ? "Taking down…" : "Take it down")
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(BrandColor.ember)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
    }

    private func consequence(_ text: String, danger: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Circle()
                .fill(danger ? BrandColor.ember : BrandColor.textMuted)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            Text(text)
                .font(BrandFont.body(13.5))
                .foregroundStyle(danger ? BrandColor.textPrimary : BrandColor.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
    }

    // MARK: - Shared

    @ViewBuilder
    private var errorBanner: some View {
        if let error {
            Text(error)
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(BrandColor.ember)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(BrandColor.ember.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func primaryButton(
        _ label: String,
        dismissOnSuccess: Bool = true,
        _ action: @escaping () async throws -> Void
    ) -> some View {
        Button {
            Task { await run(dismissOnSuccess: dismissOnSuccess, action) }
        } label: {
            Text(label)
                .font(BrandFont.body(14.5, .semibold))
                .foregroundStyle(BrandColor.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(BrandColor.accent)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.7 : 1)
    }

    private func run(
        dismissOnSuccess: Bool = true,
        _ action: () async throws -> Void
    ) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }

        do {
            try await action()
            onChanged()
            if dismissOnSuccess { dismiss() }
        } catch let apiError as APIError {
            // The server's refusal IS the copy — it names the consent rule the
            // pro just met, which no local string could restate as accurately.
            error = apiError.userMessage
        } catch {
            self.error = "Something went wrong. Try again."
        }
    }
}
