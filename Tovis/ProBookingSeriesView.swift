// Pro recurring appointment — the native port of web `/pro/bookings/series/[id]`
// (K18–K20, Phase 8).
//
// Until K20 a standing appointment was invisible on the device the pro actually
// carries (K18-D/K19-D): the schema, the materializer, the create/cancel UI and
// the roll-forward all shipped on web with no fixture, no contract entry and no
// screen. A pro could have half a calendar of repeating work and no way to see
// what repeated, what had not been booked, or what would happen next.
//
// 🔴 The one thing this screen exists to say, and the reason it leads with it:
// A SERIES CAN HAVE MISSED DATES. A collision skips that occurrence and records
// it; a screen showing only the appointments it DID book tells the pro they got
// six when they got five ([[an-always-empty-key-looks-like-an-export]]). The
// headline is "5 of 6 dates booked", and the skips are named underneath in plain
// words with their code beside them.
//
// 🔴 Read-only, deliberately. Web has "cancel this and future" / "cancel all"
// here; this does not, and that is a scope decision rather than an oversight —
// a bulk cancel is the most destructive control in the pro app, its confirm
// panel has to carry "these 3 go, these 2 stay, and you are holding $80", and
// that panel is a screen of its own. Cancelling ONE occurrence already works on
// device, from the booking it belongs to. Recorded as K20-A.
import SwiftUI
import TovisKit

struct ProBookingSeriesView: View {
    @Environment(SessionModel.self) private var session
    let seriesId: String

    private enum Phase {
        case loading
        case loaded(ProBookingSeriesDetail)
        case failed(String)
    }

    @State private var phase: Phase = .loading

