import Foundation
import TovisKit

/// Resolving the offering to preselect when booking a look.
///
/// Web's BOOK opens the availability drawer preloaded with the look's service
/// (`buildAvailabilityDrawerContext`). Native has no drawer, so both look
/// surfaces — the feed slide and the single-look detail — resolve the pro's
/// offering for that service and hand it to `BookingFlowView`. The rule lives
/// here so the two can't drift: they read the service from different payloads
/// (`LooksFeedItemDto` vs `LooksDetailItemDto`) but must book the same thing.
enum LookBooking {
    /// The pro's offering matching this look's service, or nil when the look
    /// names no service, the profile can't be fetched, or the pro no longer
    /// offers it. A nil result means "fall back to the pro's profile so the
    /// client can still pick a service" — never a dead end.
    static func offering(
        client: TovisClient,
        professionalId: String,
        serviceId: String?
    ) async -> ProOffering? {
        guard let serviceId else { return nil }
        guard let profile = try? await client.profiles.professional(id: professionalId) else {
            return nil
        }
        return profile.offerings.first { $0.serviceId == serviceId }
    }

    /// Book the Look, B8 — the CONSULT path's resolution, by offering id.
    ///
    /// A consult's booking proposal already names the exact floor offering a
    /// hold and a finalize must be placed against, so this matches on `id`
    /// rather than on the look's service. It returns the pro's display name
    /// too: the same profile fetch already carries it, and the picker needs it.
    ///
    /// 🔴 nil means REFUSE, not "fall back". On the consult path a different
    /// offering is not a lesser answer, it is the wrong appointment — the
    /// caller must say it cannot open times rather than reserve something the
    /// proposal was not derived from.
    static func offering(
        client: TovisClient,
        professionalId: String,
        offeringId: String
    ) async -> (offering: ProOffering, proName: String)? {
        guard !offeringId.isEmpty,
              let profile = try? await client.profiles.professional(id: professionalId),
              let match = profile.offerings.first(where: { $0.id == offeringId })
        else { return nil }
        return (match, profile.header.displayName)
    }
}
