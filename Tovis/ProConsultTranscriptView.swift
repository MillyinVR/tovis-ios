import SwiftUI
import TovisKit

struct ProConsultTranscriptView: View {
    let consultId: String
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var events: [ProConsultTranscript.Event] = []
    @State private var cursor: String?
    @State private var note = ""
    @State private var busy = false
    @State private var failed = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !note.isEmpty { Text(note).foregroundStyle(BrandColor.textSecondary) }
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(event.title).fontWeight(.semibold)
                            Text(Wire.dateTime(event.createdAt, timeZone: nil)).font(BrandFont.body(12))
                                .foregroundStyle(BrandColor.textSecondary)
                            if event.unavailable { Text("This historical content is unavailable.") }
                            ForEach(Array(event.items.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.label).fontWeight(.medium)
                                    Text(item.value)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .padding().background(BrandColor.bgSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    if busy { ProgressView("Loading consultation history…") }
                    if failed {
                        Text("Consultation history could not be loaded.")
                        Button("Try again") { Task { await load() } }.disabled(busy)
                    } else if cursor != nil {
                        Button("Load more history") { Task { await load() } }.disabled(busy)
                    } else if loaded && events.isEmpty { Text("No saved consultation events yet.") }
                }.padding().font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary)
            }.background(BrandColor.bgPrimary).navigationTitle("Consultation history")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
        }.task { await load() }
    }

    @MainActor private func load() async {
        guard !busy else { return }
        busy = true
        failed = false
        defer { busy = false }
        do {
            let page = try await ProConsultService(api: session.client.api).transcript(id: consultId, cursor: cursor)
            try Task.checkCancellation()
            let existing = Set(events.map(\.id))
            events += page.events.filter { !existing.contains($0.id) }
            cursor = page.nextCursor
            note = page.historyNote
            loaded = true
        } catch {
            // Clear retained history on every failure, including withdrawn access.
            events = []; cursor = nil; note = ""; loaded = false
            if !Task.isCancelled { failed = true }
        }
    }
}
