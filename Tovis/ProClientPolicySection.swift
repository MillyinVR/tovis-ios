import SwiftUI
import TovisKit

// K17-B — K16's per-client booking requirements, on device.
//
// Four switches a pro sets for ONE client: take a deposit, take payment up
// front, require a saved card, stop them booking themselves. They WIDEN the
// pro's account-wide terms for this person and never narrow them.
//
// It lives inside the technical-record tab because that tab is the one gated on
// `isClientTechnicalRecordEnabled`, and the policy route 404s on the very same
// flag. Putting the control anywhere else would mean re-deriving that gate on a
// second surface — and a control whose kill switch reaches only the write route
// is the failure this whole family of cards keeps finding
// ([[kill-switch-must-reach-the-control]]).

/// The four requirements, as ONE vocabulary: the form's wording, the summary's
/// wording, and the rule for reading each one off a stored policy.
///
/// File-scope and `CaseIterable` on purpose — inline rows in a form are
/// untestable, which is exactly how K14's dead proof-method survived to K17-A.
/// A fifth requirement added to K16 must appear here once, not in three places.
enum ProClientRequirement: String, CaseIterable, Identifiable {
    case deposit
    case prepay
    case cardOnFile
    case noOnlineBooking

    var id: String { rawValue }

    /// The switch's own label, matching web's form word for word.
    var title: String {
        switch self {
        case .deposit: return "Require a deposit"
        case .prepay: return "Require prepayment"
        case .cardOnFile: return "Require a card on file"
        case .noOnlineBooking: return "No online booking"
        }
    }

    /// What the switch does, in the pro's terms. Web's hints verbatim.
    var hint: String {
        switch self {
        case .deposit:
            return "Takes your usual deposit from this client on every booking, whatever your account-wide deposit setting says."
        case .prepay:
            return "This client pays up front."
        case .cardOnFile:
            return "This client saves a card before they can finish booking. Nothing is charged when they save it."
        case .noOnlineBooking:
            return "This client can’t book a new appointment themselves — you book them. They can still reschedule an appointment they already have."
        }
    }

    /// Is this requirement on, in a stored policy?
    func isSet(in policy: ProClientPolicy.Display) -> Bool {
        switch self {
        case .deposit: return policy.requireDeposit
        case .prepay: return policy.prepayScope != nil
        case .cardOnFile: return policy.requireCardOnFile
        case .noOnlineBooking: return policy.blockSelfServeBooking
        }
    }

    /// The short chip the collapsed summary prints — web's roster vocabulary
    /// (`summarizeProClientPolicy`), which is deliberately terser than the form's:
    /// the form asks the pro to do something, the chip states a fact.
    func summaryLabel(in policy: ProClientPolicy.Display) -> String {
        switch self {
        case .deposit: return "Deposit"
        case .prepay:
            switch policy.prepayScope {
            case .serviceOnly: return "Prepay (service)"
            case .entireBooking, .none: return "Prepay (whole booking)"
            }
        case .cardOnFile: return "Card on file"
        case .noOnlineBooking: return "No online booking"
        }
    }
}

/// The policy a SAVE sends, given what the form holds.
///
/// 🔴 `cardOnFileRailEnabled` is a parameter here and is deliberately NOT used to
/// mask `requireCardOnFile`. That masking is the tempting bug: with the rail dark
/// the switch is disabled but still rendered ON, so folding the rail in would
/// silently clear a requirement the pro set, the first time they opened this
/// sheet to change something else. Sending it as stored makes the route 409 in
/// its own words instead, and nothing is lost.
///
/// It lives at file scope, not inside the view, precisely so a test can pin
/// that — a rule buried in a private computed property is a rule nothing checks.
func proClientPolicyDraft(
    requireDeposit: Bool,
    prepayScope: ProClientPolicy.PrepayScope?,
    requireCardOnFile: Bool,
    blockSelfServeBooking: Bool,
    cardOnFileRailEnabled: Bool
) -> ProClientPolicy.Display {
    _ = cardOnFileRailEnabled
    return ProClientPolicy.Display(
        requireDeposit: requireDeposit,
        prepayScope: prepayScope,
        requireCardOnFile: requireCardOnFile,
        blockSelfServeBooking: blockSelfServeBooking
    )
}

/// The requirements a policy has set, in one fixed order, ready to print.
func proClientRequirementSummary(_ policy: ProClientPolicy.Display) -> [(id: String, label: String)] {
    ProClientRequirement.allCases
        .filter { $0.isSet(in: policy) }
        .map { (id: $0.rawValue, label: $0.summaryLabel(in: policy)) }
}

struct ProClientPolicySection: View {
    @Environment(SessionModel.self) private var session

    let clientId: String

    private enum Phase {
        case loading
        case loaded(ProClientPolicyResponse)
        /// The route 404'd — the flag is off for this pro. Show nothing at all.
        case unavailable
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var editing = false

