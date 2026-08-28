import Testing

@testable import Tovis

/// The pro client chart's tab set is a 1:1 port of the web chart's `CHART_TABS`
/// (tovis-app `lib/clients/chartTabs.ts`), and this is exactly the kind of list
/// that drifts: web merged its "History" and "Photos" tabs into one "Visits"
/// view — each visit's before/after frames now render on that visit's own card —
/// and native had to make the same move or a pro would see two different charts
/// depending on which device they picked up.
///
/// Pinned here, with the LABELS as well as the order, because the labels are the
/// parity: a tab called "History" on one surface and "Visits" on the other is a
/// drift no type checks.
@Suite struct ProClientChartTabsTests {
    /// Order and identity, matching web `CHART_TABS` exactly.
    @Test func matchesTheWebTabOrder() {
        #expect(ProClientChartView.Tab.allCases.map(\.rawValue) == [
            "Notes",
            "Allergies",
            "Visits",
            "Products",
            "Reviews",
            "Pro feedback",
            "Technical record",
        ])
    }

    /// Named on its own so a failure says the chart regrew a second grouping of
    /// the same visits, rather than just "the array changed". A photo tab
    /// re-added here would render either an empty screen (nothing feeds it any
    /// more) or a second copy of frames the visit cards already show.
    @Test func carriesNoSeparatePhotosTab() {
        #expect(ProClientChartView.Tab.allCases.allSatisfy {
            $0.rawValue.lowercased() != "photos"
        })
        #expect(ProClientChartView.Tab.allCases.count == 7)
    }

    /// The merged view keeps `history`'s place in the order — third, where the
    /// old History tab sat — so a pro's muscle memory still lands on the visits.
    @Test func visitsSitsWhereHistoryDid() {
        #expect(ProClientChartView.Tab.allCases[2] == .visits)
    }

    /// `id` is what `ForEach` keys the tab bar on; two tabs sharing one would
    /// drop a tab from the bar without any build error.
    @Test func everyTabHasADistinctId() {
        let ids = ProClientChartView.Tab.allCases.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
