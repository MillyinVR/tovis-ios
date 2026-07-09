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

    @State private var viewingMedia: FullscreenMedia?

    var body: some View {
        content.mediaFullscreenCover($viewingMedia)
    }

    @ViewBuilder
    private var content: some View {
        if let beforeStr = beforeUrl, let afterStr = afterUrl,
            let beforeURL = URL(string: beforeStr), let afterURL = URL(string: afterStr)
        {
            BeforeAfterCompareView(
                beforeURL: beforeURL, afterURL: afterURL, height: compareHeight)
        } else if beforeUrl != nil || afterUrl != nil {
            HStack(spacing: 8) {
                thumb(beforeUrl, label: "BEFORE")
                thumb(afterUrl, label: "AFTER")
            }
        }
    }

    private func thumb(_ urlString: String?, label: String) -> some View {
        Button {
            viewingMedia = FullscreenMedia.remote(
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