    var body: some View {
        Group {
            switch phase {
            case .loading:
                BrandSection(title: "Booking requirements") {
                    ProgressView().tint(BrandColor.textMuted)
                }
            case .unavailable:
                EmptyView()
            case let .failed(message):
                BrandSection(title: "Booking requirements") {
                    // A retry, because this section owns its own load: the
                    // technical record around it can succeed while this fails,
                    // and re-rendering the parent does NOT re-run this `.task`
                    // (the view keeps its identity, so `phase` survives). Without
                    // a button the pro has to leave the chart entirely to try
                    // again — for a CONTROL, that is a dead end, not a hiccup.
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message).font(BrandFont.body(12)).foregroundStyle(BrandColor.ember)
                        Button {
                            phase = .loading
                            Task { await load() }
                        } label: {
                            Text("Try again")
                                .font(BrandFont.body(13, .semibold))
                                .foregroundStyle(BrandColor.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            case let .loaded(response):
                loaded(response)
            }
        }
        .task { await load() }
        .sheet(isPresented: $editing) {
            if case let .loaded(response) = phase {
                ProClientPolicyEditSheet(
                    clientId: clientId,
                    initial: response.policy?.display ?? .none,
                    hasStoredPolicy: response.policy != nil,
                    cardOnFileRailEnabled: response.cardOnFileRailEnabled
                ) { updated in
                    phase = .loaded(updated)
                }
            }
        }
    }

    @ViewBuilder
    private func loaded(_ response: ProClientPolicyResponse) -> some View {
        BrandSection(title: "Booking requirements") {
            VStack(alignment: .leading, spacing: 10) {
                // 🔴 A stored policy this build could only read PARTIALLY. The save
                // is a whole-object PUT, so offering the form would clear whatever
                // failed to decode the moment the pro touched anything. Say so and
                // withhold the control; web is still reachable.
                if response.policy != nil, response.policy?.display == nil {
                    BrandSurface {
                        Text("This client has booking requirements set, but this version of the app can’t read all of them. Open the client on the web to change them.")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    let policy = response.policy?.display ?? .none
                    summary(policy, railEnabled: response.cardOnFileRailEnabled)
                    Button { editing = true } label: {
                        Text(policy.isEmpty ? "Set booking requirements" : "Edit booking requirements")
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(BrandColor.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func summary(_ policy: ProClientPolicy.Display, railEnabled: Bool) -> some View {
        if policy.isEmpty {
            Text("Nothing extra is required of this client — your usual terms apply.")
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textMuted)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                    Text("Booking requirements set").font(BrandFont.body(12, .semibold))
                }
                .foregroundStyle(BrandColor.amber)

                requirementChips(policy, railEnabled: railEnabled)

                Text("Private to you — never shown to the client or to other pros. The client sees only the requirement itself when they book, never that you set it.")
                    .font(BrandFont.body(11))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    /// The requirement chips, wrapping rather than truncating: on a phone this
    /// row can hold four, and a chip pushed off the edge is a requirement the pro
    /// cannot see (the K17-A tile lesson, in the one place here that can wrap).
    @ViewBuilder
    private func requirementChips(_ policy: ProClientPolicy.Display, railEnabled: Bool) -> some View {
        let chips = proClientRequirementSummary(policy).map { item -> (id: String, label: String, tint: Color) in
            // A card-on-file requirement stored while the rail is dark is SET but
            // not enforced. Saying only one of those two things is a lie either way.
            let inactive = item.id == ProClientRequirement.cardOnFile.rawValue && !railEnabled
            return (
                id: item.id,
                label: inactive ? "\(item.label) (not active)" : item.label,
                tint: inactive ? BrandColor.textMuted : BrandColor.amber
            )
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(chips, id: \.id) { BrandPill(text: $0.label, tint: $0.tint) }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(chips, id: \.id) { BrandPill(text: $0.label, tint: $0.tint) }
            }
        }
    }

    private func load() async {
        // Re-entrant: the sheet writes the fresh response straight back into
        // `phase`, and `.task` must not stomp it on a redraw.
        if case .loading = phase {} else { return }
        do {
            phase = .loaded(try await session.client.proClients.clientPolicy(clientId: clientId))
        } catch let error as APIError {
            // 404 = the founder flag is off for this pro. The whole surface stays
            // dark together — the technical tab it lives in is gated on the very
            // same flag.
            if case let .server(status, _, _) = error, status == 404 {
                phase = .unavailable
            } else {
                phase = .failed(error.userMessage)
            }
        } catch {
            phase = .failed("Couldn’t load booking requirements.")
        }
    }
}

// MARK: - The editor

struct ProClientPolicyEditSheet: View {
    let clientId: String
    let initial: ProClientPolicy.Display
    let hasStoredPolicy: Bool
    /// 🔴 The capability, straight off the wire. While this is false the write
    /// route 409s a card-on-file requirement, so the SWITCH is disabled — not
    /// merely allowed to fail.
    let cardOnFileRailEnabled: Bool
    let onSaved: (ProClientPolicyResponse) -> Void

    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var requireDeposit: Bool
    @State private var prepayOn: Bool
    @State private var prepayScope: ProClientPolicy.PrepayScope
    @State private var requireCardOnFile: Bool
    @State private var blockSelfServeBooking: Bool
    @State private var saving = false
    @State private var error: String?

    init(
        clientId: String,
        initial: ProClientPolicy.Display,
        hasStoredPolicy: Bool,
        cardOnFileRailEnabled: Bool,
        onSaved: @escaping (ProClientPolicyResponse) -> Void
    ) {
        self.clientId = clientId
        self.initial = initial
        self.hasStoredPolicy = hasStoredPolicy
        self.cardOnFileRailEnabled = cardOnFileRailEnabled
        self.onSaved = onSaved
        _requireDeposit = State(initialValue: initial.requireDeposit)
        _prepayOn = State(initialValue: initial.prepayScope != nil)
        // Web's default when a pro switches prepay ON: the wider scope.
        _prepayScope = State(initialValue: initial.prepayScope ?? .entireBooking)
        _requireCardOnFile = State(initialValue: initial.requireCardOnFile)
        _blockSelfServeBooking = State(initialValue: initial.blockSelfServeBooking)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    toggleRow(.deposit, isOn: $requireDeposit)
                    toggleRow(.prepay, isOn: $prepayOn)
                    if prepayOn { prepayScopePicker }
                    toggleRow(
                        .cardOnFile,
                        isOn: $requireCardOnFile,
                        enabled: cardOnFileRailEnabled,
                        hint: cardOnFileRailEnabled
                            ? nil
                            : "Saved cards aren’t available yet, so this can’t be required."
                    )
                    toggleRow(.noOnlineBooking, isOn: $blockSelfServeBooking)

                    if strandedCardRequirement {
                        Text("This client already has a saved-card requirement, but saved cards aren’t available right now — so this form can’t be saved until they are. Clearing all requirements still works.")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.amber)
                    }

                    Text("Private to you — never shown to the client or to other pros. The client sees only the requirement itself when they book, never that you set it.")
                        .font(BrandFont.body(11))
                        .foregroundStyle(BrandColor.textMuted)

                    if let error {
                        // The server's own sentence — a 409 names the setting that
                        // fixes it, which no message written here could.
                        Text(error)
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.ember)
                    }

                    if hasStoredPolicy {
                        Button(role: .destructive) { Task { await clear() } } label: {
                            Text("Clear all requirements").font(BrandFont.body(13, .semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(saving)
                    }
                }
                .padding(16)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Booking requirements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving)
                }
            }
        }
    }

    private var prepayScopePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What prepayment covers")
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(BrandColor.textSecondary)
            Picker("What prepayment covers", selection: $prepayScope) {
                Text("The whole booking, including add-ons").tag(ProClientPolicy.PrepayScope.entireBooking)
                Text("The main service only").tag(ProClientPolicy.PrepayScope.serviceOnly)
            }
            .pickerStyle(.menu)
            .tint(BrandColor.accent)
            .disabled(saving)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColor.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func toggleRow(
        _ requirement: ProClientRequirement,
        isOn: Binding<Bool>,
        enabled: Bool = true,
        hint: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(requirement.title)
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text(hint ?? requirement.hint)
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(BrandColor.accent)
                .disabled(saving || !enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColor.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(enabled ? 1 : 0.55)
    }

    private var draft: ProClientPolicy.Display {
        proClientPolicyDraft(
            requireDeposit: requireDeposit,
            prepayScope: prepayOn ? prepayScope : nil,
            requireCardOnFile: requireCardOnFile,
            blockSelfServeBooking: blockSelfServeBooking,
            cardOnFileRailEnabled: cardOnFileRailEnabled
        )
    }

    /// True when this client carries a stored card-on-file requirement the rail
    /// can no longer honour. Every save will 409 until the rail is back, so say
    /// it before the pro fills the form in rather than after.
    private var strandedCardRequirement: Bool {
        !cardOnFileRailEnabled && initial.requireCardOnFile
    }

    private func save() async {
        saving = true
        error = nil
        do {
            let response = try await session.client.proClients
                .updateClientPolicy(clientId: clientId, policy: draft)
            onSaved(response)
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t save. Try again."
        }
        saving = false
    }

    private func clear() async {
        saving = true
        error = nil
        do {
            let response = try await session.client.proClients.clearClientPolicy(clientId: clientId)
            onSaved(response)
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t clear. Try again."
        }
        saving = false
    }
}
