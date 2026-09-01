import Foundation

/// Book the Look, B8 — what a look's Book button does, on the device.
///
/// The Swift twin of tovis-app `lib/consult/lookBookEntry.client.ts`, and ONE
/// implementation for both look surfaces (the feed slide and the single-look
/// detail) for the same reason the web has one: they render the same button and
/// would otherwise grow two answers to the same question. `LookBooking` already
/// exists for exactly that reason on the offering side; this is its consult
/// half.
///
/// The decision is the SERVER's. `GET /client/consult/look/availability`
/// applies the founder gate, look visibility and the pilot vertical, and
/// answers `available: false` with no reason when the pilot is dark for that
/// pro — indistinguishable from a client who simply has no consult. Nothing
/// here re-derives any part of it.
///
/// It is asked ON TAP, never on render: a probe per feed slide would put two
/// database reads in front of every scroll for every viewer, pilot or not, on
/// the hottest surface in the app.
///
/// 🔴 Anything other than a clear "yes" returns nil, and the caller keeps
/// today's behaviour EXACTLY — it opens the ordinary booking sheet. That is
/// what makes this safe to ship against a production server where none of
/// these endpoints exist yet: a 404 is not an error state, it is "no door".
public enum LookConsultEntryDestination: Sendable, Equatable {
    /// A consult still mid-flow — resume it where it was.
    case resumeFlow(consultId: String)
    /// A COMPLETED consult — go straight to its booking door.
    case bookingProposal(consultId: String)

    public var consultId: String {
        switch self {
        case let .resumeFlow(id), let .bookingProposal(id): return id
        }
    }
}

public enum LookConsultEntry {
    /// Ask whether this look opens a consult for this viewer, and start (or
    /// resume) one if it does.
    ///
    /// Returns the destination to navigate to, or nil meaning "not this look,
    /// not this viewer".
    public static func resolve(
        lookPostId: String,
        service: any ConsultServicing
    ) async -> LookConsultEntryDestination? {
        let id = lookPostId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        guard let availability = try? await service.lookAvailability(lookPostId: id),
              availability.available else { return nil }

        if let existing = availability.consult {
            return destination(for: existing.status, consultId: existing.id)
        }

        // Create-or-resume on the SERVER: tapping Book twice returns the same
        // consult rather than a second one (a unique index is what makes that
        // true under a race), so a retry here is safe.
        guard let started = try? await service.createFromLook(lookPostId: id) else {
            return nil
        }
        return destination(for: started.status, consultId: started.id)
    }

    /// A consult that already reached results goes straight to its booking
    /// door; one still mid-flow resumes where it was. This is about landing on
    /// the RIGHT screen for a Book tap, not about guarding the flow — the flow
    /// guards itself off server state.
    static func destination(
        for status: ConsultSessionStatus,
        consultId: String
    ) -> LookConsultEntryDestination? {
        let trimmed = consultId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return status == .completed
            ? .bookingProposal(consultId: trimmed)
            : .resumeFlow(consultId: trimmed)
    }
}
