// The coach's memory of a room (camera plan P4.1).
//
// Tori's line for this whole phase: *"a photographer who has shot in your
// salon twice stops mentioning the overheads."* After truth (P1) and
// reliability (P2), MEMORY is the third thing that breaks the "photographer
// standing next to you" fantasy — a mentor who keeps prescribing a fix you
// cannot make stops being a mentor and becomes a dashboard. The camera's own
// north star says it plainly: never keep suggesting a fix the pro can't make.
//
// What this is:
//
//   • The pro is shown a ROOM CONDITION tip (the overheads are mixed, the
//     backdrop is busy) at the same salon location, shoot after shoot.
//   • On the Nth shoot — not the first — the lane offers one word, "GOT IT".
//   • Tapping it retires that tip AT THAT LOCATION, on this device, for good.
//
// What this is NOT, deliberately:
//
//   • **Not a score change.** A retired tip is still a real deficit and the
//     readiness ring still counts it, undiminished. `CoachTipArbiter` drops
//     the WORDS; readiness is a weighted mean over `signals` that never sees
//     this set. A coach that quietly marked a bad frame good to spare the pro
//     a sentence would be lying about the photograph, which is the one thing
//     the north star rules out ahead of everything else.
//   • **Not a mute button.** Only conditions the pro genuinely may not be
//     able to change are dismissible (`dismissible`, below): the room's light
//     and the room's backdrop. "Move in closer", "hold steady", "straighten
//     up" are things the very next frame can do differently, and turning a
//     correction the pro CAN act on into a dismissal prompt would be building
//     a way to switch the coach off, not a way to remember the room.
//   • **Not dismissible on a hard failure.** `CoachSeverity.failure` is a
//     capture no edit recovers. "The overheads stay on here" is a fact about
//     a salon; "the light is behind them and this frame is lost" is not a
//     preference. The arbiter refuses to suppress a `.failure` whatever this
//     set says — belt and braces alongside the allowlist here.
//   • **Not GPS.** The room is keyed on the booking's `locationId` — the
//     server's stable id for one of the pro's own salon locations. Salons are
//     indoors, a fix is unreliable there, and "which chair" is a different
//     privacy question from "where are you". Nothing here reads CoreLocation.
//
// ## The retune question, decided
//
// P1's salon pass WILL move `mixedLightSpread` and `clutterReference`. A
// dismissal record has to answer for that, and there are exactly two failure
// modes, which cannot both be avoided:
//
//   (a) a retune RESURRECTS a tip the pro already retired, or
//   (b) a retune keeps a dismissal SUPPRESSING a tip whose meaning has moved.
//
// **This chooses (b), and refuses (a).** The record is keyed on tip-id +
// location and nothing else — no threshold value, no score, no tuning
// version. The reason is that the pro's answer was never about the number:
// "the overheads stay on here" is a statement about the SALON, and the salon
// does not change when `mixedLightSpread` does. Resurrecting a retired tip
// because a constant moved is precisely the forgetting this phase exists to
// fix, and the pro would experience it as the coach going back on its word.
//
// (b) is then made non-silent rather than accepted blind: `meaningVersions`
// is the deliberate, auditable escape hatch. If a retune genuinely changes
// what a moment CLAIMS about a room, whoever makes that change bumps the
// moment's version here, every dismissal of it is forgotten in one commit,
// and it shows up in the diff. What is refused is the SILENT version — a
// dismissal quietly evaporating because a number two files away moved.
import Foundation

/// One salon room, remembered: which room-condition tips this pro has been
/// shown here, and which ones they have told the coach to stop mentioning.
///
/// Device-local (`UserDefaults`, same as every other coach preference — there
/// is no server-synced camera-behaviour model), per-location, and created
/// fresh for each camera open, which is what makes "this shoot" meaningful.
final class CoachRoomMemory {
    /// How many separate SHOOTS in this room a tip has to survive before the
    /// coach offers to retire it. Three, so the offer lands on the third —
    /// after the two Tori's line describes ("has shot in your salon twice").
    ///
    /// Shoots, not frames and not seconds: a tip that flickers six times in
    /// one session is one experience of it, and counting frames would put the
    /// offer on screen inside the first minute of the first shoot, which is
    /// the "a tip the pro CAN act on must not be turned into a dismissal
    /// prompt" mistake wearing a different hat.
    static let shootsBeforeOffering = 3

