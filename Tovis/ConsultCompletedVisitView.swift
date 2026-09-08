import SwiftUI
import TovisKit

struct ConsultCompletedVisitView: View {
    let visit: ConsultLookCompletedVisit
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your completed visit").font(BrandFont.body(16, .semibold))
            Text("Final service subtotal: \(Wire.money(visit.finalServiceSubtotal) ?? "Not recorded")")
            Text("Recorded service time: \(visit.observedServiceMinutes.map { "\($0) min" } ?? "Not recorded")")
            if let care = visit.aftercare {
                if let notes = care.notes { Text(notes) }
                ForEach(Array(care.sections.enumerated()), id: \.offset) { _, section in
                    Text(section.label).fontWeight(.semibold)
                    Text(section.body)
                }
                ForEach(Array(care.products.enumerated()), id: \.offset) { _, product in
                    Text(product.name).fontWeight(.semibold)
                    if let note = product.note { Text(note) }
                }
            }
        }.font(BrandFont.body(13)).foregroundStyle(BrandColor.textPrimary)
    }
}
