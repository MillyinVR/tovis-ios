import SwiftUI
import TovisKit

/// The whole plan — the device's twin of the web results page
/// (`/client/consult/[id]/results`).
///
/// 🔴 Why it exists: every section below was already DECODED on the device and
/// rendered nowhere. The thread's plan card carries a summary — the look plan
/// or the top three directions, the suitability read, and a disclosure with the
/// feature profile — and that is where it should stay, because the thread is a
/// chat and a chat message is not a report. Everything else the analysis paid
/// for (the hair observations and their confidences, what she said in her own
/// words, the safety section, what may be achievable, why each direction was
/// recommended) had no home at all. `ConsultThreadCopy.planSeeAll` has been
/// shipping as a dead string since P5a; this is its destination.
///
/// 🔴 Section ORDER is a contract, not incidental source order —
/// `ConsultResultPresentation.sections` states it, and the client's own words
/// deliberately come before anything a model observed. The order is asserted in
/// `ConsultResultsRenderTests` rather than trusted to stay right.
struct ConsultResultsView: View {
    let results: ConsultClientResults
    let teaserTapped: Bool
    let busy: Bool
    /// Nil where the teaser cannot be recorded (a preview or a render test).
    /// The card still draws — it is a statement, not only a button.
    let onTapMeCard: (() -> Void)?

