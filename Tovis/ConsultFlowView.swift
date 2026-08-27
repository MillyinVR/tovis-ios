import PhotosUI
import SwiftUI
import TovisKit
import UIKit

struct ConsultFlowView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let bookingId: String
    let professionalId: String
    var suppliedService: (any ConsultServicing)?
    var exposure: ConsultExposurePolicy = .production

    @State private var model: ConsultFlowViewModel?
    @State private var showRevokeConfirmation = false
    @State private var fullscreen: FullscreenMedia?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView().tint(BrandColor.accent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Beauty consult")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(BrandColor.textSecondary)
                }
            }
            .task {
                guard model == nil else { return }
                let created = ConsultFlowViewModel(
                    bookingId: bookingId,
                    professionalId: professionalId,
                    service: suppliedService ?? session.client.consult,
                    exposure: exposure
                )
                model = created
                await created.start()
            }
            .confirmationDialog(
                "Stop this consult and revoke consent?",
                isPresented: $showRevokeConfirmation,
                titleVisibility: .visible
            ) {
                Button("Revoke consent", role: .destructive) {
                    Task { await model?.revokeSensitiveConsent() }
                }
                Button("Keep consult", role: .cancel) {}
            } message: {
                Text("No more intake, photos, or analysis can be added. The server will make raw consult photos purge-eligible and verify their removal.")
            }
            .mediaFullscreenCover($fullscreen)
        }
        .tint(BrandColor.accent)
    }

    @ViewBuilder
    private func content(_ model: ConsultFlowViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let failure = model.failure {
                    BrandErrorBanner(message: failure.message)
                }

                switch model.stage {
                case .prerequisites:
                    prerequisites(model)
                case .intake:
                    intake(model)
                case .capture:
                    capture(model)
                case .analysis:
                    analysis(model)
                case .results:
                    if let results = model.results { resultsView(results, model: model) }
                    else { loadingCard("Loading your consult…") }
                case .stopped:
                    stopped
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            if model.stage != .prerequisites, model.stage != .stopped,
               model.agreementState?.allCurrent == true {
                Button("Privacy & revoke consent") { showRevokeConfirmation = true }
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(BrandColor.textMuted)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(BrandColor.bgPrimary)
            }
        }
    }

    private func prerequisites(_ model: ConsultFlowViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            consultHeader(
                eyebrow: "Before photos or intake",
                title: "Your consent comes first",
                body: "Review sensitive-data consent and confirm that you’re 18 or older. They are separate prerequisites."
            )
            if let state = model.agreementState {
                ForEach(state.requirements) { requirement in
                    BrandSurface {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(requirement.requiredVersion.title)
                                    .font(BrandFont.body(16, .semibold))
                                    .foregroundStyle(BrandColor.textPrimary)
                                Spacer()
                                if requirement.isAccepted {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(BrandColor.emerald)
                                }
                            }
                            Text(requirement.requiredVersion.body)
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textSecondary)
                            if !requirement.isAccepted {
                                Button {
                                    Task { await model.accept(requirement) }
                                } label: {
                                    Text(requirement.kind == .adult18PlusAttestation
                                         ? "I confirm I’m 18 or older"
                                         : "I consent")
                                        .font(BrandFont.body(14, .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .foregroundStyle(BrandColor.onAccent)
                                        .background(BrandColor.accent)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .disabled(model.busy)
                            }
                        }
                    }
                }
            } else if model.failure == nil {
                loadingCard("Loading prerequisites…")
            }
        }
    }

    private func intake(_ model: ConsultFlowViewModel) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            consultHeader(
                eyebrow: "In your words",
                title: "Tell your professional what you want",
                body: "Your answers—including color and chemical history—stay in your booking-attached consult and appear before AI observations."
            )
            if let intake = model.intakeState {
                ForEach(intake.questionPack.questions) { question in
                    BrandSection(
                        title: question.label,
                        trailing: question.requirement == .required ? "Required" : "Optional"
                    ) {
                        FlowLayout(spacing: 8, lineSpacing: 8) {
                            ForEach(question.options) { option in
                                answerChip(
                                    option,
                                    selected: model.answers[question.key] == option.value
                                ) {
                                    model.selectAnswer(questionKey: question.key, value: option.value)
                                }
                            }
                        }
                    }
                }
                primaryButton("Continue to photos", busy: model.busy,
                              disabled: !model.canSubmitIntake) {
                    Task { await model.submitIntake() }
                }
            } else {
                loadingCard("Loading intake…")
            }
        }
    }

    private func capture(_ model: ConsultFlowViewModel) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            inspirationSection(model)
            consultHeader(
                eyebrow: "Seven daylight views",
                title: "Take guided photos of your hair and face",
                body: "Four hair views and three face views. Each photo is checked right away, and if one can’t be used you’ll see why. You can run the analysis without all seven — anything the missing photos would have shown just comes back as unknown."
            )
            if let capture = model.captureState {
                ForEach(capture.shotPack.shots) { shot in
                    let slot = capture.slots.first { $0.shotKey == shot.key }
                    ConsultPhotoPickerSlot(
                        shot: shot,
                        slot: slot,
                        thumbnail: model.localThumbnails[shot.key],
                        busy: model.processingShot == shot.key,
                        disabled: model.busy,
                        onJPEG: { data in await model.submitPhoto(data, for: shot) },
                        onThumbnailTap: { image in
                            fullscreen = .local(id: "consult-shot-\(shot.key.rawValue)", image: image)
                        }
                    )
                }
                chartCopyToggle(model, capture: capture)
                if model.canRetryPhoto {
                    Button("Retry the private upload") { Task { await model.retryPhoto() } }
                        .font(BrandFont.body(14, .semibold))
                        .foregroundStyle(BrandColor.accent)
                }
                Text("\(model.acceptedShotCount) / \(model.totalShotCount) photos accepted")
                    .font(BrandFont.mono(10))
                    .foregroundStyle(BrandColor.textMuted)
                if model.canOfferPartialContinue {
                    partialContinueCard(model)
                }
            } else {
                loadingCard("Loading photo checklist…")
            }
        }
    }

    private func partialContinueCard(_ model: ConsultFlowViewModel) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 10) {
                Text("You can keep going with the photos that were accepted. The views you skip can’t be analyzed, so those parts of your results will honestly say unknown.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
                primaryButton(
                    "Continue with \(model.acceptedShotCount) of \(model.totalShotCount) photos",
                    busy: model.busy,
                    disabled: !model.inspirationDone
                ) {
                    Task { await model.proceedWithAccepted() }
                }
                if !model.inspirationDone {
                    Text("Finish the inspiration step above first.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
        }
        .accessibilityIdentifier("consult-partial-continue")
    }

    @ViewBuilder
    private func inspirationSection(_ model: ConsultFlowViewModel) -> some View {
        if let inspiration = model.inspirationState {
            if inspiration.isComplete {
                BrandSurface {
                    Label(
                        inspiration.source == nil
                            ? "Inspiration: continuing without a photo"
                            : "Inspiration done — your professional sees exactly what you picked out",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)
                }
                .accessibilityIdentifier("consult-inspiration-complete")
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    consultHeader(
                        eyebrow: "Your inspiration",
                        title: "Show us the look you’re drawn to",
                        body: inspiration.introduction
                    )
                    if inspiration.progress.blocker == .sourceDecisionRequired {
                        inspirationSourceDecision(model)
                    }
                    if let question = inspiration.progress.currentQuestion {
                        if let source = inspiration.source, source.imageAvailable {
                            ConsultInspirationImagePanel(
                                model: model,
                                questionKey: question.key,
                                referenceNote: inspiration.referenceNote,
                                onTap: { url in
                                    fullscreen = FullscreenMedia(
                                        id: "consult-inspiration",
                                        source: .remote(url: url, isVideo: false),
                                        overlay: nil
                                    )
                                }
                            )
                        }
                        if inspiration.progress.blocker == .atLeastThreeDetailsRequired {
                            Text("Pick out at least three specific details you love or want to avoid across these questions — answers like “not sure” don’t give your professional anything to work from, so a couple of questions are coming back around.")
                                .font(BrandFont.body(12))
                                .foregroundStyle(BrandColor.textPrimary)
                                .padding(10)
                                .background(BrandColor.amber.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        ConsultInspirationQuestionView(
                            question: question,
                            busy: model.busy,
                            onAnswer: { values, text, sentiment in
                                Task {
                                    await model.answerInspiration(
                                        question: question,
                                        selectedValues: values,
                                        text: text,
                                        sentiment: sentiment
                                    )
                                }
                            }
                        )
                        .id(question.key)
                    }
                }
            }
        } else {
            loadingCard("Loading your inspiration step…")
        }
    }

    private func inspirationSourceDecision(_ model: ConsultFlowViewModel) -> some View {
        ConsultInspirationPhotoPicker(
            busy: model.busy,
            onJPEG: { data in await model.uploadInspirationPhoto(data) },
            onSkip: { Task { await model.skipInspiration() } }
        )
    }

    private func analysis(_ model: ConsultFlowViewModel) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            consultHeader(
                eyebrow: "Analysis",
                title: "Run your analysis",
                body: "Your professional remains the authority on what’s safe and achievable. Raw photos are made purge-eligible as soon as analysis consumes them."
            )
            if let analysis = model.analysisState, analysis.status == .analysisPending {
                BrandSurface {
                    Text("Your photos and answers are ready. The analysis takes a minute or two, and your photos are deleted from processing storage right after it finishes.")
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                primaryButton(
                    model.busy ? "Analyzing — hold tight…" : "Run my analysis",
                    busy: model.busy, disabled: false
                ) {
                    Task { await model.startAnalysis() }
                }
            } else {
                loadingCard(model.busy ? "Reviewing your photos…" : "Analysis is still processing.")
                if !model.busy {
                    primaryButton("Check results", busy: false, disabled: false) {
                        Task { await model.refreshAnalysis() }
                    }
                }
            }
        }
    }

    private func resultsView(_ results: ConsultClientResults,
                             model: ConsultFlowViewModel) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            consultHeader(
                eyebrow: "Your beauty consult",
                title: "Directions to discuss with your professional",
                body: "These are conversation starters, not promises. Your professional will assess you in person and tell you what’s actually achievable."
            )

            // Keep this sequence aligned with ConsultResultPresentation.sections.
            clientWords(results)
            observations(results.aiObservations)
            featureProfile(results.profile)
            styleDirectionsSection(results.styleDirections)
            safety(results.safetyFlags)
            achievability(results.achievabilityDirection)
            directions(results.recommendationDirections)
            lockedMeCard(model)
        }
    }

    private func chartCopyToggle(_ model: ConsultFlowViewModel,
                                 capture: ConsultCaptureState) -> some View {
        BrandSurface {
            Toggle(isOn: Binding(
                get: { capture.chartCopy.optIn },
                set: { newValue in Task { await model.setChartCopy(newValue) } }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keep these photos on my chart")
                        .font(BrandFont.body(14, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("Private to you and your professional, for future appointments. Turn it off any time before analysis runs — otherwise photos are deleted after analysis either way.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                }
            }
            .tint(BrandColor.accent)
            .disabled(model.busy)
        }
        .accessibilityIdentifier("consult-chart-copy-toggle")
    }

    private func featureProfile(_ profile: ConsultFeatureProfile) -> some View {
        BrandSection(title: "Your feature profile") {
            VStack(spacing: 8) {
                Text("What the photos suggest about your features, so recommendations enhance what is already yours. Your professional confirms these in person — color readings from photos are approximate.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array(profile.orderedEntries.enumerated()), id: \.offset) { _, entry in
                    observationRow(entry.label, value: entry.observation.value,
                                   confidence: entry.observation.confidence)
                }
            }
        }
        .accessibilityIdentifier("consult-results-feature-profile")
    }

    private func styleDirectionsSection(_ directions: [ConsultStyleDirection]) -> some View {
        BrandSection(title: "What will flatter you most", trailing: "\(directions.count)") {
            VStack(spacing: 10) {
                Text("One direction per area, chosen to enhance your actual features rather than follow a trend. Each is a starting point to discuss with your professional.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(directions) { direction in
                    BrandSurface {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(direction.domainLabel.uppercased())
                                .font(BrandFont.mono(10))
                                .foregroundStyle(BrandColor.accent)
                            Text(direction.title)
                                .font(BrandFont.body(16, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                            Text(direction.direction)
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textSecondary)
                            Text("Why this flatters you: \(direction.whyItFlatters)")
                                .font(BrandFont.body(13, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("consult-results-style-directions-\(directions.count)")
    }

    private func clientWords(_ results: ConsultClientResults) -> some View {
        BrandSection(title: "What you told us") {
            BrandSurface {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(results.clientIntake) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.question)
                                .font(BrandFont.body(12, .semibold))
                                .foregroundStyle(BrandColor.textMuted)
                            Text(item.answer)
                                .font(BrandFont.body(14, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("consult-results-client-words")
    }

    private func observations(_ observations: ConsultAIObservations) -> some View {
        BrandSection(title: "Photo-based observations") {
            VStack(spacing: 8) {
                observationRow(
                    "Current level",
                    value: observations.currentLevel.min.flatMap { min in
                        observations.currentLevel.max.map { "Level \(min)–\($0)" }
                    } ?? "Unknown",
                    confidence: observations.currentLevel.confidence
                )
                observationRow("Tone", value: observations.currentTone.value,
                               confidence: observations.currentTone.confidence)
                observationRow("Visible condition", value: observations.visibleCondition.value,
                               confidence: observations.visibleCondition.confidence)
                observationRow("Density", value: observations.density.value,
                               confidence: observations.density.confidence)
                observationRow("Texture", value: observations.texture.value,
                               confidence: observations.texture.confidence)
            }
        }
        .accessibilityIdentifier("consult-results-ai-observations")
    }

    private func safety(_ flags: [ConsultSafetyFlag]) -> some View {
        BrandSection(title: "Safety to discuss") {
            BrandSurface(tint: BrandColor.amber.opacity(0.12)) {
                VStack(alignment: .leading, spacing: 8) {
                    if flags.isEmpty {
                        Text("No specific safety flags were identified. Your professional still needs to assess your hair and history in person.")
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textSecondary)
                    } else {
                        ForEach(flags) { flag in
                            Text("\(ConsultResultPresentation.codeLabel(flag.code)): \(flag.summary) Discuss this with your professional.")
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textPrimary)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("consult-results-safety-always-visible")
    }

    private func achievability(_ direction: ConsultAchievabilityDirection) -> some View {
        BrandSection(title: "What may be achievable") {
            BrandSurface {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ConsultResultPresentation.codeLabel(direction.assessment))
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(direction.context)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                    Text(direction.direction)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("Your professional will confirm the plan after an in-person assessment.")
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.accent)
                }
            }
        }
    }

    private func directions(_ recommendations: [ConsultRecommendationDirection]) -> some View {
        BrandSection(title: "Hair color directions", trailing: "\(recommendations.count)") {
            VStack(spacing: 10) {
                ForEach(Array(recommendations.enumerated()), id: \.element.id) { index, item in
                    BrandSurface {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(index + 1) / \(recommendations.count)")
                                .font(BrandFont.mono(10))
                                .foregroundStyle(BrandColor.accent)
                            Text(item.title)
                                .font(BrandFont.body(16, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                            Text(item.why)
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textSecondary)
                            Text("A direction to discuss with your professional: \(item.title).")
                                .font(BrandFont.body(13, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("consult-results-directions-\(recommendations.count)")
    }

    private func lockedMeCard(_ model: ConsultFlowViewModel) -> some View {
        BrandSection(title: "Me card · locked") {
            BrandSurface(tint: BrandColor.bgSecondary) {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Your full Me card", systemImage: "lock.fill")
                        .font(BrandFont.display(19, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("A future Me card could hold a deeper private analysis. It isn’t available in this pilot.")
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                    Button(model.teaserTapped ? "Interest noted" : "I’d use this") {
                        Task { await model.tapLockedMeCard() }
                    }
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(BrandColor.bgSurface)
                    .clipShape(Capsule())
                    .disabled(model.teaserTapped || model.busy)
                }
            }
        }
        .accessibilityIdentifier("consult-me-card-locked")
    }

    private var stopped: some View {
        consultHeader(
            eyebrow: "Consult stopped",
            title: "Your consent was revoked",
            body: "No more intake, photos, or analysis can be added to this consult."
        )
    }

    private func consultHeader(eyebrow: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased())
                .font(BrandFont.mono(10))
                .tracking(1.3)
                .foregroundStyle(BrandColor.accent)
            Text(title)
                .font(BrandFont.display(26, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text(body)
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    private func answerChip(_ option: ConsultIntakeOption, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(option.label)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(selected ? BrandColor.onAccent : BrandColor.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(selected ? BrandColor.accent : BrandColor.bgSurface)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func observationRow(_ label: String, value: String,
                                confidence: ConsultConfidence) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 3) {
                Text(label.uppercased())
                    .font(BrandFont.mono(10))
                    .foregroundStyle(BrandColor.textMuted)
                Text("\(ConsultResultPresentation.codeLabel(value)) · \(ConsultResultPresentation.confidence(confidence))")
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
            }
        }
    }

    private func loadingCard(_ text: String) -> some View {
        BrandSurface {
            HStack(spacing: 10) {
                ProgressView().tint(BrandColor.accent)
                Text(text).font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary)
            }
        }
    }

    private func primaryButton(_ title: String, busy: Bool, disabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().tint(BrandColor.onAccent) }
                else { Text(title).font(BrandFont.body(16, .semibold)) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(BrandColor.onAccent)
            .background(BrandColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(disabled || busy)
    }
}

/// Client-readable reasons for a refused photo, mirroring the web wizard's
/// QUALITY_REASON_COPY map. The retake tip is appended separately.
private func consultQualityReasonMessage(_ code: String?) -> String {
    switch code {
    case "WARM_INDOOR_LIGHT":
        return "Warm indoor lighting — hair color can’t be read accurately under it."
    case "COLOR_CAST":
        return "A color tint in the light is masking the true hair color."
    case "VIEW_MISMATCH":
        return "This doesn’t look like the view this photo asks for."
    case "HAIR_NOT_VISIBLE":
        return "The hair isn’t clearly visible in this photo."
    case "BLURRY":
        return "The photo is too blurry to use."
    case "TOO_DARK":
        return "The photo is too dark to read."
    case "TOO_BRIGHT":
        return "The photo is too bright or washed out."
    default:
        return "This photo can’t be used for the analysis."
    }
}

private struct ConsultPhotoPickerSlot: View {
    let shot: ConsultCaptureShot
    let slot: ConsultCaptureSlot?
    let thumbnail: UIImage?
    let busy: Bool
    let disabled: Bool
    let onJPEG: (Data) async -> Void
    let onThumbnailTap: (UIImage) -> Void

    @State private var pick: PhotosPickerItem?
    @State private var preparationError: ConsultClientFailure?
    @State private var localRetakeReason: String?
    @State private var showGuidedCamera = false
    @State private var pipeline = ConsultTransientPhotoPipeline()

    var body: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(shot.title)
                                .font(BrandFont.body(16, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                            Spacer()
                            status
                        }
                        Text(shot.instruction)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                    if let thumbnail {
                        Button { onThumbnailTap(thumbnail) } label: {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View your \(shot.title) photo")
                    }
                }

                if slot?.state == .rejected {
                    let reason = consultQualityReasonMessage(slot?.qualityReasonCode)
                    let tip = slot?.retakeTip
                    Text(tip.map { "\(reason) \($0)" } ?? reason)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.amber)
                        .accessibilityLabel("Why this photo was refused: \(reason)\(tip.map { " Retake tip: \($0)" } ?? "")")
                }
                if let preparationError {
                    Text(preparationError.message)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.ember)
                }
                if let localRetakeReason {
                    Text(localRetakeReason)
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.amber)
                }

                Button { showGuidedCamera = true } label: {
                    Label(guidedButtonTitle, systemImage: "camera.viewfinder")
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(BrandColor.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(disabled)

                PhotosPicker(selection: $pick, matching: .images) {
                    Label(pickerButtonTitle, systemImage: "photo.on.rectangle")
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(disabled ? BrandColor.textMuted : BrandColor.textSecondary)
                }
                .disabled(disabled)
            }
        }
        .fullScreenCover(isPresented: $showGuidedCamera) {
            ConsultGuidedCaptureView(shot: shot, onJPEG: onJPEG)
        }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task {
                defer { pick = nil }
                do {
                    guard let source = try await item.loadTransferable(type: Data.self) else {
                        preparationError = .invalidPhoto
                        return
                    }
                    switch await pipeline.process(
                        source,
                        expectations: ConsultShotGuidance.expectations(for: shot.key)
                    ) {
                    case let .accepted(jpeg):
                        preparationError = nil
                        localRetakeReason = nil
                        await onJPEG(jpeg)
                    case let .retake(reason):
                        preparationError = nil
                        localRetakeReason = reason
                    case .invalid:
                        localRetakeReason = nil
                        preparationError = .invalidPhoto
                    case .cancelled:
                        break
                    }
                } catch {
                    preparationError = .invalidPhoto
                }
            }
        }
    }

    private var guidedButtonTitle: String {
        switch slot?.state {
        case .accepted: return "Retake with guided camera"
        case .rejected: return "Take guided retake"
        default: return "Open guided camera"
        }
    }

    private var pickerButtonTitle: String {
        switch slot?.state {
        case .accepted: return "Replace from Photos instead"
        case .rejected: return "Choose a retake from Photos instead"
        default: return "Choose from Photos instead"
        }
    }

    @ViewBuilder
    private var status: some View {
        if busy {
            ProgressView().tint(BrandColor.accent)
        } else {
            switch slot?.state {
            case .accepted:
                Label("Passed", systemImage: "checkmark.circle.fill")
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(BrandColor.emerald)
            case .rejected:
                Label("Retake", systemImage: "arrow.clockwise.circle.fill")
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(BrandColor.amber)
            default:
                Text("Required")
                    .font(BrandFont.body(11, .semibold))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
    }
}

/// Where to look in the inspiration photo for each question — presentation-only
/// guidance beside the server-served question copy, mirrored from the web wizard.
private let consultInspirationFocusHints: [String: String] = [
    "favorite_colors": "Zoom into the hair and look at the mix of colors — the brightest pieces, the deepest pieces, and the tones in between.",
    "avoid_colors": "Look over each color in the hair again — is there any you would not want on you?",
    "length_goal": "Look at where the hair ends — how long it falls.",
    "fullness_goal": "Look at how thick and full the hair appears overall.",
    "current_styling": "Look at how the hair is styled — straight, waves, curls, or something else.",
    "styling_walkthrough": "Think about whether you could get it styled this way on your own.",
    "other_detail": "One last look — anything else stand out, good or bad?",
]

/// The inspiration source decision: add one reference photo of a look, or
/// continue without one. Uses the photo library only — an inspiration picture
/// is of a LOOK someone else wears, not something the guided camera frames.
private struct ConsultInspirationPhotoPicker: View {
    let busy: Bool
    let onJPEG: (Data) async -> Void
    let onSkip: () -> Void

    @State private var pick: PhotosPickerItem?
    @State private var preparing = false
    @State private var preparationError: ConsultClientFailure?

    var body: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 10) {
                if let preparationError {
                    Text(preparationError.message)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.ember)
                }
                PhotosPicker(selection: $pick, matching: .images) {
                    Group {
                        if busy || preparing {
                            ProgressView().tint(BrandColor.onAccent)
                        } else {
                            Label("Add an inspiration photo", systemImage: "photo.on.rectangle")
                                .font(BrandFont.body(14, .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(BrandColor.onAccent)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(busy || preparing)
                Button(action: onSkip) {
                    Text("Continue without one")
                        .font(BrandFont.body(14, .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(BrandColor.textPrimary)
                        .background(BrandColor.bgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(busy || preparing)
            }
        }
        .accessibilityIdentifier("consult-inspiration-source-decision")
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task {
                defer { pick = nil }
                preparing = true
                defer { preparing = false }
                do {
                    guard let source = try await item.loadTransferable(type: Data.self),
                          let jpeg = await ConsultPhotoPreparation.jpeg(from: source) else {
                        preparationError = .invalidPhoto
                        return
                    }
                    preparationError = nil
                    await onJPEG(jpeg)
                } catch {
                    preparationError = .invalidPhoto
                }
            }
        }
    }
}

/// Keeps the uploaded inspiration photo on screen through the question flow,
/// with the per-question focus hint. Tapping opens the zoomable fullscreen
/// viewer — the parity of web's pinch/scroll/double-tap zoom.
private struct ConsultInspirationImagePanel: View {
    let model: ConsultFlowViewModel
    let questionKey: String
    let referenceNote: String
    let onTap: (URL) -> Void

    @State private var url: URL?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url {
                Button { onTap(url) } label: {
                    DownsampledRemoteImage(url: url) {
                        HStack(spacing: 10) {
                            ProgressView().tint(BrandColor.accent)
                            Text("Loading your inspiration photo…")
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Your inspiration photo — tap to zoom")
            } else {
                BrandSurface {
                    Text(failed
                         ? "Your inspiration photo could not be loaded right now."
                         : "Loading your inspiration photo…")
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                }
            }
            if let hint = consultInspirationFocusHints[questionKey] {
                Text("\(hint) Tap the photo to zoom.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
            }
            Text(referenceNote)
                .font(BrandFont.body(11))
                .foregroundStyle(BrandColor.textMuted)
        }
        .accessibilityIdentifier("consult-inspiration-image")
        .task(id: questionKey) {
            // Refetch per question so the short-lived signed URL is renewed
            // before it can expire mid-questionnaire (the model caches it and
            // only hits the network when it is close to stale).
            let fetched = await model.inspirationImageURL()
            url = fetched
            failed = fetched == nil
        }
    }
}

/// One server-served inspiration question: option chips, and for the final
/// free-text question the first text-entry surface in the consult flow —
/// a bounded note with a GOOD/BAD/BOTH sentiment, where leaving everything
/// blank means "nothing else".
private struct ConsultInspirationQuestionView: View {
    let question: ConsultInspirationQuestion
    let busy: Bool
    let onAnswer: ([String], String, ConsultInspirationSentiment?) -> Void

    @State private var selected: [String] = []
    @State private var text = ""
    @State private var sentiment: ConsultInspirationSentiment?

    private var trimmed: String {
        question.allowText ? text.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    private var traitBlocked: Bool {
        !trimmed.isEmpty && ConsultInspirationTextRules.containsUnsupportedTraitLanguage(trimmed)
    }

    private var needsSentiment: Bool { !trimmed.isEmpty && sentiment == nil }

    private var needsSelection: Bool {
        question.kind != .text && selected.count < question.minSelections
    }

    var body: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 10) {
                Text(question.label)
                    .font(BrandFont.body(16, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                if let helpText = question.helpText {
                    Text(helpText)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(question.options) { option in
                        optionChip(option)
                    }
                }
                if question.allowText {
                    noteEntry
                }
                Button {
                    onAnswer(selected, text, sentiment)
                } label: {
                    Text("Next")
                        .font(BrandFont.body(14, .semibold))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 11)
                        .foregroundStyle(BrandColor.onAccent)
                        .background(BrandColor.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(busy || needsSelection || needsSentiment || traitBlocked)
                if needsSentiment {
                    Text("Tell us whether that note is something you like, something to avoid, or a bit of both.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
        }
        .accessibilityIdentifier("consult-inspiration-question-\(question.key)")
    }

    private func optionChip(_ option: ConsultInspirationQuestionOption) -> some View {
        let active = selected.contains(option.value)
        return Button {
            selected = ConsultInspirationAnswering.toggle(
                option.value, in: selected, question: question
            )
            // "Nothing else" and a written note are mutually exclusive.
            if question.kind == .text {
                text = ""
                sentiment = nil
            }
        } label: {
            Text(option.label)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(active ? BrandColor.onAccent : BrandColor.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(active ? BrandColor.accent : BrandColor.bgSurface)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var noteEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "Anything else, in your own words — or leave this blank",
                text: $text,
                axis: .vertical
            )
            .lineLimit(2...5)
            .font(BrandFont.body(14))
            .foregroundStyle(BrandColor.textPrimary)
            .padding(12)
            .background(BrandColor.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(busy)
            .accessibilityIdentifier("consult-inspiration-note")
            .onChange(of: text) { _, newValue in
                if newValue.count > ConsultInspirationTextRules.maxCharacters {
                    text = String(newValue.prefix(ConsultInspirationTextRules.maxCharacters))
                }
                if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    selected.removeAll { $0 == "nothing-else" }
                }
            }
            if !trimmed.isEmpty {
                HStack(spacing: 8) {
                    Text("This is…")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                    ForEach(ConsultInspirationSentiment.allCases, id: \.rawValue) { option in
                        Button {
                            sentiment = option
                        } label: {
                            Text(option.label)
                                .font(BrandFont.body(12, .semibold))
                                .foregroundStyle(sentiment == option
                                                 ? BrandColor.onAccent : BrandColor.textPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(sentiment == option
                                            ? BrandColor.accent : BrandColor.bgSurface)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                }
            }
            if traitBlocked {
                Text("Keep this note about the look itself — words about the face, eyes, skin, or body can’t be included here. Your photos already show your professional everything they need.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textPrimary)
                    .padding(10)
                    .background(BrandColor.amber.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

enum ConsultPhotoPreparation {
    static func jpeg(from data: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                let maximumDimension: CGFloat = 1_568
                let qualities: [CGFloat] = [0.9, 0.78, 0.65, 0.52]
                guard let image = UIImage(data: data) else { return nil }
                let scale = min(1, maximumDimension / max(image.size.width, image.size.height))
                let size = CGSize(width: max(1, image.size.width * scale),
                                  height: max(1, image.size.height * scale))
                let rendered = UIGraphicsImageRenderer(size: size).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                for quality in qualities {
                    if let jpeg = rendered.jpegData(compressionQuality: quality),
                       jpeg.count <= ConsultService.maximumPhotoBytes {
                        return jpeg
                    }
                }
                return nil
            }
        }.value
    }
}
