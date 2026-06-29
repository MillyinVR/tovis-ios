// Pro session hub — the live-appointment screen the footer center button opens
// (web `/pro/bookings/[id]/session`). v1 shows the authoritative session state
// (status · current step · checkout) and the primary control: advance the step
// and Finish the session. Before/after photo capture is the next build (it's a
// self-contained upload subsystem — see HANDOFF "Before/after photo capture").
import SwiftUI
import TovisKit

struct ProSessionHubView: View {
    @Environment(SessionModel.self) private var session
    let bookingId: String

    private enum Phase {
        case loading
        case loaded(ProSessionState)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var working = false
    @State private var actionError: String?
    @State private var media: [ProBookingMediaItem] = []
    /// The phase whose capture screen is open (nil = closed). Wrapper makes it
    /// Identifiable for `fullScreenCover(item:)`.
    @State private var capturing: CaptureSelection?

    private struct CaptureSelection: Identifiable {
        let phase: MediaPhase
        var id: String { phase.rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 80)
                case let .failed(message):
                    errorState(message)
                case let .loaded(state):
                    content(state)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
        .onChange(of: session.refreshTick) { Task { await loadMedia() } }
        .fullScreenCover(item: $capturing, onDismiss: { Task { await loadMedia() } }) { selection in
            ProCapturePhotosView(bookingId: bookingId, phase: selection.phase)
        }
        .tint(BrandColor.accent)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ state: ProSessionState) -> some View {
        BrandSection(title: "Status") {
            BrandSurface {
                VStack(alignment: .leading, spacing: 10) {
                    labeled("Booking", value: (state.status ?? "—").capitalized)
                    if let step = state.effectiveSessionStep ?? state.sessionStep {
                        labeled("Step", value: step.capitalized)
                    }
                    if let checkout = state.checkout?.status {
                        labeled("Payment", value: checkout.capitalized)
                    }
                    if let started = state.startedAt {
                        labeled("Started", value: Wire.dateTime(started, timeZone: nil))
                    }
                }
            }
        }

        photosSection

        if let message = actionError {
            Text(message)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.ember)
        }

        if state.terminal {
            BrandSurface {
                Text("This session is complete.")
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textSecondary)
            }
        } else {
            // Primary control: finish the session. The server resolves what
            // "finish" means for the current step (closeout / aftercare).
            Button {
                Task { await finish() }
            } label: {
                HStack {
                    if working { ProgressView().tint(BrandColor.onAccent) }
                    Text(working ? "Finishing…" : "Finish session")
                        .font(BrandFont.body(16, .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(BrandColor.accent)
                .foregroundStyle(BrandColor.onAccent)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(working)
        }
    }

    // MARK: - Photos

    private var photosSection: some View {
        BrandSection(title: "Photos") {
            VStack(spacing: 12) {
                phaseRow(.before, label: "Before")
                phaseRow(.after, label: "After")
            }
        }
    }

    @ViewBuilder
    private func phaseRow(_ phase: MediaPhase, label: String) -> some View {
        let shots = media.filter { $0.phase == phase }
        BrandSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(label)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    if !shots.isEmpty {
                        Text("\(shots.count)")
                            .font(BrandFont.mono(11))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                    Spacer()
                    Button {
                        capturing = CaptureSelection(phase: phase)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "camera.fill").font(.system(size: 13, weight: .semibold))
                            Text(shots.isEmpty ? "Capture" : "Add")
                                .font(BrandFont.body(13, .semibold))
                        }
                        .foregroundStyle(BrandColor.accent)
                    }
                }

                if !shots.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(shots) { item in
                                thumbnail(item)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ item: ProBookingMediaItem) -> some View {
        let urlString = item.displayThumbUrl
        ZStack {
            BrandColor.bgSecondary
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView().tint(BrandColor.accent)
                }
            } else {
                Image(systemName: "photo").foregroundStyle(BrandColor.textMuted)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func labeled(_ label: String, value: String) -> some View {
        HStack {
            Text(label.uppercased())
                .font(BrandFont.mono(10))
                .tracking(0.8)
                .foregroundStyle(BrandColor.textMuted)
            Spacer()
            Text(value)
                .font(BrandFont.body(14, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again")
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    // MARK: - Actions

    private func load() async {
        do {
            let state = try await session.client.proSession.state(bookingId: bookingId)
            phase = .loaded(state)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load this session.")
        }
        await loadMedia()
    }

    private func loadMedia() async {
        media = (try? await session.client.proMedia.list(bookingId: bookingId)) ?? media
    }

    private func finish() async {
        working = true
        actionError = nil
        defer { working = false }
        do {
            _ = try await session.client.proSession.finish(bookingId: bookingId)
            session.signalRefresh()
            await load()
        } catch let error as APIError {
            actionError = error.userMessage
        } catch {
            actionError = "Something went wrong."
        }
    }
}
