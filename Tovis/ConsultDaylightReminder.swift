// The one-tap "remind me tomorrow" behind a warm-light acceptance.
//
// Warm light stopped refusing a photo on 2026-09-07 (Tori): the consult accepts
// the frame, records the warning, and tells the analysis to trust its colour
// less. That is the right trade — a client who cannot pass a gate in her own
// home learns nothing — but it leaves something worth offering: daylight really
// does read truer, and tomorrow she may be somewhere it exists.
//
// 🔴 A LOCAL notification, deliberately, not a scheduled server one. The offer
// is made on the slot, in the moment, and has to be answerable in one tap with
// no round trip and no network — including on the phone she is holding in a
// basement salon with no signal. It also needs no new NotificationEventKey, no
// preference category and no drain-time validator: nothing about the consult's
// server state changes because she wants a nudge tomorrow.
//
// It rides on the notification permission the app already asks for. If she has
// refused notifications there is nothing to schedule and the offer simply never
// appears — asking again here, mid-consult, to sell a nicety would be the app
// spending a permission prompt on its own convenience.

import Foundation
import TovisKit
import UserNotifications

enum ConsultDaylightReminder {
    /// One pending reminder per consult + shot, so tapping twice does not stack
    /// two notifications for the same photograph.
    private static func identifier(consultId: String, shotKey: ConsultCaptureShotKey) -> String {
        "consult-daylight-retake.\(consultId).\(shotKey.rawValue)"
    }

    /// Whether an offer can be honoured at all: notifications already allowed,
    /// and no reminder pending for this shot.
    ///
    /// Never REQUESTS authorization — see the file note.
    static func availability(
        consultId: String,
        shotKey: ConsultCaptureShotKey,
        center: UNUserNotificationCenter = .current()
    ) async -> Availability {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        else { return .unavailable }
        let pending = await center.pendingNotificationRequests()
        let id = identifier(consultId: consultId, shotKey: shotKey)
        return pending.contains(where: { $0.identifier == id }) ? .alreadySet : .offerable
    }

    enum Availability: Equatable {
        /// Notifications are off; make no offer rather than a broken one.
        case unavailable
        case offerable
        case alreadySet
    }

    /// Schedule tomorrow's nudge. Returns false if the system refused it, so the
    /// slot can say "couldn't set that" rather than claiming a reminder exists.
    @discardableResult
    static func schedule(
        consultId: String,
        shotKey: ConsultCaptureShotKey,
        shotTitle: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        center: UNUserNotificationCenter = .current()
    ) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = "Daylight reads truer"
        content.body = "Good time to retake your \(shotTitle.lowercased()) photo for your consult."
        content.sound = .default
        content.userInfo = ["consultId": consultId, "shotKey": shotKey.rawValue]

        guard let fireDate = Self.nextMidMorning(after: now, calendar: calendar) else {
            return false
        }
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: calendar.dateComponents(
                [.year, .month, .day, .hour, .minute], from: fireDate
            ),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: identifier(consultId: consultId, shotKey: shotKey),
            content: content,
            trigger: trigger
        )
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    /// Tomorrow at 10:00 local — when there is daylight to shoot in.
    ///
    /// 🔴 Built through `Calendar`, never by adding 86_400 seconds: a DST
    /// boundary between tonight and tomorrow makes that arithmetic land an hour
    /// out, and "10:00" is the whole point of the reminder.
    static func nextMidMorning(after now: Date, calendar: Calendar = .current) -> Date? {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else {
            return nil
        }
        return calendar.date(
            bySettingHour: 10, minute: 0, second: 0, of: tomorrow
        )
    }
}
