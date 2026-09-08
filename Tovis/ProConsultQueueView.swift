import SwiftUI
import TovisKit

struct ProConsultQueueView: View {
    @Environment(SessionModel.self) private var session
    @State private var items: [ProConsultQueue.Item] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error { Text(error).foregroundStyle(BrandColor.textSecondary) }
                if loading { ProgressView() }
                if !loading && error == nil && items.isEmpty { Text("No look briefs to review yet.") }
                ForEach(items) { item in
                    NavigationLink { ProConsultBriefView(consultId: item.consultId) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.clientName).font(BrandFont.body(16, .semibold))
                            Text(item.appointmentStatus.map { BookingStatusPresentation.label($0) } ?? "Not booked yet")
                            Text("Version \(item.version) · \(item.professionalConfirmed ? "Reviewed" : "Needs your review")")
                            Text(item.clientConfirmed ? "Client confirmed this version" : "Client confirmation pending")
                            if item.awaitingAnalysis { Text("Client details changed — plan updating") }
                            ForEach(Array(item.changes.enumerated()), id: \.offset) { _, change in Text(change) }
                        }
                        .font(BrandFont.body(13)).foregroundStyle(BrandColor.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                        .background(BrandColor.bgSurface).clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
                if cursor != nil { Button("More look briefs") { Task { await load(more: true) } }.disabled(loading) }
                if error != nil { Button("Try again") { Task { await load() } } }
            }.padding()
        }
        .background(BrandColor.bgPrimary)
        .task { await load() }
        .refreshable { await load() }
    }
    private func load(more: Bool = false) async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await ProConsultService(api: session.client.api).queue(cursor: more ? cursor : nil)
            items = more ? items + result.items : result.items
            cursor = result.nextCursor
        } catch { self.error = "Could not load look briefs. Please try again." }
    }
}