    /// The only tips that may ever be retired: the room's light, and the
    /// room's backdrop. Everything else the coach says is about the camera in
    /// the pro's hands or the person in front of it, and the next frame can
    /// answer it.
    ///
    /// Note all four are `.correction` severity at their coach
    /// (`ColorCoach`, `BackgroundCoach`) — none of them is ever a hard
    /// failure, so nothing here can retire a lost frame even before the
    /// arbiter's own refusal.
    static let dismissible: Set<CoachMoment> = [
        .colorMixed, .colorGreenish, .colorWarm, .backgroundBusy,
    ]

    /// Deliberate invalidation, per moment — see "The retune question" above.
    /// **Empty on purpose.** Adding `[.colorMixed: 2]` here forgets every
    /// pro's dismissal of that tip, everywhere, and is the ONLY thing that
    /// does. Bump it when a retune changes what a moment CLAIMS about a room;
    /// never merely because a threshold moved.
    ///
    /// A bump resets the SHOOT COUNT along with the dismissal — the tip comes
    /// back and has to be met three times again before the offer returns. That
    /// is the point: if the claim has changed, the pro has not yet agreed to
    /// the new one.
    static let meaningVersions: [CoachMoment: Int] = [:]

    static func meaningVersion(of moment: CoachMoment) -> Int {
        meaningVersions[moment] ?? 1
    }

    /// What the coach says back when the pro retires a tip — the one warm
    /// sentence in this feature, and the reason `.roomTipDismissed` exists as
    /// a `CoachMoment` at all. Canonical (Calm Mentor) text; a pack wraps it
    /// through `CoachPhraseContext.detail`, same as every other wrapping
    /// moment. Nil for anything not dismissible, which cannot be reached.
    static func confirmation(for moment: CoachMoment) -> String? {
        switch moment {
        case .colorMixed: return "Got it — the overheads stay on here"
        case .colorGreenish: return "Got it — the green cast is this room"
        case .colorWarm: return "Got it — the warm light is this room"
        case .backgroundBusy: return "Got it — that’s the backdrop here"
        default: return nil
        }
    }

    /// The room's stable id — the booking's `locationId`.
    let locationId: String
    private let store: UserDefaults
    /// Tips already counted for THIS shoot, so a tip on screen for two minutes
    /// is one shoot, not seven hundred frames.
    private var countedThisShoot: Set<CoachMoment> = []
    private var dismissedCache: Set<CoachMoment>
    private var stationCache: CoachStationRead.Profile?

    /// A room, or nothing at all.
    ///
    /// ⚠️ Only a **SALON** booking has a room to remember. `Booking.locationId`
    /// is non-null for MOBILE too — it points at the PRO's own
    /// `ProfessionalLocation`, not at wherever the pro has driven to — so
    /// keying a mobile shoot on it would pool every client's living room into
    /// one bucket and let a dismissal made in one house silence a tip in the
    /// next. A mobile shoot, a practice shoot and a booking that arrived
    /// without a location all get NO memory: `init?` returns nil and the coach
    /// behaves exactly as it does today.
    init?(locationId: String?, locationType: String?, store: UserDefaults = .standard) {
        guard locationType?.uppercased() == "SALON",
              let locationId = locationId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !locationId.isEmpty
        else { return nil }
        self.locationId = locationId
        self.store = store
        self.dismissedCache = Self.dismissible.filter {
            store.bool(forKey: Self.dismissedKey(locationId: locationId, moment: $0))
        }
        self.stationCache = Self.loadStationRead(locationId: locationId, store: store)
    }

    // MARK: - Reading

    /// The tips retired in this room. Filtered through `dismissible` on the
    /// way out as well as in, so no stored value — a stale record from a build
    /// with a wider allowlist, a hand-edited defaults plist — can ever retire
    /// a correction the pro is able to act on.
    var dismissedMoments: Set<CoachMoment> { dismissedCache.intersection(Self.dismissible) }

