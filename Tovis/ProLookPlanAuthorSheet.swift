import SwiftUI
import TovisKit

struct ProLookPlanAuthorSheet: View {
    let consultId: String
    let plan: ConsultLookPlan
    let version: Int
    let onSaved: () -> Void
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var offerings: [ProLookOffering] = []
    @State private var visits: [[String]] = [[]]
    @State private var tier = "EXACT"
    @State private var title = ""
    @State private var summary = ""
    @State private var reasoning = ""
    @State private var reviewNote = ""
    @State private var reviewed = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Text("Create a new version for the client to choose and confirm. Previous price and time overrides are replaced by your menu estimates.")
                Picker("Direction", selection: $tier) {
                    Text("Exact").tag("EXACT"); Text("Close").tag("CLOSE"); Text("Toward").tag("TOWARD")
                }
                TextField("Client-facing look title", text: $title)
                TextField("Desired result", text: $summary, axis: .vertical)
                TextField("Why this direction works", text: $reasoning, axis: .vertical)
                ForEach(visits.indices, id: \.self) { index in
                    Section("Visit \(index + 1) — required work") {
                        ForEach(offerings) { offering in
                            Toggle(offering.name, isOn: Binding(get: { visits[index].contains(offering.offeringId) }, set: { selected in
                                if selected { if visits[index].count < 6 { visits[index].append(offering.offeringId) } }
                                else { visits[index].removeAll { $0 == offering.offeringId } }
                            }))
                        }
                        if visits.count > 1 { Button("Remove visit") { visits.remove(at: index) } }
                    }
                }
                if visits.count < 8 { Button("Add a later visit") { visits.append([]) } }
                TextField("Review note and prerequisites", text: $reviewNote, axis: .vertical)
                Toggle("I reviewed the current photos, preferences, history, and prerequisites.", isOn: $reviewed)
                if let error { Text(error) }
                Button(busy ? "Saving…" : "Save new look version") { Task { await save() } }
                    .disabled(busy || !reviewed || visits.contains(where: \.isEmpty) || title.isEmpty || summary.isEmpty || reasoning.isEmpty || reviewNote.isEmpty)
            }.navigationTitle("Author look plan")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .task {
                    tier = plan.tier.rawValue; title = plan.paths.first?.title ?? ""; summary = plan.summary
                    reasoning = plan.paths.first?.whyThisWorksForYou ?? ""
                    visits = plan.paths.first?.visits.map { $0.steps.map(\.offeringId) } ?? [[]]
                    do { offerings = try await ProConsultService(api: session.client.api).offerings(id: consultId) }
                    catch { self.error = "Could not load your menu. Close and try again." }
                }
        }.tint(BrandColor.accent)
    }
    private func save() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await ProConsultService(api: session.client.api).author(id: consultId, version: version, tier: tier,
                title: title, summary: summary, reasoning: reasoning, reviewNote: reviewNote,
                reviewedClientDetails: reviewed, visits: visits)
            onSaved(); dismiss()
        } catch { self.error = "Could not save. Check the plan and refresh the current brief before trying again." }
    }
}
