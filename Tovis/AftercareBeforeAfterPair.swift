// Shared before/after pair for aftercare surfaces — the native counterpart to
// web's `app/_components/aftercare/AftercareBeforeAfter`. Both photos present →
// the interactive compare slider (`BeforeAfterCompareView`, matching web's
// `BeforeAfterReveal`); only one → side-by-side labelled thumbnails that open
// full-screen on tap. Owns its own full-screen presentation, so callers just
// hand it the URLs. Renders nothing when neither photo exists, so callers can
// fall back to their own placeholder.
//
// Single source of truth for the aftercare before/after pair on iOS — used by
// the pro aftercare list and the pro aftercare-authoring screen so neither
// re-implements the compare/thumbnail + full-screen logic.
import SwiftUI
import TovisKit

struct AftercareBeforeAfterPair: View {
    let beforeUrl: String?
    let afterUrl: String?
    /// Height of the compare slider shown when both photos are present.
    var compareHeight: CGFloat = 220
    /// The visit's pro, when this pair is shown to a CLIENT — offers signed
    /// export/share on the fullscreen photo, crediting that pro. `nil` for the
    /// pro-side callers (their own aftercare list/authoring screen), which
    /// offer no save/export here at all, unchanged from before this existed.
    var clientExportProfessionalId: String?

    @State private var viewingMedia: FullscreenMedia?

    var body: some View {
        content.mediaFullscreenCover($viewingMedia)
    }

    @ViewBuilder
    private var content: some View {
        if let beforeStr = beforeUrl, let afterStr = afterUrl,
            let beforeURL = URL(string: beforeStr), let afterURL = URL(string: afterStr)
        {
            // The slider owns every drag inside its frame (BeforeAfterCompareView
            // claims the full contentShape for the wipe gesture), so the share
            // affordance sits OUTSIDE it as a corner overlay with its own tap
            // target rather than a tap-through on the slider itself.
            //
            // ⚠️ BOTTOM-trailing, not top: the slider pins its own "AFTER" capsule
            // to the TOP-trailing corner, and this overlay drew straight over it —
            // the client's care plan read "AFTE⃝" with the share circle sitting on
            // the last letter. The pro callers never saw it, because they pass no
            // `clientExportProfessionalId` and so get no button. Bottom-trailing is
            // the one free corner (BEFORE is top-leading, the grab handle is dead
            // centre).
            BeforeAfterCompareView(
                beforeURL: beforeURL, afterURL: afterURL, height: compareHeight)
                .overlay(alignment: .bottomTrailing) {
                    if let professionalId = clientExportProfessionalId {
                        shareButton(before: beforeStr, after: afterStr, professionalId: professionalId)
                    }
                }
        } else if beforeUrl != nil || afterUrl != nil {
            HStack(spacing: 8) {
                thumb(beforeUrl, label: "BEFORE")
                thumb(afterUrl, label: "AFTER")
            }
        }
    }

    /// The compare-slider case's only way to reach export — the slider itself
    /// has no tap-to-fullscreen (it's a drag surface, reused across the app in
    /// contexts where tapping should NOT open a sheet). Opens straight into
    /// the before/after diptych export rather than routing through fullscreen
    /// first, since there is nothing to zoom into that the slider doesn't
    /// already show.
    private func shareButton(before: String, after: String, professionalId: String) -> some View {
        Button {
            viewingMedia = FullscreenMedia.clientExportable(
                id: after, urlString: after, isVideo: false,
                professionalId: professionalId, beforeUrlString: before
            )
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.45), in: Circle())
        }
        .padding(10)
        .accessibilityLabel("Share")
    }

    private func thumb(_ urlString: String?, label: String) -> some View {
        Button {
            viewingMedia = clientExportProfessionalId.flatMap { professionalId in
                FullscreenMedia.clientExportable(
                    id: urlString ?? label, urlString: urlString, isVideo: false,
                    professionalId: professionalId
                )
            } ?? FullscreenMedia.remote(
                id: urlString ?? label, urlString: urlString, isVideo: false)
        } label: {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(BrandColor.bgPrimary)
                if let urlString, let url = URL(string: urlString) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ProgressView().tint(BrandColor.accent)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(BrandColor.textMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text(label)
                    .font(BrandFont.mono(8))
                    .tracking(1.0)
                    .foregroundStyle(BrandColor.textPrimary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(BrandColor.bgPrimary.opacity(0.7))
                    .clipShape(Capsule())
                    .padding(6)
            }
            .frame(height: 96)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(urlString == nil)
    }
}