    func isDismissed(_ moment: CoachMoment) -> Bool { dismissedMoments.contains(moment) }

    /// How many separate shoots in this room have shown this tip.
    func shootsShown(_ moment: CoachMoment) -> Int {
        guard Self.dismissible.contains(moment) else { return 0 }
        return store.integer(forKey: Self.countKey(locationId: locationId, moment: moment))
    }

    /// What the lane should offer for the tip currently on it, and the side
    /// effect of the pro having seen that tip — the whole per-frame decision
    /// in one place, so it can be tested without a camera or a live engine.
    ///
    /// `raw` is the moment the coach DECIDED on; `published` is the moment
    /// still attached to the sentence the pro is actually reading. They differ
    /// when a match look's bespoke direction has replaced the whole correction
    /// (`LookDirectionScript` strips the moment). The underlying condition is
    /// the same one either way, so it still counts toward this room — but the
    /// offer is withheld, because "GOT IT" beside words that no longer mention
    /// the overheads asks the pro to agree to something the lane isn't saying.
    @discardableResult
    func offer(forRaw raw: CoachMoment?, published: CoachMoment?, now: Date = Date()) -> CoachMoment? {
        guard let raw else { return nil }
        noteShown(raw)
        guard published == raw, shouldOfferDismissal(of: raw, now: now) else { return nil }
        return raw
    }

    /// Has this pro seen this tip here often enough to be offered a way out —
    /// or has the station read (P4.2) already measured the condition as this
    /// ROOM's, which is the same question answered with better evidence?
    ///
    /// The three-shoot wait exists because the coach cannot tell a room
    /// condition from a circumstance and must not turn a fixable tip into a
    /// dismissal prompt. A station read the pro took of the empty station IS
    /// that telling-apart: the room itself measured warm/green/mixed with
    /// nobody in it, so the offer lands the first time the tip fires here.
    /// The offer only — the dismissal is still the pro's tap, and a hard
    /// failure is still refused at both the allowlist and the arbiter.
    func shouldOfferDismissal(of moment: CoachMoment, now: Date = Date()) -> Bool {
        Self.dismissible.contains(moment)
            && !isDismissed(moment)
            && (shootsShown(moment) >= Self.shootsBeforeOffering
                || stationProfile(now: now)?.corroborates(moment) == true)
    }

    // MARK: - Writing

    /// The coach put this tip on screen during this shoot. Counts at most once
    /// per shoot per tip, and stops counting once the tip is retired (the
    /// number has done its job by then, and letting it run would make a later
    /// `meaningVersions` bump re-offer instantly rather than re-earn).
    func noteShown(_ moment: CoachMoment) {
        guard Self.dismissible.contains(moment), !isDismissed(moment),
              countedThisShoot.insert(moment).inserted
        else { return }
        store.set(shootsShown(moment) + 1,
                  forKey: Self.countKey(locationId: locationId, moment: moment))
    }

    /// The pro said this one isn't theirs to fix. Returns false — changing
    /// nothing — for anything outside the allowlist.
    @discardableResult
    func dismiss(_ moment: CoachMoment) -> Bool {
        guard Self.dismissible.contains(moment) else { return false }
        store.set(true, forKey: Self.dismissedKey(locationId: locationId, moment: moment))
        dismissedCache.insert(moment)
        return true
    }

    /// Undo — the pro tapped the offer by mistake. Puts the tip straight back
    /// and leaves the shoot count alone, so the offer is on screen again
    /// immediately for anyone who did mean it.
    ///
    /// This exists because the dismissal is otherwise permanent, one tap deep,
    /// and reached from a control the pro has never seen before. A dismissal
    /// costs only the SENTENCE — the ring and the dimensions drawer still
    /// carry the deficit — but "you can still infer it from the drawer" is not
    /// a way back, and a one-way door on a first encounter is not something to
    /// ship and then disclose.
    @discardableResult
    func restore(_ moment: CoachMoment) -> Bool {
        guard dismissedCache.contains(moment) else { return false }
        store.removeObject(forKey: Self.dismissedKey(locationId: locationId, moment: moment))
        dismissedCache.remove(moment)
        return true
    }

