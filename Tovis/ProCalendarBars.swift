// Calendar bars/panels — native counterparts of the web `MobileAutoAcceptBar`,
// `MobilePendingRequestBar` (+ `PendingRequestSurface`), and `MobileLocationBar`.
// Copy is quoted verbatim from the brand `proCalendar.mobileAutoAccept` /
// `mobilePendingRequest` / `labels`.
import SwiftUI
import TovisKit

/// Display label for a pro location (name → address → type). Shared by the
/// location bar and the block-time sheet's picker.
func proLocationDisplayLabel(_ location: ProLocationSummary) -> String {
    location.name ?? location.formattedAddress ?? location.type?.capitalized ?? "Location"
}

// MARK: - Auto-accept

struct ProAutoAcceptBar: View {
    let enabled: Bool
    let saving: Bool
    let onToggle: () -> Void

    private var statusText: String {
        if saving { return "Saving" }
        return enabled ? "On" : "Off"
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(enabled ? BrandColor.emerald : BrandColor.textMuted)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-accept")
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text("\(statusText) · new bookings go live")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { enabled }, set: { _ in onToggle() }))
                .labelsHidden()
                .tint(BrandColor.accent)
                .disabled(saving)
                .accessibilityLabel(enabled ? "Auto-accept is on" : "Auto-accept is off")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Pending request (top request quick-actions)

struct ProPendingRequestBar: View {
    let event: ProCalendarEvent
    let moreCount: Int
    let timeZone: String?
    let busy: Bool
    let errorText: String?
    let onOpen: () -> Void
    let onApprove: () -> Void
    let onDeny: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("◆ Pending request")
                    .font(BrandFont.mono(11))
                    .tracking(0.8)
                    .foregroundStyle(BrandColor.gold)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(BrandColor.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide pending requests bar")
            }

            Button(action: onOpen) {
                HStack(spacing: 12) {
                    BrandAvatar(name: event.clientName, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.clientName.isEmpty ? "Client" : event.clientName)
                            .font(BrandFont.body(15, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                            .lineLimit(1)
                        Text(event.title.isEmpty ? "Booking" : event.title)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textSecondary)
                            .lineLimit(1)
                        Text(Wire.dateTime(event.startsAt, timeZone: event.timeZone ?? timeZone))
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if moreCount > 0 {
                Text("+\(moreCount) more")
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(BrandColor.accent)
            }

            if let errorText {
                Text(errorText)
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.ember)
            }

            HStack(spacing: 10) {
                actionButton(
                    label: "Deny pending booking",
                    system: "xmark",
                    fill: BrandColor.bgSecondary,
                    tint: BrandColor.ember,
                    action: onDeny)
                actionButton(
                    label: "Approve pending booking",
                    system: "checkmark",
                    fill: BrandColor.accent,
                    tint: BrandColor.onAccent,
                    action: onApprove)
            }
            .disabled(busy)
            .opacity(busy ? 0.6 : 1)
        }
        .padding(14)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(BrandColor.gold.opacity(0.4), lineWidth: 1)
        )
    }

    private func actionButton(
        label: String, system: String, fill: Color, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: system).font(.system(size: 13, weight: .bold))
                Text(system == "checkmark" ? "Approve" : "Deny")
                    .font(BrandFont.body(14, .semibold))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Location selector (multi-location pros)

struct ProLocationBar: View {
    let locations: [ProLocationSummary]
    let activeLocationId: String?
    let onChange: (String?) -> Void

    private var selectedLabel: String {
        guard let activeLocationId,
              let match = locations.first(where: { $0.id == activeLocationId })
        else { return "All locations" }
        return proLocationDisplayLabel(match)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("LOC")
                .font(BrandFont.mono(11))
                .tracking(0.8)
                .foregroundStyle(BrandColor.textMuted)
            Menu {
                Button("All locations") { onChange(nil) }
                ForEach(locations) { location in
                    Button(proLocationDisplayLabel(location)) { onChange(location.id) }
                }
            } label: {
                HStack {
                    Text(selectedLabel)
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(BrandColor.textMuted)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(BrandColor.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}
