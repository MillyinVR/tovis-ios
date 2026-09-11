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
    @State private var showingHistory = false
    @State private var authoring = false
    @State private var expectations: LookExpectationTarget?
    @State private var recordedFeedback: ProConsultFeedback?
    @State private var fullscreen: FullscreenMedia?
    private var service: ProConsultService { ProConsultService(api: session.client.api) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error { Text(error).foregroundStyle(BrandColor.textSecondary) }
                if busy { ProgressView() }
                if let brief {
                    if let topLine = brief.topLine, !topLine.isEmpty {
                        ProConsultTopLine(text: topLine)
                    }
                    if let mentor = brief.mentor {
                        ConsultMentorLayer(mentor: mentor)
                    }
                    ProConsultVersionSummary(brief: brief)
                    Button("Read consultation history") { showingHistory = true }
                    if let suitability = brief.currentSuitability {
                        ProSuitabilityView(suitability: suitability)
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
                        if photos.inspirationUrl == nil && photos.captures.isEmpty { Text("No retained photos are available for this consultation.") }
                        if let url = photos.inspirationUrl { photo(url, label: "Inspiration look") }
                        ForEach(photos.captures) { capture in photo(capture.url, label: capture.label) }
                    }
                    ProConsultEvidence(brief: brief)
                    ForEach(brief.styleDirections) { direction in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(direction.title).fontWeight(.semibold)
                            Text(direction.direction)
                            Text(direction.whyItFlatters).foregroundStyle(BrandColor.textSecondary)
                        }
                    }
                    ProConsultSafety(brief: brief)
                    if let plan = brief.lookBrief?.professionalPlan ?? brief.lookPlan, let version = brief.lookBrief {
                        Text("Look brief · version \(version.version)").font(BrandFont.body(18, .semibold))
                        Button("Author or revise the look plan") { authoring = true }
                            .disabled(busy || (version.confirmationOpen ?? version.inputOpen) == false)
                        Text(plan.summary)
                        if version.professionalPlan != nil { Text("Plan authored by your pro after reviewing your details.") }
                        if version.inputOpen == false { Text("The appointment has started. Consult inputs are closed.") }
                        if version.invalidatedProfessionalPlan == true { Text("The client’s details changed. The previous professional plan needs a fresh review.") }
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
                    ProConsultEstimateAndDirections(brief: brief)
                    // C2-4 — only a server that sends the list gets the control:
                    // on one that predates it, asking would 404.
                    if let questions = brief.proFollowUps {
                        ProConsultFollowUpSection(consultId: consultId, questions: questions, busy: busy) {
                            Task { await load() }
                        }
                    }
                    if let feedback = recordedFeedback ?? brief.feedback {
                        Text("Feedback recorded: \(feedback.rating == .accurateUseful ? "Accurate / useful" : "Off")")
                    } else {
                        Text("Was this brief accurate and useful?")
                        HStack {
                            Button("Accurate / useful") { Task { await submitFeedback(.accurateUseful) } }
                            Button("Off") { Task { await submitFeedback(.off) } }
                        }.buttonStyle(.bordered).disabled(busy)
                    }
                } else if !busy { Button("Reload brief") { Task { await load() } } }
            }.font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary).padding()
        }
        .background(BrandColor.bgPrimary).navigationTitle("Look brief")
        .task { await load() }.refreshable { await load() }
        .mediaFullscreenCover($fullscreen)
        .sheet(isPresented: $showingHistory) { ProConsultTranscriptView(consultId: consultId) }
        .sheet(isPresented: $authoring) {
            if let plan = brief?.lookBrief?.professionalPlan ?? brief?.lookPlan, let version = brief?.lookBrief {
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

    private func submitFeedback(_ rating: ProConsultFeedback.Rating) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { recordedFeedback = try await service.feedback(id: consultId, rating: rating) }
        catch { self.error = "Feedback could not be saved. Try again." }
    }

    private func photo(_ url: URL, label: String) -> some View {
        VStack(alignment: .leading) {
            Text(label).fontWeight(.semibold)
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    Button {
                        fullscreen = FullscreenMedia(id: url.absoluteString, source: .remote(url: url, isVideo: false), overlay: nil)
                    } label: { image.resizable().scaledToFit() }
                    .buttonStyle(.plain).accessibilityLabel("Open \(label)")
                case .failure:
                    Text("A photo link expired. Refresh photos to view it again.")
                case .empty: ProgressView()
                @unknown default: EmptyView()
                }
            }.frame(maxHeight: 360)
        }
    }
    private func load() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let loaded = try await service.brief(id: consultId)
            brief = loaded
            recordedFeedback = loaded.feedback
        }
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

private func consultBriefLabel(_ value: String) -> String {
    value.replacingOccurrences(of: "_", with: " ").lowercased().capitalized
}

/// C2-6a — the first line of the Brief. Server-composed, one sentence pair,
/// rendered whole: the pro reads it before anything else on the screen.
struct ProConsultTopLine: View {
    let text: String
    var body: some View {
        Text(text)
            .font(BrandFont.body(16, .semibold))
            .foregroundStyle(BrandColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(BrandColor.bgPrimary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(BrandColor.textPrimary.opacity(0.2), lineWidth: 1))
            .accessibilityIdentifier("consult-brief-top-line")
    }
}

struct ProConsultVersionSummary: View {
    let brief: ProConsultBrief
    var body: some View {
        if let version = brief.planVersion, version > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Updated plan · version \(version)").fontWeight(.semibold)
                if (brief.planChanges ?? []).isEmpty { Text("Your client added something. Nothing in the plan moved.") }
                ForEach(brief.planChanges ?? []) { change in
                    Text("\(change.label): \(change.from ?? "—") → \(change.to ?? "—")")
                }
            }
        }
    }
}

