// Inbox — the client's message threads (GET /api/v1/messages/threads). A native
// rebuild of the web /messages inbox: one row per conversation with the pro,
// showing the latest preview + an unread dot. Taps push into the thread.
import SwiftUI
import TovisKit

struct InboxView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded([MessageThread])
        case failed(String)
    }

    @State private var phase: Phase = .loading

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView().tint(BrandColor.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .failed(message):
                    errorState(message)
                case let .loaded(threads):
                    if threads.isEmpty { emptyState } else { list(threads) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .refreshable { await load() }
            .task { if case .loading = phase { await load() } }
            .onChange(of: session.refreshTick) { Task { await load() } }
            .task { await poll() }
        }
        .tint(BrandColor.accent)
    }

    private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { await load() }
        }
    }

    private func list(_ threads: [MessageThread]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(threads) { thread in
                    NavigationLink {
                        ThreadView(thread: thread)
                    } label: {
                        ThreadRow(thread: thread)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(BrandColor.textPrimary.opacity(0.08)).padding(.leading, 84)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32)).foregroundStyle(BrandColor.textMuted)
            Text("No messages yet")
                .font(BrandFont.display(20, .semibold)).foregroundStyle(BrandColor.textPrimary)
            Text("When you start a conversation, it shows up here.")
                .font(BrandFont.body(14)).foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again")
                    .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12).padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.horizontal, 40)
    }

    private func load() async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            phase = .loaded(try await session.client.messages.threads())
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Something went wrong. Please try again.")
        }
    }
}

private struct ThreadRow: View {
    let thread: MessageThread

    var body: some View {
        HStack(spacing: 14) {
            BrandAvatar(name: thread.counterpartyName,
                        avatarUrl: thread.counterpartyAvatarUrl, size: 50)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(thread.counterpartyName)
                        .font(BrandFont.body(15, thread.isUnread ? .bold : .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if let when = relativeTime(thread.lastMessageAt) {
                        Text(when).font(BrandFont.mono(10)).foregroundStyle(BrandColor.textMuted)
                    }
                }
                HStack(spacing: 8) {
                    Text(thread.lastMessagePreview ?? "No messages yet")
                        .font(BrandFont.body(13, thread.isUnread ? .medium : .regular))
                        .foregroundStyle(thread.isUnread ? BrandColor.textSecondary : BrandColor.textMuted)
                        .lineLimit(1)
                    Spacer()
                    if thread.isUnread {
                        Circle().fill(BrandColor.accent).frame(width: 8, height: 8)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// Compact "when" for a thread row: time today, weekday this week, else M/d.
func relativeTime(_ iso: String?) -> String? {
    guard let iso, let date = Wire.date(iso) else { return nil }
    let cal = Calendar.current
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    if cal.isDateInToday(date) {
        f.dateFormat = "h:mm a"
    } else if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 {
        f.dateFormat = "EEE"
    } else {
        f.dateFormat = "M/d/yy"
    }
    return f.string(from: date)
}