    var body: some View {
        ScrollView {
            ConsultResultsContent(
                results: results, teaserTapped: teaserTapped,
                busy: busy, onTapMeCard: onTapMeCard
            )
        }
        .background(BrandColor.bgPrimary)
        .navigationTitle(ConsultThreadCopy.planSeeAll)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The screen's body, outside its `ScrollView`.
///
/// 🔴 Split out because `ImageRenderer` draws a `ScrollView` as its BACKGROUND
/// AND NOTHING ELSE — the first render of this screen came back 780×5200 pixels
/// of exactly one colour, and the test passed, because it asserted the width.
/// A screen is not renderable; its content is. Every other render test in this
/// repo already renders a leaf for the same reason.
struct ConsultResultsContent: View {
    let results: ConsultClientResults
    let teaserTapped: Bool
    let busy: Bool
    let onTapMeCard: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            ForEach(ConsultResultPresentation.sections, id: \.self) { section in
                self.section(section)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            para(ConsultResultsCopy.eyebrow, size: 11, weight: .bold,
                 color: BrandColor.textMuted, upper: true, kerning: 1)
            para(ConsultResultsCopy.title, size: 22, weight: .bold, color: BrandColor.textPrimary)
            para(ConsultResultsCopy.intro, size: 14, color: BrandColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func section(_ section: ConsultResultSection) -> some View {
        switch section {
        case .clientWords: clientWords
        case .aiObservations: observations
        case .featureProfile: profile
        case .styleDirections: styleDirections
        case .safety: safety
        case .achievability: achievability
        case .directions: directions
        case .lockedMeCard: meCard
        }
    }

    // MARK: - Sections

    /// Her own answers, FIRST — before anything a model observed. That order is
    /// the point: this is a record of what she asked for, not a reading of her.
    private var clientWords: some View {
        card(ConsultResultsCopy.clientWordsTitle) {
            ForEach(results.clientIntake) { item in
                VStack(alignment: .leading, spacing: 2) {
                    para(item.question, size: 12, weight: .semibold, color: BrandColor.textMuted)
                    para(item.answer, size: 14, weight: .semibold, color: BrandColor.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var observations: some View {
        let o = results.aiObservations
        return card(ConsultResultsCopy.aiObservationsTitle, body: ConsultResultsCopy.aiObservationsBody) {
            observation(ConsultResultsCopy.baseLevelLabel, ConsultResultsCopy.hairLevel(o.baseLevel.value), o.baseLevel.confidence)
            observation(ConsultResultsCopy.lightestLevelLabel, ConsultResultsCopy.hairLevel(o.lightestLevel.value), o.lightestLevel.confidence)
            observation(ConsultResultsCopy.toneLabel, ConsultClientProfileCopy.value(field: "currentTone", value: o.currentTone.value), o.currentTone.confidence)
            observation(ConsultResultsCopy.conditionLabel, ConsultClientProfileCopy.value(field: "visibleCondition", value: o.visibleCondition.value), o.visibleCondition.confidence)
            observation(ConsultResultsCopy.densityLabel, ConsultClientProfileCopy.value(field: "density", value: o.density.value), o.density.confidence)
            observation(ConsultResultsCopy.textureLabel, ConsultClientProfileCopy.value(field: "texture", value: o.texture.value), o.texture.confidence)
        }
    }

    /// 🔴 Reuses `clientEntries` rather than listing the twelve fields again.
    /// The thread's disclosure reads the same property, so the two can never
    /// fall out of order with each other, and a field added to the profile
    /// appears in both without being typed anywhere twice.
    private var profile: some View {
        card(ConsultResultsCopy.profileTitle, body: ConsultResultsCopy.profileBody) {
            ForEach(results.profile.clientEntries, id: \.label) { entry in
                observation(entry.label, entry.value, entry.confidence)
            }
        }
    }

    private var styleDirections: some View {
        VStack(alignment: .leading, spacing: 10) {
            para(ConsultResultsCopy.styleDirectionsTitle, size: 17, weight: .bold,
                 color: BrandColor.textPrimary)
            para(ConsultResultsCopy.styleDirectionsBody, size: 13, color: BrandColor.textSecondary)
            ForEach(results.styleDirections) { direction in
                surface {
                    para(direction.domainLabel, size: 10, weight: .bold,
                         color: BrandColor.accent, upper: true, kerning: 1.2)
                    para(direction.title, size: 15, weight: .bold, color: BrandColor.textPrimary)
                    para(direction.direction, size: 14, color: BrandColor.textSecondary)
                    para("\(ConsultResultsCopy.whyItFlattersLabel): \(direction.whyItFlatters)",
                         size: 14, color: BrandColor.textPrimary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 🔴 ALWAYS drawn, including empty. An empty safety section is a
    /// statement — "nothing specific was found, and your pro still has to
    /// check" — and hiding it would read as a clean bill of health nobody gave.
    private var safety: some View {
        VStack(alignment: .leading, spacing: 8) {
            para(ConsultResultsCopy.safetyTitle, size: 15, weight: .bold,
                 color: BrandColor.textPrimary)
            if results.safetyFlags.isEmpty {
                para(ConsultResultsCopy.safetyEmpty, size: 14, color: BrandColor.textSecondary)
            } else {
                ForEach(results.safetyFlags) { flag in
                    para("\(ConsultResultPresentation.codeLabel(flag.code)): \(flag.summary) \(ConsultResultsCopy.safetyItemSuffix)",
                         size: 14, color: BrandColor.textPrimary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(BrandColor.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("consult-results-safety")
    }

    private var achievability: some View {
        card(ConsultResultsCopy.achievabilityTitle) {
            para(ConsultResultsCopy.achievabilityLabel(results.achievabilityDirection.assessment),
                 size: 14, weight: .bold, color: BrandColor.textPrimary)
            para(results.achievabilityDirection.context, size: 14, color: BrandColor.textSecondary)
            para(results.achievabilityDirection.direction, size: 14, weight: .semibold,
                 color: BrandColor.textPrimary)
        }
    }

    /// The FULL list with each one's reason — the thread card shows the first
    /// three titles and nothing else.
    private var directions: some View {
        VStack(alignment: .leading, spacing: 10) {
            para(results.recommendationDirections.count == 1
                 ? ConsultResultsCopy.singleRecommendationTitle
                 : ConsultResultsCopy.recommendationsTitle,
                 size: 17, weight: .bold, color: BrandColor.textPrimary)
            ForEach(Array(results.recommendationDirections.enumerated()), id: \.offset) { index, direction in
                surface {
                    para("\(index + 1) / \(results.recommendationDirections.count)",
                         size: 10, weight: .bold, color: BrandColor.accent, kerning: 1.2)
                    para(direction.title, size: 15, weight: .bold, color: BrandColor.textPrimary)
                    para(direction.why, size: 14, color: BrandColor.textSecondary)
                    para("\(ConsultResultsCopy.recommendationDiscussionPrefix) \(direction.title).",
                         size: 14, weight: .semibold, color: BrandColor.textPrimary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 🔴 The tap records INTEREST and unlocks nothing — the copy says so, and
    /// the card stays locked afterwards. A teaser that appeared to unlock
    /// something would be the "manufactures confidence" failure in UI form.
    private var meCard: some View {
        card(ConsultResultsCopy.meCardTitle, eyebrow: ConsultResultsCopy.meCardEyebrow) {
            para(ConsultResultsCopy.meCardBody, size: 13, color: BrandColor.textSecondary)
            if teaserTapped {
                para(ConsultResultsCopy.meCardTappedLabel, size: 13, weight: .semibold,
                     color: BrandColor.textMuted)
            } else if let onTapMeCard {
                Button(ConsultResultsCopy.meCardTapLabel, action: onTapMeCard)
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.accent)
                    .disabled(busy)
            }
        }
    }

    // MARK: - Pieces

    private func observation(
        _ label: String, _ value: String, _ confidence: ConsultConfidence
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            para(label, size: 11, weight: .bold, color: BrandColor.textMuted,
                 upper: true, kerning: 0.6)
            // 🔴 The confidence RANGE travels with every reading. A value shown
            // without it reads as a fact, and none of these are facts — they
            // are what a photograph suggested.
            para("\(value) · \(ConsultResultPresentation.confidence(confidence))",
                 size: 13, weight: .semibold, color: BrandColor.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
        )
    }

    private func card<Content: View>(
        _ title: String, eyebrow: String? = nil, body: String? = nil,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        surface {
            if let eyebrow {
                para(eyebrow, size: 10, weight: .bold, color: BrandColor.textMuted,
                     upper: true, kerning: 1.2)
            }
            para(title, size: 15, weight: .bold, color: BrandColor.textPrimary)
            if let body {
                para(body, size: 13, color: BrandColor.textSecondary)
            }
            content()
        }
    }

    /// One sentence, wrapped.
    ///
    /// 🔴 `.fixedSize(horizontal: false, vertical: true)` is the load-bearing
    /// part. In a `VStack` the children negotiate width, and a long `Text`
    /// beside several others loses that negotiation and TRUNCATES rather than
    /// wrapping — the first render of this screen came back with its own title
    /// reading "Directions to discuss with your pr…" and the observations
    /// heading cut at "your prof…". Every sentence here is a paragraph, so
    /// every one goes through this.
    private func para(
        _ text: String, size: CGFloat, weight: Font.Weight = .regular,
        color: Color, upper: Bool = false, kerning: CGFloat = 0
    ) -> some View {
        Text(text)
            .font(BrandFont.body(size, weight))
            .textCase(upper ? .uppercase : nil)
            .kerning(kerning)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func surface<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(BrandColor.bgSurface, in: RoundedRectangle(cornerRadius: 16))
    }
}
