// Where everything else went.
//
// The subtraction pass didn't delete the camera's controls — it stopped giving
// each one a permanent row over the live preview. Three drawers hold what used
// to be four rows and eight header parts, and each opens from the thing it
// belongs to:
//
//   • swipe the coach line up  → the seven dimensions (was: seven status pills)
//   • tap ⋯                    → the tools tray (was: eyedropper + lock + gear)
//   • tap the step chip        → the guide sheet   (was: the eight-part guide bar)
//
// A thing earns a permanent slot by being touched per-SHOT. Calibration, AE/AF
// lock, the ghost strength and the pack are set once per salon, per light, or
// per shoot — so they're one gesture away rather than always on screen.
import SwiftUI
import TovisKit

// MARK: - Drawer 1 — the seven dimensions

/// The pills, second layer. Pulling them up is a deliberate act ("why won't it
/// go green?"), which is the only moment seven simultaneous numbers help.
struct DimensionsDrawer: View {
    let headline: String
    let headlineTone: LaneTone
    let statuses: [CoachStatus]
    /// The active coaching voice — renders each row's message/goodPhrase and
    /// gates whether `why` shows (`CoachVoice.includesWhy(for:)`). Defaults
    /// to Calm Mentor so today's always-on `why` display is unchanged for
    /// any caller that doesn't pass one.
    var voice: CoachVoice = CalmMentorVoice()

    /// All seven, in the beauty-photography priority order the coach weights by.
    /// Pose is included here even though it stayed out of the old always-on row:
    /// a drawer the pro opened on purpose should answer the whole question.
    private static let order: [CoachCategory] =
        [.lighting, .color, .level, .composition, .sharpness, .background, .pose]

