// Pro Finance & Tax — the native counterpart of the web `/pro/finance`
// (ProFinanceScreen). Backed by GET /api/v1/pro/finance, a superset of the
// Overview view-model. Four sub-tabs: Overview (finance summary + income
// breakdown + quarterly reminder + the retained performance stats), Expenses
// (add/edit/delete), Write-Offs (IRS-risk guide), and Export. All values arrive
// pre-formatted, so this stays presentation-only (aside from expense CRUD).
import SwiftUI
import TovisKit

struct ProFinanceView: View {
    @Environment(SessionModel.self) private var session

    enum Sub: String, CaseIterable, Identifiable {
        case overview, expenses, writeOffs, export
        var id: String { rawValue }
        var label: String {
            switch self {
            case .overview:  return "Overview"
            case .expenses:  return "Expenses"
            case .writeOffs: return "Write-Offs"
            case .export:    return "Export"
            }
        }
    }

    private enum Phase {
        case loading
        case loaded(ProFinanceResponse)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var month: String?
    @State private var sub: Sub = .overview
    @State private var showExpenseForm = false
    @State private var editing: ProFinanceResponse.ExpenseItem?
    @State private var pendingDelete: ProFinanceResponse.ExpenseItem?
    @State private var showDeleteConfirm = false

    private var loaded: ProFinanceResponse? {
        if case let .loaded(data) = phase { return data }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 50)
                case let .failed(message):
                    errorState(message)
                case let .loaded(data):
                    monthNav(data.months)
                    subTabBar
                    switch sub {
                    case .overview:  overviewPanel(data)
                    case .expenses:  expensesPanel(data)
                    case .writeOffs: writeOffsPanel(data)
                    case .export:    exportPanel(data)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 120)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .refreshable { await load() }
        .task { if case .loading = phase { await load() } }
        .onChange(of: session.refreshTick) { Task { await load() } }
        .sheet(isPresented: $showExpenseForm) {
            ProExpenseFormView(
                categories: loaded?.finance.categories ?? [],
                editing: editing,
                timeZone: loaded?.activeMonth.timeZone ?? "America/Los_Angeles",
                onSaved: { Task { await load() } }
            )
        }
        .confirmationDialog(
            "Delete this expense?",
            isPresented: $showDeleteConfirm,
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) {
                Task { await deleteExpense(item) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Month nav + sub-tabs

    private func monthNav(_ months: [ProOverviewResponse.MonthNav]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(months) { m in
                    Button {
                        month = m.key
                        Task { await load() }
                    } label: {
                        Text(m.label)
                            .font(BrandFont.body(12, .bold))
                            .foregroundStyle(m.active ? BrandColor.onAccent : BrandColor.textPrimary)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 14)
                            .background(m.active ? BrandColor.accent : BrandColor.bgSecondary)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(BrandColor.textMuted.opacity(m.active ? 0 : 0.18), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var subTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(Sub.allCases) { tab in
                    let active = tab == sub
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) { sub = tab }
                    } label: {
                        VStack(spacing: 8) {
                            Text(tab.label)
                                .font(BrandFont.body(13, .heavy))
                                .foregroundStyle(active ? BrandColor.textPrimary : BrandColor.textMuted)
                            Rectangle()
                                .fill(active ? BrandColor.accent : Color.clear)
                                .frame(height: 2)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 2)
        }
    }

    // MARK: Overview sub-tab

    @ViewBuilder
    private func overviewPanel(_ data: ProFinanceResponse) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ForEach(data.finance.summaryCards) { card in
                BrandSurface(tint: BrandColor.bgSecondary) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(card.label)
                            .font(BrandFont.mono(9))
                            .tracking(1.2)
                            .foregroundStyle(BrandColor.textMuted)
                        Text(card.value)
                            .font(BrandFont.display(26, .bold))
                            .foregroundStyle(Self.toneColor(card.tone))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(card.sub)
                            .font(BrandFont.body(11))
                            .foregroundStyle(BrandColor.textMuted)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }

        BrandSection(title: "Income breakdown") {
            VStack(spacing: 0) {
                ForEach(Array(data.finance.incomeBreakdown.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Rectangle().fill(BrandColor.textMuted.opacity(0.08)).frame(height: 1)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label)
                                .font(BrandFont.body(15, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                            Text(item.source)
                                .font(BrandFont.body(11))
                                .foregroundStyle(BrandColor.textMuted)
                        }
                        Spacer()
                        Text(item.value)
                            .font(BrandFont.body(15, .semibold))
                            .foregroundStyle(BrandColor.emerald)
                    }
                    .padding(.vertical, 12)
                }
            }
        }

        quarterlyReminder(data.finance.quarterlyReminder)

        ProPerformanceSectionsView(
            revenue: data.revenue,
            primaryStats: data.primaryStats,
            secondaryStats: data.secondaryStats,
            topServices: data.topServices
        )
    }

    private func quarterlyReminder(_ reminder: ProFinanceResponse.QuarterlyReminder) -> some View {
        BrandSurface(tint: BrandColor.gold.opacity(0.10)) {
            VStack(alignment: .leading, spacing: 8) {
                Text("QUARTERLY TAX REMINDER")
                    .font(BrandFont.mono(10))
                    .tracking(1.2)
                    .foregroundStyle(BrandColor.gold)
                (
                    Text("Next estimated tax payment due ")
                        + Text(reminder.dueDateLabel).bold().foregroundColor(BrandColor.textPrimary)
                        + Text(". \(reminder.body)")
                )
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Expenses sub-tab

    @ViewBuilder
    private func expensesPanel(_ data: ProFinanceResponse) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("TOTAL TRACKED")
                    .font(BrandFont.mono(10))
                    .tracking(1.2)
                    .foregroundStyle(BrandColor.textMuted)
                Text(data.finance.expenseTotalLabel)
                    .font(BrandFont.display(30, .bold))
                    .foregroundStyle(BrandColor.ember)
            }
            Spacer()
            Button {
                editing = nil
                showExpenseForm = true
            } label: {
                Text("+ Add")
                    .font(BrandFont.body(13, .bold))
                    .foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 18)
                    .background(BrandColor.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }

        if data.finance.expenses.isEmpty {
            BrandSurface(tint: BrandColor.bgSecondary) {
                Text("No expenses tracked for this month yet. Add your first one to start building your write-offs.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 10) {
                ForEach(data.finance.expenses) { expense in
                    expenseRow(expense)
                }
            }
        }

        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(spacing: 8) {
                Text("Import from CosmoProf or Salon Centric")
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)
                Text("Connect your account to auto-import order history as expenses. Coming soon.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func expenseRow(_ expense: ProFinanceResponse.ExpenseItem) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(expense.label)
                        .font(BrandFont.body(15, .bold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(expense.categoryLabel)
                            .font(BrandFont.body(12, .semibold))
                            .foregroundStyle(Self.riskColor(expense.categoryRisk))
                        Text("·").foregroundStyle(BrandColor.textMuted)
                        Text(expense.dateLabel)
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                }
                Spacer()
                Text(expense.amountLabel)
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.ember)
                Menu {
                    Button("Edit") {
                        editing = expense
                        showExpenseForm = true
                    }
                    Button("Delete", role: .destructive) {
                        pendingDelete = expense
                        showDeleteConfirm = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(BrandColor.textMuted)
                        .frame(width: 30, height: 30)
                }
            }
        }
    }

    // MARK: Write-Offs sub-tab

    @ViewBuilder
    private func writeOffsPanel(_ data: ProFinanceResponse) -> some View {
        Text("Every category below is color-coded by IRS risk level. Tap any one to see what qualifies and what documentation to keep.")
            .font(BrandFont.body(14))
            .foregroundStyle(BrandColor.textSecondary)

        HStack(spacing: 16) {
            legendItem("green", "Clear")
            legendItem("yellow", "Conditional")
            legendItem("red", "Risky")
        }

        VStack(spacing: 10) {
            ForEach(data.finance.categories) { category in
                writeOffRow(category)
            }
        }

        BrandSurface(tint: BrandColor.gold.opacity(0.08)) {
            Text("This helps you track and organize — but we’re not a CPA. Tax laws change. Always verify deductions with a tax professional before filing, especially for home office, appearance, and meals.")
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func legendItem(_ risk: String, _ label: String) -> some View {
        HStack(spacing: 7) {
            Circle().fill(Self.riskColor(risk)).frame(width: 9, height: 9)
            Text(label)
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(Self.riskColor(risk))
        }
    }

    private func writeOffRow(_ category: ProFinanceResponse.CategoryInfo) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(category.tooltip)
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
                if !category.examples.isEmpty {
                    Text("Examples: \(category.examples.joined(separator: ", "))")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            HStack(spacing: 10) {
                Circle().fill(Self.riskColor(category.risk)).frame(width: 9, height: 9)
                Text(category.label)
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Spacer()
                Text(category.riskLabel)
                    .font(BrandFont.body(11, .semibold))
                    .foregroundStyle(Self.riskColor(category.risk))
            }
        }
        .tint(BrandColor.textMuted)
        .padding(14)
        .background(BrandColor.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: Export sub-tab

    @ViewBuilder
    private func exportPanel(_ data: ProFinanceResponse) -> some View {
        Text("Export your income and expense data for your accountant or to fill out Schedule C yourself.")
            .font(BrandFont.body(14))
            .foregroundStyle(BrandColor.textSecondary)

        exportRow("Monthly Summary", "\(data.activeMonth.label) — income + expenses")
        exportRow("Year-to-Date Summary", String(data.finance.taxYear))
        exportRow("Full Year Export", "\(data.finance.taxYear) — all months")
        exportRow("Schedule C Ready", "Formatted for your CPA or tax software")

        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CSV & SCHEDULE-C EXPORT")
                    .font(BrandFont.mono(10))
                    .tracking(1.2)
                    .foregroundStyle(BrandColor.textMuted)
                Text("Download your CSV and Schedule-C exports from the Tovis web dashboard. In-app export is coming soon.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func exportRow(_ title: String, _ sub: String) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(sub)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                }
                Spacer()
            }
        }
    }

    // MARK: Shared

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again")
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    static func toneColor(_ tone: String) -> Color {
        switch tone {
        case "positive": return BrandColor.emerald
        case "negative": return BrandColor.ember
        case "warn":     return BrandColor.gold
        default:         return BrandColor.textPrimary
        }
    }

    static func riskColor(_ risk: String) -> Color {
        switch risk {
        case "green":  return BrandColor.emerald
        case "yellow": return BrandColor.amber
        case "red":    return BrandColor.ember
        default:       return BrandColor.textMuted
        }
    }

    private func load() async {
        do {
            let data = try await session.client.proFinance.finance(month: month)
            phase = .loaded(data)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your finance summary.")
        }
    }

    private func deleteExpense(_ expense: ProFinanceResponse.ExpenseItem) async {
        do {
            try await session.client.proFinance.deleteExpense(id: expense.id)
            await load()
        } catch {
            // Non-fatal; a reload will reflect the true state.
        }
    }
}