struct ProConsultEvidence: View {
    let brief: ProConsultBrief
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let ai = brief.aiObservations {
                Text("AI observations").font(BrandFont.body(18, .semibold))
                Text("Photo-based observations to verify in person.").foregroundStyle(BrandColor.textSecondary)
                observation("Base level", ai.baseLevel)
                observation("Lightest level", ai.lightestLevel)
                observation("Tone", ai.currentTone)
                observation("Visible condition", ai.visibleCondition)
                observation("Density", ai.density)
                observation("Texture", ai.texture)
                summary("Goal summary", ai.goalSummary)
                summary("History summary", ai.historySummary)
                summary("Constraints", ai.constraintsSummary)
                summary("Maintenance", ai.maintenanceSummary)
                summary("Appointment context", ai.appointmentContextSummary)
            }
            Text("Feature profile").font(BrandFont.body(18, .semibold))
            Text("Photo-based feature observations to confirm in person — color readings from phone photos are approximate; drape to verify.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(BrandColor.textSecondary)
            ForEach(brief.profile.orderedEntries, id: \.label) { entry in observation(entry.label, entry.observation) }
        }
    }
    private func observation(_ label: String, _ value: ConsultObservation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).fontWeight(.semibold)
            Text("\(consultBriefLabel(value.value)) · \(Int((value.confidence.min * 100).rounded()))–\(Int((value.confidence.max * 100).rounded()))% confidence")
                .foregroundStyle(BrandColor.textSecondary)
        }
    }
    private func summary(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(label).fontWeight(.semibold); Text(value) }
    }
}

struct ProConsultSafety: View {
    let brief: ProConsultBrief
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Safety flags").font(BrandFont.body(18, .semibold))
            if let flags = brief.safetyFlags {
                if flags.isEmpty { Text("No flags were identified by this analysis. Confirm history and suitability in person before service.") }
                ForEach(flags) { flag in
                    Text("\(consultBriefLabel(flag.code)): \(flag.summary) Discuss with the professional before service.")
                }
            } else { Text("Safety information is unavailable. Confirm history and suitability in person before service.") }
        }
        .padding().background(BrandColor.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ProConsultEstimateAndDirections: View {
    let brief: ProConsultBrief
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if brief.lookPlan == nil {
                Text("Directions to discuss").font(BrandFont.body(18, .semibold))
                if let direction = brief.achievabilityDirection {
                    Text("Achievability: \(consultBriefLabel(direction.assessment))").fontWeight(.semibold)
                    Text(direction.context)
                    Text(direction.direction)
                }
                ForEach(brief.recommendationDirections ?? []) { direction in
                    Text(direction.title).fontWeight(.semibold)
                    Text(direction.why)
                    Text(direction.direction)
                }
            }
            if let estimate = brief.serviceEstimate {
                Text("Service estimate").font(BrandFont.body(18, .semibold))
                Text("Derived only from your own \(estimate.locationType == "SALON" ? "in-salon" : "mobile") prices and durations. Durations are rounded up to your slot length. You make the final call.")
                if estimate.status == "REFUSED" {
                    Text("No estimate: \(refusal(estimate.refusalCode))")
                } else {
                    ForEach(Array(estimate.lines.enumerated()), id: \.offset) { _, line in
                        Text(line.source == "LOOK_PLAN_REQUIRED" ? "Required for the chosen look" : line.source == "LOOK_LINKED_SERVICE" ? "From the look" : "From the analysis")
                            .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                        Text("\(line.serviceName) · \((Wire.money(line.estimatedPrice) ?? "—")) · \(line.estimatedDurationMinutes) min").fontWeight(.semibold)
                        Text(line.rationale)
                    }
                    Text("Estimated total: \(total(estimate)) · \(estimate.lines.reduce(0) { $0 + $1.estimatedDurationMinutes }) min\((estimate.bufferMinutes ?? 0) > 0 ? " + \(estimate.bufferMinutes ?? 0) min buffer" : "")")
                }
            }
        }
    }
    private func total(_ estimate: ProConsultServiceEstimate) -> String {
        var amount = Decimal.zero
        for line in estimate.lines {
            guard let price = Decimal(string: line.estimatedPrice, locale: Locale(identifier: "en_US_POSIX")) else { return "—" }
            amount += price
        }
        return (Wire.moneyDecimal(amount) ?? "—")
    }
    private func refusal(_ code: String?) -> String {
        switch code {
        case "LOOK_PLAN_SELECTION_REQUIRED": "The client needs to choose and confirm the current look before the first appointment can be sized."
        case "LOOK_SERVICE_UNLINKED": "The look this consult started from no longer names a service."
        case "SERVICE_NOT_ON_MENU": "The service behind this look is not an active offering on your menu."
        case "MENU_MODE_UNAVAILABLE": "That service is not offered in this mode on your menu."
        case "MENU_PRICE_UNSET": "That service has no price set on your menu for this mode."
        case "MENU_DURATION_UNSET": "That service has no duration set on your menu for this mode."
        case "PRO_SCHEDULING_NOT_READY": "There is no bookable location yet."
        default: "Your menu cannot express this look."
        }
    }
}
