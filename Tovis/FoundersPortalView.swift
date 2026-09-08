import SwiftUI
import TovisKit

/// Eligibility-aware entry shared by both account/workspace surfaces. A 403 is
/// intentionally silent: only users admitted by the backend see the row.
struct FounderPortalSection: View {
    @Environment(SessionModel.self) private var session
    @State private var portal: FounderPortal?

    var body: some View {
        Group {
            if let portal {
                BrandSection(title: "Founders") {
                    NavigationLink {
                        FoundersPortalView(initialPortal: portal)
                    } label: {
                        SettingsRowLabel(
                            icon: "sparkles",
                            title: "Founders Portal",
                            subtitle: "Private product feedback community"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task { await loadIfEligible() }
    }

    private func loadIfEligible() async {
        portal = try? await session.client.founders.portal()
    }
}

struct FoundersPortalView: View {
    let initialPortal: FounderPortal

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("FOUNDING CIRCLE")
                        .font(BrandFont.mono(10).weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(BrandColor.accent)
                    Text("Build the future together")
                        .font(BrandFont.display(28, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("Share what works, what feels confusing, and what would make the product indispensable.")
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textMuted)
                }

                ForEach(initialPortal.rooms) { room in
                    NavigationLink {
                        FounderRoomView(room: room, portal: initialPortal)
                    } label: {
                        BrandSurface {
                            HStack(spacing: 12) {
                                Image(systemName: room.audience == .pro ? "sparkles" : "heart")
                                    .foregroundStyle(BrandColor.accent)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(room.label)
                                        .font(BrandFont.body(15, .semibold))
                                        .foregroundStyle(BrandColor.textPrimary)
                                    Text(room.description)
                                        .font(BrandFont.body(11))
                                        .foregroundStyle(BrandColor.textMuted)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer()
                                if room.unreadCount > 0 {
                                    Text("\(room.unreadCount)")
                                        .font(BrandFont.mono(10).weight(.bold))
                                        .foregroundStyle(BrandColor.onAccent)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 4)
                                        .background(BrandColor.accent)
                                        .clipShape(Capsule())
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(BrandColor.textMuted)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                if initialPortal.canAdminister {
                    NavigationLink {
                        FounderAdminView()
                    } label: {
                        SettingsRowLabel(
                            icon: "checkmark.shield",
                            title: "Admin & membership",
                            subtitle: "Monitor the founding community"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Founders Portal")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FounderRoomView: View {
    @Environment(SessionModel.self) private var session
    let room: FounderRoom
    let portal: FounderPortal

    @State private var messages: [FounderMessage] = []
    @State private var draft = ""
    @State private var kind: FounderMessageKind = .chat
    @State private var replyTo: FounderMessage?
    @State private var currentUserId: String?
    @State private var isLoading = true
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var reportedMessageIds: Set<String> = []

    private var availableKinds: [FounderMessageKind] {
        var values: [FounderMessageKind] = [.chat, .question, .bug, .idea, .love]
        if portal.canAdminister { values.append(.announcement) }
        return values
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Opening the conversation…")
                    .frame(maxHeight: .infinity)
            } else if messages.isEmpty {
                ContentUnavailableView(
                    "Start this conversation",
                    systemImage: "person.3",
                    description: Text("Your feedback directly shapes what gets built next.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(messages) { message in
                            messageRow(message)
                        }
                    }
                    .padding(16)
                }
            }

            composer
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle(room.label)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: room.key) {
            currentUserId = await session.client.currentUserId()
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await load(quiet: true)
            }
        }
    }

    private func messageRow(_ message: FounderMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(message.author.displayName.prefix(1)).uppercased())
                .font(BrandFont.body(13, .bold))
                .foregroundStyle(BrandColor.accent)
                .frame(width: 34, height: 34)
                .background(BrandColor.bgSurface)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(message.author.displayName)
                        .font(BrandFont.body(12, .semibold))
                    Text(kindLabel(message.kind).uppercased())
                        .font(BrandFont.mono(8).weight(.bold))
                        .foregroundStyle(BrandColor.accent)
                    Text(Wire.relativeAgo(message.createdAt))
                        .font(BrandFont.body(10))
                        .foregroundStyle(BrandColor.textMuted)
                }
                Text(message.body)
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textPrimary)
                    .padding(11)
                    .background(BrandColor.bgSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                HStack(spacing: 12) {
                    if message.answeredAt != nil {
                        Label("Answered by the team", systemImage: "checkmark.circle.fill")
                            .font(BrandFont.body(10, .semibold))
                            .foregroundStyle(BrandColor.accent)
                    }
                    Button(portal.canModerate && message.kind == .question ? "Answer" : "Reply") {
                        replyTo = message
                    }
                    .font(BrandFont.body(10, .semibold))
                    .foregroundStyle(BrandColor.accent)
                    if message.author.id != currentUserId && !portal.canModerate {
                        Button(reportedMessageIds.contains(message.id) ? "Reported" : "Report") {
                            Task { await report(message) }
                        }
                        .disabled(reportedMessageIds.contains(message.id))
                        .font(BrandFont.body(10, .semibold))
                        .foregroundStyle(BrandColor.textMuted)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(message.author.id == currentUserId ? 0.92 : 1)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage {
                Text(errorMessage).font(BrandFont.body(11)).foregroundStyle(BrandColor.ember)
            }
            if let replyTo {
                HStack {
                    Text("Replying to \(replyTo.author.displayName)")
                        .font(BrandFont.body(10, .semibold))
                        .foregroundStyle(BrandColor.textMuted)
                    Spacer()
                    Button("Cancel") { self.replyTo = nil }
                        .font(BrandFont.body(10, .semibold))
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(availableKinds) { option in
                        Button(kindLabel(option)) { kind = option }
                            .font(BrandFont.body(10, .semibold))
                            .foregroundStyle(kind == option ? BrandColor.onAccent : BrandColor.textMuted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(kind == option ? BrandColor.accent : BrandColor.bgSurface)
                            .clipShape(Capsule())
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Share feedback or ask a question…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(BrandColor.bgSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Button { Task { await send() } } label: {
                    Image(systemName: "paperplane.fill")
                        .frame(width: 42, height: 42)
                        .background(BrandColor.accent)
                        .foregroundStyle(BrandColor.onAccent)
                        .clipShape(Circle())
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
        }
        .padding(12)
        .background(BrandColor.bgSecondary)
    }

    private func load(quiet: Bool = false) async {
        if !quiet { isLoading = true }
        do {
            messages = try await session.client.founders.messages(room: room.key)
            try? await session.client.founders.markRead(room: room.key)
            errorMessage = nil
        } catch let error as APIError {
            if !quiet { errorMessage = error.userMessage }
        } catch {
            if !quiet { errorMessage = "Couldn’t load this conversation." }
        }
        if !quiet { isLoading = false }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        defer { isSending = false }
        do {
            let message = try await session.client.founders.send(
                room: room.key,
                body: text,
                kind: kind,
                replyToId: replyTo?.id
            )
            messages.append(message)
            draft = ""
            kind = .chat
            replyTo = nil
            errorMessage = nil
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Your message couldn’t be sent."
        }
    }

    private func report(_ message: FounderMessage) async {
        do {
            try await session.client.founders.report(messageId: message.id)
            reportedMessageIds.insert(message.id)
            errorMessage = nil
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn’t report this message."
        }
    }

    private func kindLabel(_ kind: FounderMessageKind) -> String {
        switch kind {
        case .chat: "Chat"
        case .question: "Question"
        case .bug: "Bug"
        case .idea: "Idea"
        case .love: "Love"
        case .announcement: "Announcement"
        }
    }
}

private struct FounderAdminView: View {
    @Environment(SessionModel.self) private var session
    @State private var summary: FounderAdminSummary?
    @State private var errorMessage: String?
    @State private var professionalEmail = ""
    @State private var professionalSpecialty: FounderSpecialty = .hair
    @State private var clientEmail = ""
    @State private var sponsorEmail = ""
    @State private var isSaving = false
    @State private var savedMessage: String?

    var body: some View {
        ScrollView {
            if let summary {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
                        metric("\(summary.proSeatsUsed) / 100", "Pro seats")
                        metric("\(summary.activeClients)", "Founding clients")
                        metric("\(summary.unansweredQuestions)", "Questions")
                        metric("\(summary.openReports)", "Open reports")
                    }
                    enrollmentForms
                    if !summary.reports.isEmpty {
                        reportQueue(summary.reports)
                    }
                    Text("FOUNDING ROSTER")
                        .font(BrandFont.mono(10).weight(.bold))
                        .foregroundStyle(BrandColor.textMuted)
                    ForEach(summary.members) { member in
                        BrandSurface {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(member.displayName).font(BrandFont.body(14, .semibold))
                                Text(member.audience == .pro ? (member.specialty ?? "Professional") : "Client Circle \(member.clientSlot ?? 0)")
                                    .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
                            }
                        }
                    }
                }
                .padding(18)
            } else if let errorMessage {
                ContentUnavailableView("Couldn’t load admin", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Founder Admin")
        .task { await load() }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 5) {
                Text(value).font(BrandFont.display(24, .semibold))
                Text(label).font(BrandFont.body(10)).foregroundStyle(BrandColor.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var enrollmentForms: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ADD FOUNDERS")
                .font(BrandFont.mono(10).weight(.bold))
                .foregroundStyle(BrandColor.textMuted)

            BrandSurface {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Professional").font(BrandFont.body(14, .semibold))
                    founderEmailField("Professional email", text: $professionalEmail)
                    Picker("Specialty", selection: $professionalSpecialty) {
                        ForEach(FounderSpecialty.allCases) { specialty in
                            Text(specialty.displayName).tag(specialty)
                        }
                    }
                    Button("Add founding professional") {
                        Task { await enrollProfessional() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandColor.accent)
                    .disabled(professionalEmail.isEmpty || isSaving)
                }
            }

            BrandSurface {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Client").font(BrandFont.body(14, .semibold))
                    founderEmailField("Client email", text: $clientEmail)
                    founderEmailField("Sponsoring pro email", text: $sponsorEmail)
                    Button("Add founding client") {
                        Task { await enrollClient() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandColor.accent)
                    .disabled(clientEmail.isEmpty || sponsorEmail.isEmpty || isSaving)
                }
            }

            if let savedMessage {
                Text(savedMessage)
                    .font(BrandFont.body(11, .semibold))
                    .foregroundStyle(BrandColor.accent)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(BrandFont.body(11))
                    .foregroundStyle(BrandColor.ember)
            }
        }
    }

    private func reportQueue(_ reports: [FounderMessageReport]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("REPORTS TO REVIEW")
                .font(BrandFont.mono(10).weight(.bold))
                .foregroundStyle(BrandColor.textMuted)
            ForEach(reports) { report in
                BrandSurface {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(report.reason.rawValue.replacingOccurrences(of: "_", with: " "))
                            .font(BrandFont.mono(9).weight(.bold))
                            .foregroundStyle(BrandColor.accent)
                        Text(report.message.body)
                            .font(BrandFont.body(13))
                        HStack {
                            Button("Hide message") {
                                Task { await moderate(report, hide: true) }
                            }
                            Button("Keep & resolve") {
                                Task { await moderate(report, hide: false) }
                            }
                        }
                        .font(BrandFont.body(10, .semibold))
                        .disabled(isSaving)
                    }
                }
            }
        }
    }

    private func founderEmailField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
            .padding(11)
            .background(BrandColor.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func enrollProfessional() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await session.client.founders.enrollProfessional(
                email: professionalEmail,
                specialty: professionalSpecialty
            )
            professionalEmail = ""
            savedMessage = "Founding professional added."
            errorMessage = nil
            await load()
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn’t add this professional."
        }
    }

    private func enrollClient() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await session.client.founders.enrollClient(
                email: clientEmail,
                sponsorEmail: sponsorEmail
            )
            clientEmail = ""
            sponsorEmail = ""
            savedMessage = "Founding client added."
            errorMessage = nil
            await load()
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn’t add this client."
        }
    }

    private func moderate(_ report: FounderMessageReport, hide: Bool) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await session.client.founders.moderateReport(
                reportId: report.id,
                hideMessage: hide
            )
            savedMessage = hide ? "Message hidden and report resolved." : "Report resolved."
            errorMessage = nil
            await load()
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn’t resolve this report."
        }
    }

    private func load() async {
        do { summary = try await session.client.founders.adminSummary() }
        catch let error as APIError { errorMessage = error.userMessage }
        catch { errorMessage = "Please try again." }
    }
}
