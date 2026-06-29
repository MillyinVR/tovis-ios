// Add a service address for a mobile booking. A simple typed form — the backend
// geocodes it on save (fills the formatted address + lat/lng used for the pro's
// travel-radius check), so we send the street + city/state/postal and surface the
// backend's verification error if it can't be located. (Places autocomplete is a
// later Discover polish item; a typed address that geocodes is enough for v1.)
import SwiftUI
import TovisKit

struct AddServiceAddressSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Called with the saved (geocoded) address so the caller can select it.
    let onSaved: (ClientAddress) -> Void

    @State private var label = ""
    @State private var line1 = ""
    @State private var line2 = ""
    @State private var city = ""
    @State private var state = ""
    @State private var postalCode = ""

    @State private var saving = false
    @State private var error: String?

    private var canSave: Bool {
        !trimmed(line1).isEmpty && !trimmed(city).isEmpty &&
            !trimmed(state).isEmpty && !trimmed(postalCode).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("Label (optional)", text: $label, placeholder: "Home, Studio…")
                    field("Street address", text: $line1, placeholder: "123 Main St")
                    field("Apt / suite (optional)", text: $line2, placeholder: "Apt 4B")
                    field("City", text: $city, placeholder: "Los Angeles")
                    HStack(spacing: 12) {
                        field("State", text: $state, placeholder: "CA")
                        field("ZIP", text: $postalCode, placeholder: "90001")
                            .keyboardType(.numbersAndPunctuation)
                    }

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }

                    Button { Task { await save() } } label: {
                        Group {
                            if saving { ProgressView().tint(BrandColor.onAccent) }
                            else { Text("Save address").font(BrandFont.body(17, .semibold)) }
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .foregroundStyle(BrandColor.onAccent)
                        .background(canSave ? BrandColor.accent : BrandColor.textMuted.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(!canSave || saving)
                    .padding(.top, 4)
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Service address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
            }
        }
        .tint(BrandColor.accent)
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(BrandFont.body(12, .medium)).foregroundStyle(BrandColor.textMuted)
            TextField(placeholder, text: text)
                .font(BrandFont.body(15)).foregroundStyle(BrandColor.textPrimary)
                .padding(12)
                .background(BrandColor.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1))
        }
    }

    private func save() async {
        guard canSave, !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            let address = try await session.client.addresses.createServiceAddress(
                label: trimmed(label).isEmpty ? nil : trimmed(label),
                addressLine1: trimmed(line1),
                addressLine2: trimmed(line2).isEmpty ? nil : trimmed(line2),
                city: trimmed(city),
                state: trimmed(state),
                postalCode: trimmed(postalCode),
                isDefault: false
            )
            onSaved(address)
            dismiss()
        } catch let apiError as APIError {
            error = apiError.userMessage
        } catch {
            self.error = "Couldn’t save that address. Try again."
        }
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
