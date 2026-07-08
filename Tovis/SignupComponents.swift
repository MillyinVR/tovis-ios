// Shared building blocks for the native signup forms (ClientSignupView +
// ProSignupView), so the two flows render identical field labels, consent rows,
// and primary buttons instead of each re-declaring them.
import SwiftUI
import UIKit

/// The small secondary label shown above a signup input.
struct SignupFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(BrandFont.body(13, .semibold))
            .foregroundStyle(BrandColor.textSecondary)
    }
}

/// A tappable consent checkbox row (transactional-SMS / Terms), styled as a
/// surface card. `text` carries its own markdown links (Terms / Privacy).
struct SignupConsentRow: View {
    @Binding var isOn: Bool
    let text: Text
    /// Called after the toggle flips — e.g. to clear a validation error.
    var onToggle: () -> Void = {}

    var body: some View {
        Button {
            isOn.toggle()
            onToggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(isOn ? BrandColor.accent : BrandColor.textMuted)
                text
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
                    .tint(BrandColor.accent)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// The full-width brand primary button that submits / advances a signup step.
struct SignupPrimaryButton: View {
    let title: String
    let isLoading: Bool
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView().tint(BrandColor.onAccent)
                } else {
                    Text(title).font(BrandFont.body(17, .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(BrandColor.accent)
            .foregroundStyle(BrandColor.onAccent)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(isDisabled || isLoading)
        .padding(.top, 4)
    }
}

/// A secondary full-width "Back" button used to step backward in a multi-step form.
struct SignupBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Back")
                .font(BrandFont.body(15, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(BrandColor.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

/// The step progress header ("Step N of M" + label + segmented bar) shared by any
/// multi-step signup flow.
struct SignupStepIndicator: View {
    let step: Int
    let labels: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Step \(step + 1) of \(labels.count)")
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)
                Spacer()
                Text(labels[safe: step] ?? "")
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
            }
            HStack(spacing: 6) {
                ForEach(labels.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? BrandColor.accent.opacity(0.6) : BrandColor.textMuted.opacity(0.18))
                        .frame(height: 4)
                }
            }
        }
    }
}

/// A password field with a show/hide (eye) toggle, styled to match `BrandField`.
/// Used everywhere the user types a password (sign in, signup, password reset) so
/// they can reveal what they typed and catch typos. The content type is applied to
/// the inner field — `.password` for sign in (autofill), `.newPassword` for signup
/// / reset (Passwords app strong-password suggestion + save).
struct PasswordRevealField: View {
    let placeholder: String
    @Binding var text: String
    var textContentType: UITextContentType? = .password

    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isRevealed {
                    TextField("", text: $text, prompt: prompt)
                } else {
                    SecureField("", text: $text, prompt: prompt)
                }
            }
            .font(BrandFont.body(16))
            .foregroundStyle(BrandColor.textPrimary)
            .textContentType(textContentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(BrandColor.textMuted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRevealed ? "Hide password" : "Show password")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
        )
    }

    private var prompt: Text {
        Text(placeholder).foregroundStyle(BrandColor.textMuted)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