    var body: some View {
        ScrollView {
            switch phase {
            case .loading:
                ProgressView()
                    .tint(BrandColor.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            case .failed(let message):
                VStack(spacing: 10) {
                    Text("Couldn't load this recurring appointment")
                        .font(BrandFont.body(14, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(message)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Try again") { Task { await load() } }
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.accent)
                }
                .padding(.horizontal, 24)
                .padding(.top, 60)
            case .loaded(let series):
                content(series)
            }
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Recurring appointment")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ series: ProBookingSeriesDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(series)
            outcome(series)
            pricing(series)
            occurrences(series)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 40)
    }

    @ViewBuilder
    private func header(_ series: ProBookingSeriesDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(series.clientName ?? "Client")
                    .font(BrandFont.display(24, .bold))
                    .foregroundStyle(BrandColor.textPrimary)
                Spacer(minLength: 8)
                if let status = series.statusDisplay {
                    Text(status.label)
                        .font(BrandFont.mono(9))
                        .foregroundStyle(statusTone(status))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(statusTone(status).opacity(0.14))
                        .clipShape(Capsule())
                }
            }

            Text(
                [series.serviceName, series.cadenceLabel, series.plannedLabel]
                    .compactMap { $0 }
                    .joined(separator: " · ")
            )
            .font(BrandFont.body(13))
            .foregroundStyle(BrandColor.textSecondary)

            if let place = series.locationLabel {
                // The zone is the LOCATION's, and saying so matters: "every
                // Friday 9am" is 9am there, and a pro reading a date near
                // midnight in another zone would otherwise read a different day.
                Text("\(place)\(series.timeZone.map { " · times shown in \(friendlyZone($0))" } ?? "")")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
            }

            if let addOns = series.addOnNames, !addOns.isEmpty {
                Text("Add-ons: \(addOns.joined(separator: ", "))")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    /// 🔴 The headline, and the skips. See the file header.
    @ViewBuilder
    private func outcome(_ series: ProBookingSeriesDetail) -> some View {
        let booked = series.occurrenceRows.count
        let skips = series.skippedRows

        card {
            sectionTitle("What was booked")

            HStack(spacing: 4) {
                Text("\(booked) of \(series.attemptedCount) dates booked")
                    .font(BrandFont.body(15, .bold))
                    .foregroundStyle(BrandColor.textPrimary)
                if !skips.isEmpty {
                    Text("· \(skips.count) could not be booked")
                        .font(BrandFont.body(15, .bold))
                        .foregroundStyle(BrandColor.amber)
                }
            }

            ForEach(skips) { skip in
                VStack(alignment: .leading, spacing: 4) {
                    Text(skipTitle(skip, timeZone: series.timeZone))
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(skip.explanation)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                    // The code is DIAGNOSTIC — printed as a code, never dressed
                    // up as a sentence. It is what a pro reads out to support.
                    if let detail = skip.detail, skip.reason != .nonexistentLocalTime {
                        Text(detail)
                            .font(BrandFont.mono(9))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(BrandColor.bgPrimary)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(BrandColor.amber.opacity(0.35), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            // K20's roll-forward, stated. Rendered from the server's own
            // sentence-worth of facts and hidden entirely when it will not
            // continue — a negative restatement would read as a fault.
            if let sentence = series.rollForward?.sentence {
                Text(sentence)
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(BrandColor.bgPrimary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(BrandColor.accent.opacity(0.3), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    /// The PIN, and what it means. K20 decided that a rolled-forward occurrence
    /// is booked at occurrence 0's price, so this screen must say which of the
    /// two numbers the client is actually charged.
    @ViewBuilder
    private func pricing(_ series: ProBookingSeriesDetail) -> some View {
        if let pricing = series.pricing {
            card {
                sectionTitle("Price")

                Text(
                    Wire.moneyCents(pricing.pinnedTotalCents).map { "\($0) per appointment" }
                        ?? "Not priced"
                )
                .font(BrandFont.body(15, .bold))
                .foregroundStyle(BrandColor.textPrimary)

                Text(
                    "Every appointment in this series is booked at the price the client agreed to when it was set up"
                        + ((series.rollForward?.willContinue == true)
                            ? ", including the dates still to be added." : ".")
                )
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textSecondary)

                if pricing.showsListPriceComparison,
                    let current = Wire.moneyCents(pricing.currentListTotalCents)
                {
                    Text(
                        "Your current list price for this service is \(current). "
                            + "These appointments keep their agreed price — nothing has been repriced"
                            + ((series.rollForward?.willContinue == true)
                                ? ", and new dates will be booked at the agreed price too. To move this client to your current price, end this series and start a new one."
                                : ".")
                    )
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(BrandColor.bgPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if pricing.occurrencesDisagree == true {
                    Text(
                        "Some appointments in this series were booked at a different price to the first one."
                    )
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.amber)
                }
            }
        }
    }

    @ViewBuilder
    private func occurrences(_ series: ProBookingSeriesDetail) -> some View {
        card {
            sectionTitle("Appointments")

            ForEach(series.occurrenceRows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("#\(row.occurrenceNumber)")
                        .font(BrandFont.mono(10))
                        .foregroundStyle(BrandColor.textMuted)
                        .frame(width: 30, alignment: .leading)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(Wire.dateTime(row.scheduledFor, timeZone: series.timeZone))
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        HStack(spacing: 6) {
                            // Words, from the ONE label table — never the raw
                            // enum (the B10 rule).
                            Text(BookingStatusPresentation.label(row.status))
                                .font(BrandFont.mono(9))
                                .foregroundStyle(BrandColor.textSecondary)
                            if let money = Wire.moneyCents(row.bookedTotalCents) {
                                Text(money)
                                    .font(BrandFont.mono(9))
                                    .foregroundStyle(BrandColor.textMuted)
                            }
                            if row.depositHeldCents > 0,
                                let held = Wire.moneyCents(row.depositHeldCents)
                            {
                                Text("\(held) held")
                                    .font(BrandFont.mono(9))
                                    .foregroundStyle(BrandColor.gold)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(BrandColor.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(BrandFont.mono(9))
            .foregroundStyle(BrandColor.textMuted)
    }

    private func statusTone(_ status: ProBookingSeriesDetail.Status) -> Color {
        switch status {
        case .active: return BrandColor.accent
        case .ended: return BrandColor.textSecondary
        case .cancelled: return BrandColor.ember
        }
    }

    private func skipTitle(
        _ skip: ProBookingSeriesDetail.Skipped.Display,
        timeZone: String?
    ) -> String {
        if let instant = skip.intendedStart {
            return Wire.dateTime(instant, timeZone: timeZone)
        }
        // A DST gap has no instant — the wall clock that does not exist IS the
        // date, so it stands in for one rather than being hidden as a code.
        return skip.detail ?? "Date unavailable"
    }

    private func friendlyZone(_ identifier: String) -> String {
        TimeZone(identifier: identifier)
            .flatMap { $0.localizedName(for: .generic, locale: .current) }
            ?? identifier
    }

    // MARK: - Load

    private func load() async {
        phase = .loading
        do {
            let series = try await session.client.proBookings.series(seriesId: seriesId)
            phase = .loaded(series)
        } catch {
            phase = .failed(userFacingMessage(error))
        }
    }

    private func userFacingMessage(_ error: Error) -> String {
        if let apiError = error as? APIError { return apiError.userMessage }
        return error.localizedDescription
    }
}
