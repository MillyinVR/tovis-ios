// Pro Waitlist — the native counterpart of the web `/pro/waitlist` outreach
// workspace, backed by GET /api/v1/pro/waitlist (route already exists, so this is
// an iOS-only port — no backend change). Shows the clients waiting for this pro's
// services, grouped by service and FIFO-ranked (who has waited longest is rank #1),
// and lets the pro message whoever they like to fill a spot — top of the list
// first. Read-only otherwise: the "offer a concrete time" flow is a separate
// calendar surface. Reached from the pro profile's Business section.
import SwiftUI
import TovisKit

struct ProWaitlistView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded(ProWaitlistOutreach)
        case failed(String)
    }

    @State private var phase: Phase = .loading

    // Message-a-client entry point: resolve-or-create the WAITLIST thread, then
    // push it into ThreadView. `messageWorkingId` is the entry currently resolving
    // (drives the per-row spinner + disable), shared across the whole list.
    @State private var messageNav: MessageThreadNav?
    @State private var messageWorkingId: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 60)
                case let .failed(message):
                    errorState(message)
                case let .loaded(outreach):
                    content(outreach)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Waitlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .refreshable { await load() }
        .task { if case .loading = phase { await load() } }
        .onChange(of: session.refreshTick) { Task { await load() } }
        .navigationDestination(item: $messageNav) { nav in
            ThreadView(thread: nav.thread)
        }
    }

    @ViewBuilder
    private func content(_ outreach: ProWaitlistOutreach) -> some View {
        if outreach.isEmpty {
            emptyState
        } else {
            Text("Clients waiting for your services, in the order they joined. Reach out to fill a spot — message whoever you like, top of the list first.")
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(outreach.services) { group in
                serviceGroup(group)
            }
        }
    }

    private func serviceGroup(_ group: ProWaitlistServiceGroup) -> some View {
        BrandSection(
            title: group.serviceName,
            trailing: "\(group.entries.count) waiting"
        ) {
            BrandSurface {
                VStack(spacing: 0) {
                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                        entryRow(entry)
                        if index < group.entries.count - 1 {
                            Divider().overlay(BrandColor.textMuted.opacity(0.12))
                        }
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: ProWaitlistEntry) -> some View {
        HStack(spacing: 12) {
            Text("\(entry.rank)")
                .font(BrandFont.mono(11))
                .foregroundStyle(BrandColor.textSecondary)
                .frame(width: 26, height: 26)
                .background(BrandColor.bgSecondary)
                .clipShape(Circle())

            BrandAvatar(name: entry.clientName, avatarUrl: entry.avatarUrl, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.clientName)
                    .font(BrandFont.body(14, .bold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .lineLimit(1)
                Text(subtitle(entry))
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task { await openThread(for: entry) }
            } label: {
                Group {
                    if messageWorkingId == entry.waitlistEntryId {
                        ProgressView().tint(BrandColor.accent)
                    } else {
                        Text("Message")
                    }
                }
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(BrandColor.textSecondary)
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .overlay(
                    Capsule().stroke(BrandColor.textMuted.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(messageWorkingId != nil)
        }
        .padding(.vertical, 10)
    }

    /// "<preference> · joined <Mon D>" — the join date is resolved to the device
    /// zone at the edge (`Wire.monthDay`); the preference label is server-formatted.
    private func subtitle(_ entry: ProWaitlistEntry) -> String {
        let joined = Wire.monthDay(entry.joinedAt)
        return joined.isEmpty ? entry.preferenceLabel : "\(entry.preferenceLabel) · joined \(joined)"
    }

    private var emptyState: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 8) {
                Text("No one on your waitlist yet")
                    .font(BrandFont.body(15, .bold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text("When a client joins your waitlist, they'll show up here in join order so you can offer them an opening.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.top, 50)
    }

    private func load() async {
        do {
            let outreach = try await session.client.proSchedule.waitlistOutreach()
            phase = .loaded(outreach)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn't load your waitlist just now. Please try again.")
        }
    }

    private func openThread(for entry: ProWaitlistEntry) async {
        guard messageWorkingId == nil else { return }
        messageWorkingId = entry.waitlistEntryId
        defer { messageWorkingId = nil }
        if let thread = try? await session.client.messages.openWaitlistThread(
            waitlistEntryId: entry.waitlistEntryId
        ) {
            messageNav = MessageThreadNav(thread: thread)
        }
    }
}