struct ProConsultBriefView: View {
    let consultId: String
    @Environment(SessionModel.self) private var session
    @State private var brief: ProConsultBrief?
    @State private var photos: ProConsultPhotos?
    @State private var busy = false
    @State private var error: String?
    @State private var adjustment: LookAdjustmentTarget?
    @State private var authoring = false
    @State private var expectations: LookExpectationTarget?
    private var service: ProConsultService { ProConsultService(api: session.client.api) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error { Text(error).foregroundStyle(BrandColor.textSecondary) }
                if busy { ProgressView() }
                if let brief {
                    if let mentor = brief.mentor {
                        ConsultMentorLayer(mentor: mentor)
                    }
                    if let inspiration = brief.inspiration {
                        Text("What matters in the inspiration").font(BrandFont.body(18, .semibold))
                        Text(inspiration.referenceNote).foregroundStyle(BrandColor.textSecondary)
                        ForEach(Array(inspiration.exactClientDetails.enumerated()), id: \.offset) { _, detail in
                            Text("\(detail.sentiment == "LIKE" ? "Likes" : detail.sentiment == "DISLIKE" ? "Avoids" : detail.sentiment == "GOAL" ? "Wants" : "Context"): \(detail.clientWords)")
                        }
                    }
                    Text("Client’s words").font(BrandFont.body(18, .semibold))
                    ForEach(brief.lookBrief?.chartSources ?? []) { source in Text(source.summary).font(BrandFont.body(12)) }
                    ForEach(brief.clientIntake + (brief.lookBrief?.additionalClientAnswers ?? [])) { item in
                        VStack(alignment: .leading) { Text(item.question).fontWeight(.semibold); Text(item.answer) }
                    }
                    Button(photos == nil ? "View consultation photos" : "Refresh photos") { Task { await loadPhotos() } }.disabled(busy)
                    if let photos {
                        if let url = photos.inspirationUrl { photo(url, label: "Inspiration look") }
                        ForEach(photos.captures) { capture in photo(capture.url, label: capture.label) }
                    }
                    ForEach(brief.styleDirections) { direction in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(direction.title).fontWeight(.semibold)
                            Text(direction.direction)
                            Text(direction.whyItFlatters).foregroundStyle(BrandColor.textSecondary)
                        }
                    }
                    if let plan = brief.lookPlan, let version = brief.lookBrief {
                        Text("Look brief · version \(version.version)").font(BrandFont.body(18, .semibold))
                        Button("Author or revise the look plan") { authoring = true }
                            .disabled(busy || (version.confirmationOpen ?? version.inputOpen) == false)
                        Text(plan.summary)
                        if version.correctionsNeedReview {
                            Text("Earlier corrections need review before this look can be confirmed.")
                            ForEach(Array((version.invalidatedAdjustments ?? []).enumerated()), id: \.offset) { _, entry in
                                Text("Option \(entry.pathIndex + 1): \(entry.field.lowercased()) — \(entry.value)")
                            }
                        }
                        Text(plan.tier.rawValue.capitalized)
                        ForEach(Array(plan.paths.enumerated()), id: \.offset) { pathIndex, path in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(path.title).fontWeight(.semibold)
                                Text(path.whyThisWorksForYou)
                                ForEach((version.adjustments ?? []).filter { $0.field == "EXPECTATIONS" && $0.pathIndex == pathIndex }, id: \.pathIndex) { note in
                                    Text("Expected result: \(note.value)")
                                }
                                Button("Clarify expected result") {
                                    expectations = LookExpectationTarget(version: version.version, pathIndex: pathIndex,
                                        value: version.adjustments?.first { $0.field == "EXPECTATIONS" && $0.pathIndex == pathIndex }?.value ?? "")
                                }.disabled(busy || version.awaitingAnalysis || (version.confirmationOpen ?? version.inputOpen) == false)
                                Text("\(path.sessionCount) planned visit\(path.sessionCount == 1 ? "" : "s")")
                                ForEach(Array(path.visits.enumerated()), id: \.offset) { visitIndex, visit in
                                    Text("Visit \(visitIndex + 1): \(visit.steps.map(\.serviceName).joined(separator: " + "))")
                                }
                                ForEach(version.pathEstimates.filter { $0.pathIndex == pathIndex }, id: \.locationType) { estimate in
                                    Text(estimate.locationType == "SALON" ? "At the salon" : "Mobile")
                                    Text("First appointment: \(estimate.firstAppointment.formattedSummary)")
                                    if path.sessionCount > 1 { Text("Whole transformation: \(estimate.transformation.formattedSummary)") }
                                    ForEach(Array(estimate.visits.enumerated()), id: \.offset) { visitIndex, visit in
                                        ForEach(visit.steps, id: \.offeringId) { step in
                                            Button("Adjust visit \(visitIndex + 1) · \((path.visits.indices.contains(visitIndex) ? path.visits[visitIndex].steps.first(where: { $0.offeringId == step.offeringId })?.serviceName : nil) ?? "required work")") {
                                                adjustment = LookAdjustmentTarget(version: version.version, pathIndex: pathIndex,
                                                    visitIndex: visitIndex, offeringId: step.offeringId, locationType: estimate.locationType,
                                                    price: step.price ?? "", minutes: step.durationMinutes.map(String.init) ?? "")
                                            }.disabled(busy || version.awaitingAnalysis || (version.confirmationOpen ?? version.inputOpen) == false)
                                        }
                                    }
                                }
                            }.padding().background(BrandColor.bgSurface).clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        ForEach(Array(version.changes.enumerated()), id: \.offset) { _, change in Text(change) }
                        Text(version.clientConfirmed ? "Client confirmed this version" : "Client confirmation pending")
                        Text(version.professionalConfirmed ? "You confirmed this version" : "Your confirmation is needed")
                        if let reserved = version.reservedDurationMinutes { Text("Reserved appointment: \(reserved) min. Changes need a new availability check and confirmation.") }
                        Text("Estimate — your pro will confirm. Tip not included.").foregroundStyle(BrandColor.textSecondary)
                        Button(version.professionalConfirmed ? "Version confirmed" : "Confirm this look") { Task { await confirm(version.version) } }
                            .disabled(busy || version.professionalConfirmed || version.selectedPathIndex == nil || version.awaitingAnalysis || version.confirmationOpen == false || version.correctionsNeedReview)
                        if let visit = version.completedVisit { ConsultCompletedVisitView(visit: visit) }
                        if let bookingId = version.bookingId {
                            NavigationLink("Open appointment and session record") { ProBookingDetailView(bookingId: bookingId) }
                        }
                        Text(version.selectedPathIndex != nil && !version.awaitingAnalysis
                            ? (version.clientConfirmed && version.professionalConfirmed ? "You both confirmed this look." : "Review and confirm this version together.")
                            : plan.nextStep)
                    }
                } else if !busy { Button("Reload brief") { Task { await load() } } }
            }.font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary).padding()
        }
        .background(BrandColor.bgPrimary).navigationTitle("Look brief")
        .task { await load() }.refreshable { await load() }
        .sheet(isPresented: $authoring) {
            if let plan = brief?.lookPlan, let version = brief?.lookBrief {
                ProLookPlanAuthorSheet(consultId: consultId, plan: plan, version: version.version) { Task { await load() } }
            }
        }
        .sheet(item: $expectations) { target in
            ProLookExpectationSheet(consultId: consultId, target: target) { Task { await load() } }
        }
        .sheet(item: $adjustment) { target in
            ProLookAdjustmentSheet(consultId: consultId, target: target) { Task { await load() } }
        }
    }

    private func photo(_ url: URL, label: String) -> some View {
        VStack(alignment: .leading) {
            Text(label).fontWeight(.semibold)
            AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }
                .frame(maxHeight: 360)
        }
    }
    private func load() async {
        busy = true; error = nil
        defer { busy = false }
        do { brief = try await service.brief(id: consultId) }
        catch { self.error = "Could not load this look brief. Please try again." }
    }
    private func loadPhotos() async {
        busy = true; error = nil
        defer { busy = false }
        do { photos = try await service.photos(id: consultId) }
        catch { self.error = "Photos are unavailable. They may have expired or been removed." }
    }
    private func confirm(_ version: Int) async {
        busy = true; error = nil
        do { try await service.confirm(id: consultId, version: version); await load() }
        catch { self.error = "The look may have changed. Refresh and review the current version." }
        busy = false
    }
}

