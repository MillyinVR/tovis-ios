// Best-shots review — the Session Reel tray. The coach auto-harvested these stills
// at quality peaks across the session; the pro reviews and uploads the keepers
// (staged, not auto-uploaded — capture stays intentional). Selected shots upload
// to the booking's BEFORE/AFTER media via the same pipeline as a manual capture.
import SwiftUI
import TovisKit

struct BestShotsReviewView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let coach: CoachEngine
    let bookingId: String
    let phase: MediaPhase
    /// Card-solved color correction — baked into each kept shot at upload,
    /// same as manual captures. Nil = no card scanned.
    var correction: ColorMatrix3x3? = nil

    @State private var selected: Set<UUID> = []
    @State private var uploading = false
    @State private var progress = ""
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        NavigationStack {
            Group {
                if coach.harvested.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Best shots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(allSelected ? "Deselect all" : "Select all") { toggleAll() }
                        .tint(BrandColor.accent)
                        .disabled(coach.harvested.isEmpty || uploading)
                }
            }
            .safeAreaInset(edge: .bottom) { uploadBar }
        }
        .tint(BrandColor.accent)
        .onAppear { selected = Set(coach.harvested.map(\.id)) }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(coach.harvested) { shot in
                    cell(shot)
                }
            }
            .padding(16)
        }
    }

    private func cell(_ shot: HarvestedShot) -> some View {
        let isSelected = selected.contains(shot.id)
        return Image(uiImage: shot.image)
            .resizable()
            .scaledToFill()
            .frame(height: 132)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? BrandColor.accent : .white)
                    .padding(6)
                    .shadow(radius: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? BrandColor.accent : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelected { selected.remove(shot.id) } else { selected.insert(shot.id) }
            }
    }

    private var uploadBar: some View {
        VStack(spacing: 8) {
            if let errorMessage {
                Text(errorMessage).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
            }
            Button {
                Task { await uploadSelected() }
            } label: {
                HStack {
                    if uploading { ProgressView().tint(BrandColor.onAccent) }
                    Text(uploading ? (progress.isEmpty ? "Uploading…" : progress)
                                   : "Keep \(selected.count) to \(phaseLabel)")
                        .font(BrandFont.body(16, .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(BrandColor.accent)
                .foregroundStyle(BrandColor.onAccent)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(uploading || selected.isEmpty)
            .opacity(selected.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(BrandColor.textMuted)
            Text("No best shots yet")
                .font(BrandFont.display(20, .semibold)).foregroundStyle(BrandColor.textPrimary)
            Text("As you shoot, the camera saves the highest-quality frames here.")
                .font(BrandFont.body(14)).foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 80).padding(.horizontal, 30)
    }

    // MARK: - Actions

    private var allSelected: Bool {
        !coach.harvested.isEmpty && selected.count == coach.harvested.count
    }

    private func toggleAll() {
        selected = allSelected ? [] : Set(coach.harvested.map(\.id))
    }

    private func uploadSelected() async {
        let shots = coach.harvested.filter { selected.contains($0.id) }
        guard !shots.isEmpty else { return }
        uploading = true
        errorMessage = nil
        defer { uploading = false }

        var uploaded: Set<UUID> = []
        var lastError: String?
        for (index, shot) in shots.enumerated() {
            progress = "Uploading \(index + 1) of \(shots.count)…"
            // The full-res bytes live on disk (only the tray thumb is in RAM) —
            // read them back off the main actor for the upload.
            guard let raw = await Task.detached(
                priority: .userInitiated,
                operation: { SessionByteVault.read(shot.fileURL) }
            ).value else {
                lastError = "Couldn’t read some photos — try again."
                continue   // leave it in the tray; the file may return next retry
            }
            var payload = raw
            if let correction, let corrected = await CardCorrection.apply(correction, to: raw) {
                payload = corrected
            }
            do {
                try await session.client.proMedia.uploadSessionPhoto(
                    bookingId: bookingId,
                    phase: phase,
                    imageData: payload
                )
                uploaded.insert(shot.id)
            } catch let error as APIError {
                lastError = error.userMessage
            } catch {
                lastError = "Couldn’t upload some photos — they’re still here to retry."
            }
            // Keep going: one flaky upload must not strand the shots behind it.
        }

        // Only the successes leave the tray; failures stay selected so the pro can
        // tap "Keep" again to retry (their bytes are never dropped).
        coach.removeHarvested(uploaded)
        selected.subtract(uploaded)
        if !uploaded.isEmpty { session.signalRefresh() }   // the hub gallery picks up the new photos
        let failedCount = shots.count - uploaded.count
        if failedCount > 0 {
            errorMessage = lastError
                ?? "Couldn’t upload \(failedCount) photo\(failedCount == 1 ? "" : "s") — still here to retry."
        }
        if coach.harvested.isEmpty { dismiss() }
    }

    private var phaseLabel: String {
        switch phase {
        case .before: return "Before"
        case .after: return "After"
        case .other: return "Session"
        }
    }
}
