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
