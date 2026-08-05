// The practice library — the shots taken with the standalone camera.
//
// Portfolio-shaped on purpose (a grid of the pro's own work), but with none of
// the portfolio's obligations: a practice shot has no booking, no client and no
// service, so nothing here is owed to anybody and nothing here is public.
//
// The one thing it CAN do is stop being practice. "Attach" promotes a shot into
// real media — onto one of the pro's bookings, or out as a look — which is the
// moment a service is finally known. That is why the pickers live here rather
// than in the camera: at capture time there is nothing to pick.
//
// Backed by GET/DELETE /api/v1/pro/practice and POST /pro/practice/{id}/attach.
import SwiftUI
import TovisKit

struct ProPracticeLibraryView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Opens the standalone camera. Nil hides the "Take a shot" affordance —
    /// used when the library is presented FROM the camera, where a second way
    /// in would just stack two cameras.
    var onShoot: (() -> Void)?

    private enum Phase: Equatable {
        case loading
        case loaded([ProPracticeShot])
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var attaching: ProPracticeShot?
    @State private var confirmingDelete: ProPracticeShot?
    @State private var viewing: ProPracticeShot?
    @State private var banner: String?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Shots you took outside a session. Nothing here is shared or attached to anyone — until you say so.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)

                if let banner {
                    Text(banner)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textPrimary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(BrandColor.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 60)
                case let .failed(message):
                    errorState(message)
                case let .loaded(items):
                    if items.isEmpty { emptyState } else { grid(items) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Practice")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if let onShoot {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onShoot()
                    } label: {
                        Image(systemName: "camera.fill")
                    }
                    .tint(BrandColor.accent)
                    .accessibilityLabel("Take a practice shot")
                }
            }
        }
        .task { await load() }
        .sheet(item: $attaching) { shot in
            ProPracticeAttachSheet(shot: shot) { message in
                banner = message
                Task { await load(silent: true) }
            }
        }
        .sheet(item: $viewing) { shot in
            ProPracticeShotDetail(shot: shot)
        }
        .confirmationDialog(
            "Delete this practice shot?",
            isPresented: Binding(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmingDelete
        ) { shot in
            Button("Delete", role: .destructive) {
                let target = shot
                confirmingDelete = nil
                Task { await delete(target) }
            }
            Button("Keep it", role: .cancel) { confirmingDelete = nil }
        } message: { shot in
            // Attaching COPIES the bytes, so this really is only the practice
            // copy — say so, or a pro will assume it unpublishes their look.
            Text(shot.isAttached
                 ? "This one has already been attached. Deleting it here won’t touch the copy you attached."
                 : "This can’t be undone.")
        }
    }

    // MARK: - Grid

    private func grid(_ items: [ProPracticeShot]) -> some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(items) { shot in
                tile(shot)
            }
        }
    }

    private func tile(_ shot: ProPracticeShot) -> some View {
        Button {
            viewing = shot
        } label: {
            ZStack(alignment: .topTrailing) {
                thumbnail(shot)
                if shot.isAttached {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(BrandColor.accent)
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(shot.isAttached ? "Practice shot, already attached" : "Practice shot")
        .contextMenu {
            Button {
                attaching = shot
            } label: {
                Label(shot.isAttached ? "Already attached" : "Attach…", systemImage: "paperclip")
            }
            .disabled(shot.isAttached)

            Button(role: .destructive) {
                confirmingDelete = shot
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ shot: ProPracticeShot) -> some View {
        let focal = MediaFocalPoint(x: shot.focalX, y: shot.focalY)
        if let raw = shot.renderUrl, let url = URL(string: raw) {
            FocalCoverImage(url: url, focal: focal, maxPixel: 320) {
                BrandColor.bgSurface
            } failure: {
                placeholderTile(systemImage: "photo")
            }
            .frame(height: 132)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            // A signed URL expires; a tile that can't render is not a lost shot.
            placeholderTile(systemImage: "arrow.clockwise")
                .frame(height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func placeholderTile(systemImage: String) -> some View {
        ZStack {
            BrandColor.bgSurface
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(BrandColor.textMuted)
        }
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.fill")
                .font(.system(size: 26))
                .foregroundStyle(BrandColor.textMuted)
            Text("No practice shots yet")
                .font(BrandFont.display(17, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text("Open the camera between clients — the coach works exactly the same, and nothing you shoot is owed to anyone.")
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message)
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await load() } }
                .font(BrandFont.body(14, .semibold))
                .tint(BrandColor.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    // MARK: - Data

    private func load(silent: Bool = false) async {
        if !silent { phase = .loading }
        do {
            phase = .loaded(try await session.client.proPractice.list())
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your practice shots.")
        }
    }

    /// Delete removes only the PRACTICE copy — media attached from it keeps its
    /// own bytes (the server copies on attach), which is what the dialog says.
    private func delete(_ shot: ProPracticeShot) async {
        do {
            try await session.client.proPractice.delete(shotId: shot.id)
            banner = nil
            await load(silent: true)
        } catch let error as APIError {
            banner = error.userMessage
        } catch {
            banner = "Couldn’t delete that shot."
        }
    }
}

/// One shot, full-bleed, with its attach state spelled out — and the two ways out
/// with it. A practice shot is owed to nobody, which makes it the purest case for
/// both: save the original to the camera roll, or make a post out of it without
/// it ever touching a booking.
private struct ProPracticeShotDetail: View {
    let shot: ProPracticeShot
    @Environment(\.dismiss) private var dismiss

    /// The subject focal the camera found at capture time — practice shots are
    /// the one surface that carries it on read, so their smart crop is the one
    /// that actually knows where the face is.
    private var exportContext: ProMediaExportContext? {
        guard shot.mediaType == .image,
              let raw = shot.renderUrl, let url = URL(string: raw) else { return nil }
        return ProMediaExportContext(
            main: .remote(url),
            focal: MediaFocalPoint(x: shot.focalX, y: shot.focalY)
        )
    }

    var body: some View {
        NavigationStack {
            VStack {
                if let raw = shot.renderUrl, let url = URL(string: raw) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        ProgressView().tint(BrandColor.accent)
                    }
                } else {
                    Text("This photo’s link expired — pull the library to refresh.")
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle(shot.isAttached ? "Attached" : "Practice shot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .tint(BrandColor.textSecondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let exportContext {
                    // The same bar the fullscreen viewer shows, so "Save to
                    // Photos" means the same thing on every pro surface.
                    ProMediaExportBar(context: exportContext)
                }
            }
        }
        .tint(BrandColor.accent)
    }
}
