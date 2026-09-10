import SwiftUI
import TovisKit

struct ClientSuitabilityView: View {
    let suitability: ClientSuitability
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ConsultSuitabilityCopy.clientNote)
                .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
            SuitabilityTextSection(title: ConsultSuitabilityCopy.loved, items: suitability.whatYouLoved)
            if !suitability.tailoring.isEmpty {
                Text(ConsultSuitabilityCopy.tailoring).font(BrandFont.body(16, .semibold))
                ForEach(Array(suitability.tailoring.enumerated()), id: \.offset) { _, item in
                    Text(item.explanation)
                    if item.needsConfirmation {
                        Text(ConsultSuitabilityCopy.clientConfirmation)
                            .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                    }
                }
            }
            SuitabilityTextSection(title: ConsultSuitabilityCopy.confirmations, items: suitability.proConfirmations)
        }
        .font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary)
        .accessibilityIdentifier("consult-client-suitability")
    }
}

struct ProSuitabilityView: View {
    let suitability: ProSuitability
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ConsultSuitabilityCopy.proTitle).font(BrandFont.body(18, .semibold))
            SuitabilityTextSection(title: ConsultSuitabilityCopy.desiredChoices, items: suitability.whatYouLoved)
            if !suitability.tailoring.isEmpty {
                Text(ConsultSuitabilityCopy.professionalDirections).font(BrandFont.body(16, .semibold))
                ForEach(Array(suitability.tailoring.enumerated()), id: \.offset) { _, item in
                    Text(item.direction)
                    if item.needsConfirmation { Text(ConsultSuitabilityCopy.reviewRequired).font(BrandFont.body(12, .semibold)) }
                    SuitabilitySourcesView(sources: item.sources)
                }
            }
            if !suitability.proConfirmations.isEmpty {
                Text(ConsultSuitabilityCopy.reviewRequired).font(BrandFont.body(16, .semibold))
                ForEach(Array(suitability.proConfirmations.enumerated()), id: \.offset) { _, item in
                    Text(item.check)
                    SuitabilitySourcesView(sources: item.sources)
                }
            }
        }
        .font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary)
        .accessibilityIdentifier("consult-pro-suitability")
    }
}

private struct SuitabilityTextSection: View {
    let title: String
    let items: [String]
    var body: some View {
        if !items.isEmpty {
            Text(title).font(BrandFont.body(16, .semibold))
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in Text(item) }
        }
    }
}

private struct SuitabilitySourcesView: View {
    let sources: [SuitabilityEvidence]
    var body: some View {
        ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
            VStack(alignment: .leading, spacing: 4) {
                Text("\(ConsultSuitabilityCopy.provenance(source.provenance)) · \(source.label): \(source.value)")
                if source.provenance == "OBSERVED" {
                    Text(ConsultSuitabilityCopy.observationUncertainty)
                    if let confidence = source.confidence { Text(ConsultSuitabilityCopy.confidence(confidence)) }
                    ForEach(Array((source.evidence ?? []).enumerated()), id: \.offset) { _, detail in Text(detail) }
                }
            }
            .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