    private var ordered: [CoachStatus] {
        Self.order.compactMap { category in statuses.first { $0.category == category } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 11) {
                Circle().fill(headlineTone.color).frame(width: 9, height: 9)
                Text(headline)
                    .font(BrandFont.display(17, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
            }
            .accessibilityElement(children: .combine)

            VStack(spacing: 1) {
                ForEach(ordered) { status in
                    row(status)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("Live while open. Swipe down or shoot to dismiss.")
                .font(BrandFont.body(12.5))
                .foregroundStyle(BrandColor.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.height(560)])
        .presentationDragIndicator(.visible)
        .presentationBackground(BrandColor.bgSecondary)
        // The camera keeps running behind this one — it's a live read-out, and
        // the pro is looking at it precisely to watch a number change.
        .presentationBackgroundInteraction(.enabled(upThrough: .height(560)))
    }

    private func row(_ status: CoachStatus) -> some View {
        let tone = Self.tone(status)
        let text = renderedMessage(status)
        let shownWhy = self.shownWhy(status)
        let spoken = [text, shownWhy].compactMap { $0 }
        return HStack(alignment: .top, spacing: 12) {
            Circle().fill(tone.color).frame(width: 7, height: 7)
                .padding(.top, 5)
            Text(status.category.shortLabel)
                .font(BrandFont.mono(11))
                .tracking(0.8)
                .foregroundStyle(status.message == nil ? BrandColor.textMuted : BrandColor.textPrimary)
                .frame(width: 74, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .font(BrandFont.body(13.5))
                    .foregroundStyle(status.message == nil ? BrandColor.textMuted : BrandColor.textSecondary)
                // The drawer is the one surface the pro opened on purpose to
                // ask "why won't it go green?" — so it is where the coach stops
                // issuing imperatives and explains itself. A photographer says
                // WHY; a checklist just says what. Whether it rides along at
                // all is the voice's chattiness (minimal packs skip it).
                if let shownWhy {
                    Text(shownWhy)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(status.message == nil
                    ? BrandColor.textPrimary.opacity(0.045)
                    : tone.color.opacity(0.13))
        // The row's state is carried by colour — spell it out.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.category.spokenName)
        .accessibilityValue(spoken.isEmpty ? "good" : spoken.joined(separator: ". "))
    }

    /// The row's headline text in the active voice: the issue (tagged with
    /// `status.moment`) when there is one, else the passing phrase (tagged
    /// with the category's fixed `goodMoment`) — both fall back to today's
    /// canonical text when the voice has no override.
    private func renderedMessage(_ status: CoachStatus) -> String {
        if let message = status.message {
            return CoachVoiceRenderer.render(
                status.moment, fallback: message,
                ctx: status.phraseCtx ?? CoachPhraseContext(), voice: voice) ?? message
        }
        let fallback = Self.goodPhrase(status.category)
        return CoachVoiceRenderer.render(status.category.goodMoment, fallback: fallback, voice: voice) ?? fallback
    }

    /// `why` only when there's an issue AND the active voice's chattiness
    /// includes it for this moment (minimal packs skip it by default).
    private func shownWhy(_ status: CoachStatus) -> String? {
        guard let why = status.why, status.message != nil, let moment = status.moment,
              voice.includesWhy(for: moment) else { return nil }
        return why
    }

    /// Mirrors the pills' tint: good, minor issue, or fix-this-now.
    private static func tone(_ s: CoachStatus) -> LaneTone {
        guard s.message != nil else { return .accent }
        return s.score < 0.5 ? .alert : .warn
    }

    /// What a passing fundamental says. Deliberately plain: it's derived from
    /// the score being good, so it must not claim a measurement we didn't make.
    private static func goodPhrase(_ c: CoachCategory) -> String {
        switch c {
        case .lighting: return "Good light"
        case .color: return "Colour is true"
        case .level: return "Level"
        case .composition: return "Framed"
        case .sharpness: return "Sharp"
        case .background: return "Background is clean"
        case .pose: return "Pose reads"
        }
    }
}

// MARK: - Drawer 2 — the tools tray

/// Four header icons become one ⋯. Everything set once per salon, per light or
/// per session lives here; nothing set per-shot does.
struct CameraToolsDrawer: View {
    @Bindable var settings: CoachSettings
    let whiteBalanceCalibrated: Bool
    let cardCalibrated: Bool
    let aeAfLocked: Bool
    @Binding var onionEnabled: Bool
    @Binding var onionOpacity: Double
    /// Whether there's anything to ghost (a before, or a matched look).
    let ghostAvailable: Bool
    /// Which "before" the ghost is showing, when there's more than one to line
    /// up against. Nil when a matched look drives the ghost (there's only one).
    let referenceChoice: (index: Int, count: Int)?
    let onCycleReference: () -> Void
    let onCalibrate: () -> Void
    let onToggleAEAF: () -> Void
    let onOpenAllSettings: () -> Void
    /// Opens the practice library. Nil in a session shoot — practice shots and
    /// session photos are different custody, and mixing the two entry points
    /// here would suggest otherwise.
    var onOpenPracticeLibrary: (() -> Void)? = nil
    /// "Also save to Photos", practice only. Nil in a session shoot: a client's
    /// before/after is THEIR photo, and quietly copying it to the pro's camera
    /// roll is not a toggle to offer in passing.
    var saveToPhotos: Binding<Bool>? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Tools")
                .font(BrandFont.display(19, .semibold))
                .foregroundStyle(BrandColor.textPrimary)

            HStack(spacing: 10) {
                tile(icon: "eyedropper.halffull",
                     title: "White balance",
                     caption: cardCalibrated ? "CARD LOCKED"
                              : (whiteBalanceCalibrated ? "CALIBRATED" : "AUTO"),
                     active: whiteBalanceCalibrated || cardCalibrated) {
                    dismiss()
                    onCalibrate()
                }
                tile(icon: aeAfLocked ? "lock.fill" : "lock.open",
                     title: "AE/AF lock",
                     caption: aeAfLocked ? "LOCKED" : "OFF · HOLD",
                     active: aeAfLocked,
                     action: onToggleAEAF)
                tile(icon: "circle.lefthalf.filled",
                     title: "Ghost before",
                     caption: ghostAvailable
                        ? (onionEnabled ? "\(Int(onionOpacity * 100))%" : "OFF")
                        : "NONE",
                     active: ghostAvailable && onionEnabled) {
                    guard ghostAvailable else { return }
                    onionEnabled.toggle()
                }
                .disabled(!ghostAvailable)
            }

            if let saveToPhotos {
                Toggle(isOn: saveToPhotos) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also save to Photos")
                            .font(BrandFont.body(15, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text("Keeps a copy in your camera roll, originals untouched")
                            .font(BrandFont.mono(10))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                }
                .tint(BrandColor.accent)
                .padding(.horizontal, 14)
                .frame(minHeight: 56)
                .background(BrandColor.textPrimary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if let onOpenPracticeLibrary {
                Button {
                    dismiss()
                    onOpenPracticeLibrary()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Practice library")
                            .font(BrandFont.body(15, .semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(BrandColor.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .frame(maxWidth: .infinity)
                    .background(BrandColor.textPrimary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Every shot you've taken outside a session")
            }

            if ghostAvailable, onionEnabled {
                HStack(spacing: 14) {
                    Text("GHOST")
                        .font(BrandFont.mono(10)).tracking(0.8)
                        .foregroundStyle(BrandColor.textMuted)
                    Slider(value: $onionOpacity, in: 0.1...0.7)
                        .tint(BrandColor.accent)
                        .accessibilityLabel("Ghost overlay strength")

                    // Which "before" to line up against. The guide moves this
                    // automatically shot-by-shot; this is the manual override,
                    // and the only way to cycle at all when guides are off.
                    if let choice = referenceChoice, choice.count > 1 {
                        Button(action: onCycleReference) {
                            Text("\(min(choice.index, choice.count - 1) + 1)/\(choice.count)")
                                .font(BrandFont.mono(12))
                                .foregroundStyle(BrandColor.textPrimary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(BrandColor.textPrimary.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Reference photo \(min(choice.index, choice.count - 1) + 1) of \(choice.count)")
                        .accessibilityHint("Cycles to the next reference photo")
                    }
                }
            }

            VStack(spacing: 1) {
                toggleRow("Shoot for me when it’s good", isOn: $settings.autoCapture)
                toggleRow("Say the tip out loud", isOn: $settings.speak)
                toggleRow("Grid & level", isOn: Binding(
                    get: { settings.showGrid || settings.showLevel },
                    set: { settings.showGrid = $0; settings.showLevel = $0 }
                ))
                toggleRow("Crop-safe rails", isOn: $settings.showCropGuide)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button {
                dismiss()
                onOpenAllSettings()
            } label: {
                HStack {
                    Text("All coaching settings")
                        .font(BrandFont.body(14, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(BrandColor.textMuted)
                }
                .padding(.horizontal, 14).padding(.vertical, 13)
                .background(BrandColor.textPrimary.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Text("Everything here is also a gesture: tap to focus, hold to lock.")
                .font(BrandFont.body(12.5))
                .foregroundStyle(BrandColor.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.height(ghostAvailable && onionEnabled ? 560 : 510)])
        .presentationDragIndicator(.visible)
        .presentationBackground(BrandColor.bgSecondary)
    }

    private func tile(icon: String, title: String, caption: String,
                      active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(active ? BrandColor.accent : BrandColor.textPrimary)
                Text(title)
                    .font(BrandFont.body(12.5, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(caption)
                    .font(BrandFont.mono(9.5))
                    .foregroundStyle(active ? BrandColor.accent : BrandColor.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 14)
            .background(active ? BrandColor.accent.opacity(0.14)
                               : BrandColor.textPrimary.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(active ? BrandColor.accent.opacity(0.34)
                                         : BrandColor.textPrimary.opacity(0.10),
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(caption.lowercased())")
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label)
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textPrimary)
        }
        .tint(BrandColor.accent)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(BrandColor.textPrimary.opacity(0.045))
    }
}

// MARK: - Drawer 3 — the guide

/// The eight-part guide bar — dots, packs menu, counter, arrows, icon, title,
/// hint — is one chip plus this sheet. Trending packs live behind one word
/// instead of a permanent menu button, because a pack is chosen once per shoot.
struct ShotGuideDrawer: View {
    let guide: ShotGuide
    let currentStepID: String?
    let completedStepIDs: Set<String>
    /// What the shoot actually owes, in one line
    /// (`ProSessionPhotoRequirement.guideNote`). The shot list below it is a set
    /// of suggestions — the dots and checkmarks used to read as a checklist the
    /// pro had to clear before they were allowed to leave.
    let requirementNote: String
    let standardGuideName: String
    let trendingPacks: [ProShotPack]
    let activePackID: String?
    let matchLookActive: Bool
    /// Claude's direction lines for a matched look — the human-coaching extras
    /// (expression, head angle, hands, light) no evaluator can measure. They
    /// used to own a permanent card over the preview; a brief belongs with the
    /// shot list, so they live here.
    let aiSummary: String?
    let directionLines: [String]
    let directionIndex: Int
    let onSelectStep: (String) -> Void
    let onSelectPack: (ProShotPack?) -> Void
    let onMatchAPhoto: () -> Void
    let onAdvanceDirection: () -> Void
    /// The active coaching voice — renders the current step's hint
    /// (`.shotStepHint`). Defaults to Calm Mentor so any caller that doesn't
    /// pass one keeps seeing today's text unchanged.
    var voice: CoachVoice = CalmMentorVoice()

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(guide.name) · \(guide.steps.count) shot\(guide.steps.count == 1 ? "" : "s")")
                    .font(BrandFont.display(19, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Spacer()
                packsMenu
            }

            Text(requirementNote)
                .font(BrandFont.body(12.5))
                .foregroundStyle(BrandColor.textSecondary)

            if !directionLines.isEmpty { directionCard }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(guide.steps) { step in
                        stepRow(step)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            Text("Or swipe the preview sideways to move a shot without opening this.")
                .font(BrandFont.body(12.5))
                .foregroundStyle(BrandColor.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(BrandColor.bgSecondary)
    }

    /// Tap to step through the AI direction lines (each is spoken when voice
    /// tips are on) — the same interaction the old floating card had.
    private var directionCard: some View {
        let index = min(max(directionIndex, 0), directionLines.count - 1)
        return Button(action: onAdvanceDirection) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(BrandColor.amber)
                    Text(aiSummary ?? "AI direction")
                        .font(BrandFont.mono(10)).tracking(0.5)
                        .foregroundStyle(BrandColor.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(index + 1)/\(directionLines.count)")
                        .font(BrandFont.mono(10))
                        .foregroundStyle(BrandColor.textMuted)
                }
                Text(directionLines[index])
                    .font(BrandFont.body(13.5, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(BrandColor.amber.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(BrandColor.amber.opacity(0.30), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("AI direction, \(index + 1) of \(directionLines.count)")
        .accessibilityValue(directionLines[index])
        .accessibilityHint("Double-tap for the next direction")
    }

    private var packsMenu: some View {
        Menu {
            Button { onSelectPack(nil) } label: {
                if activePackID == nil, !matchLookActive {
                    Label(standardGuideName, systemImage: "checkmark")
                } else {
                    Text(standardGuideName)
                }
            }
            ForEach(trendingPacks) { pack in
                Button { onSelectPack(pack) } label: {
                    if activePackID == pack.id {
                        Label("\(pack.name) — \(pack.tagline)", systemImage: "checkmark")
                    } else {
                        Text("\(pack.name) — \(pack.tagline)")
                    }
                }
            }
            Divider()
            Button {
                dismiss()
                onMatchAPhoto()
            } label: {
                if matchLookActive {
                    Label("Match a photo…", systemImage: "checkmark")
                } else {
                    Label("Match a photo…", systemImage: "photo.on.rectangle.angled")
                }
            }
        } label: {
            Text("PACKS")
                .font(BrandFont.mono(10)).tracking(0.8)
                .foregroundStyle(BrandColor.accent)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(BrandColor.accent.opacity(0.34), lineWidth: 1)
                )
        }
        .accessibilityLabel("Shot packs")
    }

    /// The current step's how-to, in the active voice (`.shotStepHint`).
    private func renderedHint(_ step: ShotStep) -> String {
        CoachVoiceRenderer.render(
            .shotStepHint, fallback: step.hint,
            ctx: CoachPhraseContext(subjectNoun: step.title, detail: step.hint), voice: voice) ?? step.hint
    }

    private func stepRow(_ step: ShotStep) -> some View {
        let done = completedStepIDs.contains(step.id)
        let current = step.id == currentStepID
        return Button {
            onSelectStep(step.id)
            dismiss()
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    if done {
                        Circle().fill(BrandColor.accent).frame(width: 22, height: 22)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(BrandColor.onAccent)
                    } else {
                        Circle()
                            .strokeBorder(current ? BrandColor.accent
                                                  : BrandColor.textPrimary.opacity(0.24),
                                          lineWidth: 2)
                            .frame(width: 22, height: 22)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title)
                        .font(current ? BrandFont.display(15, .semibold) : BrandFont.body(14.5))
                        .foregroundStyle(done ? BrandColor.textMuted : BrandColor.textPrimary)
                    if current {
                        Text(renderedHint(step))
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            .background(current ? BrandColor.accent.opacity(0.12)
                                : BrandColor.textPrimary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(current ? BrandColor.accent.opacity(0.34) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(step.title)
        .accessibilityValue(done ? "captured" : (current ? "current shot" : "not taken yet"))
    }
}
