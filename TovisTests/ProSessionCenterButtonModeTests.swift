import Testing
import TovisKit
@testable import Tovis

/// When the pro footer's centre button stops being a session button and becomes
/// a plain camera.
///
/// The old behaviour — a greyed-out, unusable coin whenever no session was live —
/// is what this replaces. The risk in replacing it is the opposite mistake:
/// hijacking the slot during a REAL session state and stranding a pro mid-flow.
/// These pin both sides of that line.
@Suite struct ProSessionCenterButtonModeTests {

    private func standalone(
        _ action: ProSessionCenterAction,
        hasLoaded: Bool = true,
        actionInFlight: Bool = false
    ) -> Bool {
        ProSessionModel.isStandaloneCamera(
            action: action, hasLoaded: hasLoaded, actionInFlight: actionInFlight)
    }

    /// The whole point: no session action → a usable camera, not a dead button.
    @Test func noSessionActionMeansTheCameraButton() {
        #expect(standalone(.none))
        #expect(standalone(.unknown))
    }

    /// 🔴 Every genuine session action keeps the slot. START/FINISH with a
    /// missing booking id and PICK_BOOKING with nothing to pick are *disabled*
    /// session states — they must stay session states, or a pro whose session is
    /// mid-hiccup gets a practice camera where their Start button was.
    @Test func everySessionActionKeepsTheButton() {
        for action: ProSessionCenterAction in [
            .start, .finish, .pickBooking, .navigate, .captureBefore, .captureAfter,
        ] {
            #expect(standalone(action) == false, "\(action) must not become the practice camera")
        }
    }

    /// Before the first load the model's `center` defaults to `.none`. Reading
    /// that as "no session" would flash a camera glyph on every pro shell launch
    /// and then flip to their live session a beat later.
    @Test func nothingIsDecidedUntilTheFirstLoadLands() {
        #expect(standalone(.none, hasLoaded: false) == false)
        #expect(standalone(.unknown, hasLoaded: false) == false)
    }

    /// A tap already in flight owns the button until it resolves.
    @Test func anInFlightTapKeepsTheButton() {
        #expect(standalone(.none, actionInFlight: true) == false)
    }

    /// A session starting mid-practice: the server's next poll returns a real
    /// action, and the slot goes back to the session flow on its own.
    @Test func aSessionStartingTakesTheSlotBack() {
        #expect(standalone(.none))
        #expect(standalone(.start) == false)
    }
}