    // MARK: - The station read (P4.2)
    //
    // One coarse reading of the room's light, taken by the pro at setup and
    // stored as RAW numbers (see `CoachStationRead.Profile` for why raw).
    // Same store, same per-location keying as the dismissals above, and the
    // same salon-only gate by construction — a memory that failed `init?` has
    // nowhere to record a read. Deliberately SEPARATE keys from the
    // dismissals: a re-read can never touch what the pro has retired, and a
    // `meaningVersions` bump can never erase a measurement of the room.

    /// How long a station read stays trusted: ~6 months. A salon's light does
    /// change — a bulb swap, a rearrange, a season — and the coach cannot see
    /// it happen, so an unbounded read would drift ever further from the room
    /// it claims to know. Expiry costs one tap (the setup card returns);
    /// speaking a stale room fact costs trust. The pro can also re-read at
    /// any time from the session hub's summary row.
    static let stationReadMaxAge: TimeInterval = 180 * 24 * 3600

    /// This room's station read, or nil when none has been taken or the last
    /// one has aged out. `now` is injectable for tests; callers use the clock.
    func stationProfile(now: Date = Date()) -> CoachStationRead.Profile? {
        guard let profile = stationCache,
              now.timeIntervalSince(profile.readAt) <= Self.stationReadMaxAge,
              profile.readAt <= now
        else { return nil }
        return profile
    }

    /// Record a fresh read, replacing any previous one — re-reading IS the
    /// "the salon changed a bulb" story, so replacement is the point.
    func recordStationRead(_ profile: CoachStationRead.Profile) {
        store.set(profile.warmth, forKey: Self.stationKey(locationId: locationId, field: "warmth"))
        store.set(profile.greenTint, forKey: Self.stationKey(locationId: locationId, field: "green"))
        store.set(profile.thirdWarmths, forKey: Self.stationKey(locationId: locationId, field: "thirds"))
        store.set(profile.readAt.timeIntervalSince1970,
                  forKey: Self.stationKey(locationId: locationId, field: "readAt"))
        stationCache = profile
    }

    private static func loadStationRead(locationId: String, store: UserDefaults)
        -> CoachStationRead.Profile? {
        let readAtKey = stationKey(locationId: locationId, field: "readAt")
        guard store.object(forKey: readAtKey) != nil,
              let thirds = store.array(forKey: stationKey(locationId: locationId, field: "thirds"))
                  as? [Double],
              thirds.count == 3
        else { return nil }
        return CoachStationRead.Profile(
            warmth: store.double(forKey: stationKey(locationId: locationId, field: "warmth")),
            greenTint: store.double(forKey: stationKey(locationId: locationId, field: "green")),
            thirdWarmths: thirds,
            readAt: Date(timeIntervalSince1970: store.double(forKey: readAtKey)))
    }

    // MARK: - Keys
    //
    // `tovis.coach.room.<locationId>.<moment>.v<n>.<field>` — tip-id AND
    // location, per the decision at the top of this file, plus the deliberate
    // meaning version. The `tovis.coach.` prefix matches `CoachSettings`;
    // `.room.` keeps this apart from the shoot-scoped defaults
    // `ProCameraDestination.custodyScope` namespaces (white balance, card
    // calibration), which are per-BOOKING and must not be confused with a
    // per-LOCATION record that outlives every booking in the room.

    private static func base(locationId: String, moment: CoachMoment) -> String {
        "tovis.coach.room.\(locationId).\(moment).v\(meaningVersion(of: moment))"
    }

    static func countKey(locationId: String, moment: CoachMoment) -> String {
        base(locationId: locationId, moment: moment) + ".shoots"
    }

    static func dismissedKey(locationId: String, moment: CoachMoment) -> String {
        base(locationId: locationId, moment: moment) + ".dismissed"
    }

    /// `tovis.coach.room.<locationId>.station.v1.<field>` — per LOCATION, not
    /// per moment (the read is of the room, not of any one tip), with its own
    /// schema version so a future change to what the fields mean can be made
    /// non-silent the same way `meaningVersions` makes retunes non-silent.
    static func stationKey(locationId: String, field: String) -> String {
        "tovis.coach.room.\(locationId).station.v1.\(field)"
    }
}