struct LookAdjustmentTarget: Identifiable {
    let version: Int
    let pathIndex: Int
    let visitIndex: Int
    let offeringId: String
    let locationType: String
    let price: String
    let minutes: String
    var id: String { "\(version):\(pathIndex):\(visitIndex):\(offeringId):\(locationType)" }
}

private struct ProLookAdjustmentSheet: View {
    let consultId: String
    let target: LookAdjustmentTarget
    let onSaved: () -> Void
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var price = ""
    @State private var minutes = ""
    @State private var reason = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Price (zero is complimentary)", text: $price).keyboardType(.decimalPad)
                TextField("Minutes", text: $minutes).keyboardType(.numberPad)
                TextField("Reason (optional)", text: $reason)
                if let error { Text(error) }
                Button(busy ? "Saving…" : "Save for this version") { Task { await save() } }.disabled(busy)
            }.navigationTitle("Adjust look")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .onAppear { price = target.price; minutes = target.minutes }
        }.tint(BrandColor.accent)
    }
    private func save() async {
        let priceInput = price.trimmingCharacters(in: .whitespacesAndNewlines)
        let minutesInput = minutes.trimmingCharacters(in: .whitespacesAndNewlines)
        let amount = Decimal(string: priceInput, locale: Locale(identifier: "en_US_POSIX"))
        let duration = Int(minutesInput)
        guard (!priceInput.isEmpty || !minutesInput.isEmpty),
              (priceInput.isEmpty || (amount.map { $0 >= 0 } ?? false)),
              (minutesInput.isEmpty || (duration.map { $0 > 0 } ?? false)) else {
            error = "Enter a valid price or time to adjust."; return
        }
        let normalized = amount.map(CheckoutMoney.fixed2)
        busy = true; error = nil
        defer { busy = false }
        do {
            try await ProConsultService(api: session.client.api).adjust(id: consultId, version: target.version,
                pathIndex: target.pathIndex, visitIndex: target.visitIndex, offeringId: target.offeringId,
                locationType: target.locationType, price: normalized, minutes: duration.map(String.init), reason: reason.isEmpty ? nil : reason)
            onSaved(); dismiss()
        } catch { self.error = "Could not save. The look may have changed; refresh and review it." }
    }
}

private struct LookExpectationTarget: Identifiable {
    let version: Int
    let pathIndex: Int
    let value: String
    var id: Int { pathIndex }
}

private struct ProLookExpectationSheet: View {
    let consultId: String
    let target: LookExpectationTarget
    let onSaved: () -> Void
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("What the client can expect") { TextEditor(text: $value).frame(minHeight: 120) }
                Text("This creates a new version for both of you to confirm.")
                if let error { Text(error) }
                Button(busy ? "Saving…" : "Save expectations") { Task { await save() } }
                    .disabled(busy || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.count > 600)
            }
            .navigationTitle("Expected result")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
            .onAppear { value = target.value }
        }
    }
    private func save() async {
        busy = true
        defer { busy = false }
        do {
            try await ProConsultService(api: session.client.api).expectations(id: consultId, version: target.version,
                pathIndex: target.pathIndex, value: value.trimmingCharacters(in: .whitespacesAndNewlines))
            onSaved()
            dismiss()
        } catch { self.error = "Could not save expectations. Reload the brief and try again." }
    }
}

struct ConsultMentorLayer: View {
    let mentor: ConsultMentor
    var body: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text(mentor.title).font(BrandFont.body(20, .semibold))
                Text(mentor.authority).font(BrandFont.body(13))
                ForEach(mentor.sections) { section in
                    Text("\(section.id). \(section.title)").font(BrandFont.body(16, .semibold))
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        Text(item.text).font(BrandFont.body(13))
                    }
                }
                Text(mentor.formulationNote).font(BrandFont.body(12))
            }
        }.accessibilityIdentifier("consult-mentor")
    }
}
