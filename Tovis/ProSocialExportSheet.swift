// "Make me something I can post."
//
// The camera has always been a very good photographer and stopped at upload. This
// is the rest of it: pick the box the platform wants, nudge the crop if the smart
// default missed, and leave with a signed file — to the share sheet, to the camera
// roll, or both.
//
// Everything the picture will look like is decided in TovisKit (`SocialExportPlan`
// for the geometry, `SocialExportPolicy` for the signature, `SocialExportRenderer`
// for the pixels), all of it tested in CI. This file is the choosing.
import SwiftUI
import TovisKit

struct ProSocialExportSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let context: ProMediaExportContext
    /// Shared with the presenting surface so identity is loaded once and the
    /// sources are decoded once.
    let model: ProMediaExportModel
    var identity: MediaExportIdentity = .own

    @State private var format: SocialExportFormat = .instagram45
    @State private var asPair = true
    @State private var adjust: CGFloat = 0
    @State private var preview: UIImage?
    @State private var rendering = false
    /// Bumped by every control so an in-flight render that is no longer the
    /// current settings can be thrown away instead of flashing on screen.
    @State private var renderToken = 0
    @State private var sharing: ExportFile?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    previewPane
                    formatPicker
                    if context.hasPair { pairToggle }
                    cropAdjuster
                    signatureNote
                    if case let .failed(message) = model.phase {
                        Text(message)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.ember)
                    }
                    if case let .done(message) = model.phase {
                        Text(message)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.emerald)
                    }
                }
                .padding(20)
                // Clear the pinned action bar — a `safeAreaInset` on a
                // `ScrollView` inside a `NavigationStack` does not extend the
                // content inset here, so without this the crop slider and the
                // signature line sit under the Share button.
                .padding(.bottom, 96)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.tint(BrandColor.textSecondary)
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
        }
        .tint(BrandColor.accent)
        .task {
            switch identity {
            case .own:
                await model.loadIdentity(session.client)
            case let .client(professionalId):
                await model.loadIdentity(session.client, forProfessionalId: professionalId)
            }
            asPair = context.hasPair
            await refreshPreview()
        }
        .sheet(item: $sharing) { file in
            ShareSheet(items: [file.url]) { try? FileManager.default.removeItem(at: file.url) }
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewPane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(BrandColor.bgSecondary)
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ProgressView().tint(BrandColor.accent)
            }
            if rendering && preview != nil {
                Color.black.opacity(0.15)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        // The pane takes the export's own shape, so what the pro is looking at is
        // literally the file — signature included, at its real position.
        .aspectRatio(format.aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        // Capped so the size picker, the pair toggle and the signature line all
        // land above the fold on a normal phone. A 9:16 preview at full width
        // would otherwise push every control that decides what it looks like off
        // the bottom of the screen.
        .frame(maxHeight: 340)
    }

    // MARK: - Controls

    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Size")
            Picker("Size", selection: $format) {
                ForEach(SocialExportFormat.allCases) { option in
                    Text(option.shortLabel).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: format) { Task { await refreshPreview() } }

            Text(format.platformLabel)
                .font(BrandFont.body(11))
                .foregroundStyle(BrandColor.textMuted)
        }
    }

    private var pairToggle: some View {
        Toggle(isOn: $asPair) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Before & after")
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text(format.pairArrangement == .stacked
                     ? "Stacked — before on top."
                     : "Side by side — before on the left.")
                    .font(BrandFont.body(11))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
        .tint(BrandColor.accent)
        .onChange(of: asPair) { Task { await refreshPreview() } }
    }

    private var cropAdjuster: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(sliderIsVertical ? "Up / down" : "Left / right")
            Slider(value: $adjust, in: -1...1) { editing in
                // Render on release only. A full-resolution crop per slider tick
                // would stutter and heat the phone for a picture nobody sees.
                if !editing { Task { await refreshPreview() } }
            }
            .tint(BrandColor.accent)

            Text(adjust == 0
                 ? "Centred on the subject. Drag to move the crop."
                 : "Tap to reset to the smart crop.")
                .font(BrandFont.body(11))
                .foregroundStyle(BrandColor.textMuted)
                .onTapGesture {
                    guard adjust != 0 else { return }
                    adjust = 0
                    Task { await refreshPreview() }
                }
        }
    }

    /// Which way the crop can travel, for the label — answered from the decoded
    /// source rather than assumed.
    private var sliderIsVertical: Bool { model.cropTravelIsVertical(for: format) }

    private var navigationTitle: String {
        if case .client = identity { return "Share" }
        return "Make a post"
    }

    private var signatureNote: some View {
        MediaExportSignatureNote(watermark: model.exportWatermark, identity: identity)
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await share() }
            } label: {
                actionLabel("Share", systemImage: "square.and.arrow.up", primary: true)
            }
            .buttonStyle(.plain)
            .disabled(rendering)

            Button {
                Task { await saveExport() }
            } label: {
                actionLabel("Save to Photos", systemImage: "arrow.down.circle", primary: false)
            }
            .buttonStyle(.plain)
            .disabled(rendering)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func actionLabel(_ title: String, systemImage: String, primary: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
            Text(title).font(BrandFont.body(14, .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .foregroundStyle(primary ? BrandColor.onAccent : BrandColor.accent)
        .background(primary ? BrandColor.accent : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BrandColor.accent.opacity(primary ? 0 : 0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func share() async {
        guard let data = await renderCurrent() else { return }
        do {
            sharing = ExportFile(url: try model.temporaryFile(for: data, named: exportFilename))
        } catch {
            model.setFailure("Couldn’t prepare that file to share.")
        }
    }

    private func saveExport() async {
        guard let data = await renderCurrent() else { return }
        await model.savePhotosCopy(of: data)
    }

    private var exportFilename: String {
        let shape = format.shortLabel.replacingOccurrences(of: ":", with: "x")
        return "tovis-\(shape)\(asPair && context.hasPair ? "-before-after" : "")"
    }

    // MARK: - Rendering

    private func renderCurrent() async -> Data? {
        rendering = true
        defer { rendering = false }
        do {
            return try await model.renderExport(
                context, format: format, asPair: asPair, adjust: adjust
            )
        } catch {
            model.setFailure("Couldn’t build that export. Try again.")
            return nil
        }
    }

    /// Re-render the preview for the current settings. Late results are dropped:
    /// a pro who flips 4:5 → 9:16 while the first render is still running must not
    /// see the old shape land on top of the new one.
    private func refreshPreview() async {
        renderToken += 1
        let token = renderToken
        model.clearStatus()
        guard let data = await renderCurrent() else { return }
        guard token == renderToken else { return }
        preview = UIImage(data: data)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.mono(11)).tracking(1.2).textCase(.uppercase)
            .foregroundStyle(BrandColor.textMuted)
    }
}

/// The rendered file, wrapped so `.sheet(item:)` can key on it — a bare `URL`
/// would need a retroactive `Identifiable` conformance on a Foundation type,
/// which is exactly the kind of thing that collides with somebody else's later.
/// Shared with `ProVideoExportSheet`, which renders a file too rather than `Data`.
struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// The "Signed" field both export sheets show — the pro's signature (or a
/// nudge to set one) plus the membership note when the platform mark rides
/// along. Shared between `ProSocialExportSheet` and `ProVideoExportSheet` so
/// the copy can't drift between the image and video paths.
struct MediaExportSignatureNote: View {
    let watermark: ExportWatermark
    let identity: MediaExportIdentity

    /// Distinct copy for the two identities: for `.own` the missing signature
    /// is something the viewer can fix (their own profile); for `.client` it
    /// is the PRO's handle that's missing, nothing the client viewing it can
    /// act on.
    private var noSignatureMessage: String {
        if case .client = identity {
            return "This pro hasn't set a handle yet, so their exports go unsigned."
        }
        return "Set a handle on your profile and your exports will be signed with it."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("Signed")
            if let signature = watermark.signature {
                Text(watermark.showsPlatformMark
                     ? "\(signature) · \(watermark.platformMark.uppercased())"
                     : signature)
                    .font(BrandFont.display(14, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
            } else {
                Text(noSignatureMessage)
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
            }
            // Said plainly rather than sold: the export is theirs either way, and
            // the membership only changes whether the small mark rides along.
            if watermark.showsPlatformMark {
                Text("Members’ exports carry their handle only.")
                    .font(BrandFont.body(11))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.mono(11)).tracking(1.2).textCase(.uppercase)
            .foregroundStyle(BrandColor.textMuted)
    }
}
