// The two states where the camera cannot run — and the second door out of both.
//
// Permission denied and "AVCaptureSession didn't start" are the same shape with
// different words: one sentence of cause, one primary way to fix it, and one way
// to keep working if the fix isn't available right now. Before the redesign the
// only options were "Open Settings" and "Close", which meant a pro whose camera
// was held by another app had nothing to do but abandon the session.
import SwiftUI

struct CameraDeadEndView: View {
    enum Kind {
        case permissionDenied
        case cameraFailed(String)
    }

    let kind: Kind
    let onPrimary: () -> Void
    let onChooseFromLibrary: () -> Void
    let onClose: () -> Void
    /// True while picked photos are being prepared + uploaded.
    let importing: Bool
    /// Anything the import needs to say — there is no lane on this screen, so
    /// a failure here would otherwise be set and never shown.
    let note: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(isFailure ? BrandColor.ember : BrandColor.textMuted)
                .frame(width: 52, height: 52)
                .background(isFailure ? BrandColor.ember.opacity(0.14)
                                      : BrandColor.textPrimary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(title)
                .font(BrandFont.display(21, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
                .multilineTextAlignment(.center)

            Text(detail)
                .font(BrandFont.body(14.5))
                .foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)

            Button(action: onPrimary) {
                Text(primaryLabel)
                    .font(BrandFont.display(15.5, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(BrandColor.accent,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.top, 10)

            // The dead end's second door. It runs the same presign→PUT→confirm
            // pipeline a captured shot does, so the booking ends up with real
            // session media either way.
            Button(action: onChooseFromLibrary) {
                HStack(spacing: 8) {
                    if importing { ProgressView().tint(BrandColor.textSecondary) }
                    Text(importing ? "Adding photos…" : "Choose from library instead")
                        .font(BrandFont.display(15.5, .semibold))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                .frame(maxWidth: .infinity).frame(height: 50)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(BrandColor.textPrimary.opacity(0.14), lineWidth: 1)
                )
            }
            .disabled(importing)

            if let note {
                Text(note)
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.amber)
                    .multilineTextAlignment(.center)
            }

            // The failure's own words, small and last — it's for a support
            // conversation, not for the pro to act on.
            if case let .cameraFailed(message) = kind, !message.isEmpty {
                Text(message)
                    .font(BrandFont.mono(10))
                    .foregroundStyle(BrandColor.textMuted.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }

            Button("Close", action: onClose)
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textMuted)
                .padding(.top, 4)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: 420)
    }

    private var isFailure: Bool {
        if case .cameraFailed = kind { return true }
        return false
    }

    private var icon: String {
        isFailure ? "exclamationmark.triangle" : "camera.fill"
    }

    private var title: String {
        isFailure ? "The camera didn’t start" : "Camera access is off"
    }

    private var detail: String {
        isFailure
            ? "Another app may be holding it. Close it, or try again."
            : "Session photos need the camera. Turn it on in Settings and come straight back."
    }

    private var primaryLabel: String {
        isFailure ? "Try again" : "Open Settings"
    }
}
