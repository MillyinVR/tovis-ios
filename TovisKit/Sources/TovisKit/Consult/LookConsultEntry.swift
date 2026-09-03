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
/// 🔴 Anything other than a clear "yes" is `.noConsult`, and the caller keeps
/// today's behaviour EXACTLY — it opens the ordinary booking sheet. That is
/// what makes this safe to ship against a production server where none of
/// these endpoints exist yet: a 404 is not an error state, it is "no door".
///
/// The ONE refusal that is not "no door" is the server's WORKSPACE_MISMATCH:
/// the viewer is acting as PRO on an account that also has a client profile.
/// Booking is client-only end to end (the hold and the finalize both require a
/// client), so falling through to the sheet there is not a fallback, it is a
/// dead end one screen later. That answer is surfaced as its own outcome so
/// the caller can offer the switch — what the web's WorkspaceMismatchProvider
/// does for every fetch, done here for the one tap that needs it.
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

/// What a Book tap resolved to.
public enum LookConsultEntryOutcome: Sendable, Equatable {
    /// This look opens (or resumes) a consult — go there.
    case consult(LookConsultEntryDestination)
    /// Not this look, not this viewer, or a server that has no consult door:
    /// the caller opens the ordinary booking sheet, unchanged.
    case noConsult
    /// The viewer is acting as PRO on an account that can also act as a
    /// client. Offer the switch; the client workspace will answer the same tap.
    case workspaceMismatch
}

public enum LookConsultEntry {
    /// Ask whether this look opens a consult for this viewer, and start (or
    /// resume) one if it does.
    public static func resolve(
        lookPostId: String,
        service: any ConsultServicing
    ) async -> LookConsultEntryOutcome {
        let id = lookPostId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return .noConsult }

        let availability: ConsultLookAvailability
        do {
            availability = try await service.lookAvailability(lookPostId: id)
        } catch {
            return outcome(refusedBy: error)
        }
        guard availability.available else { return .noConsult }

        if let existing = availability.consult {
            return outcome(for: existing.status, consultId: existing.id)
        }

        // Create-or-resume on the SERVER: tapping Book twice returns the same
        // consult rather than a second one (a unique index is what makes that
        // true under a race), so a retry here is safe.
        let started: ConsultLookSession
        do {
            started = try await service.createFromLook(lookPostId: id)
        } catch {
            return outcome(refusedBy: error)
        }
        return outcome(for: started.status, consultId: started.id)
    }

    /// A refused probe is "no door" — EXCEPT the one refusal that names a door
    /// the viewer can open by switching workspaces.
    static func outcome(refusedBy error: Error) -> LookConsultEntryOutcome {
        if let apiError = error as? APIError, apiError.isWorkspaceMismatch {
            return .workspaceMismatch
        }
        return .noConsult
    }

    private static func outcome(
        for status: ConsultSessionStatus,
        consultId: String
    ) -> LookConsultEntryOutcome {
        guard let destination = destination(for: status, consultId: consultId) else {
            return .noConsult
        }
        return .consult(destination)
    }

    /// A consult that already reached results goes straight to its booking
    /// door; one still mid-flow resumes where it was. This is about landing on
    /// the RIGHT screen for a Book tap, not about guarding the flow — the flow
    /// guards itself off server state.
    ///
    /// 🔴 `.cancelled` returns nil, which hands the Book button BACK to the
    /// ordinary booking sheet. The server returns the existing session for a
    /// (client, pro, look) triple whatever its status — a unique index makes a
    /// second one impossible — so a terminal consult otherwise captures the
    /// button forever: every tap lands on a screen with no forward action and
    /// the booking sheet below is never reached.
    ///
    /// `.consentRevoked` is NOT terminal and deliberately still resumes:
    /// accepting a fresh agreement moves the session back to CONSENT_REQUIRED
    /// on the server, so the flow's own consent step is the way back in.
    static func destination(
        for status: ConsultSessionStatus,
        consultId: String
    ) -> LookConsultEntryDestination? {
        let trimmed = consultId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Terminal with no recovery transition: purged mid-analysis. Nothing
        // the client can do revives it.
        guard status != .cancelled else { return nil }
        return status == .completed
            ? .bookingProposal(consultId: trimmed)
            : .resumeFlow(consultId: trimmed)
    }
}
