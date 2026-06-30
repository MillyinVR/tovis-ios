import Foundation

// Pure closeout-checklist logic for the wrap-up screen — the native counterpart
// of the web `lib/proSession/closeoutChecklist.ts`. Drives the five wrap-up rows
// (after photos · aftercare sent · payment collected · checkout paid/waived ·
// consultation approved) and the help text. No network — unit-tested 1:1.

public struct ProSessionCloseoutInput: Sendable {
    public let afterCount: Int
    public let hasAfterPhoto: Bool
    public let hasAftercareDraft: Bool
    public let hasFinalizedAftercare: Bool
    public let hasPaymentCollected: Bool
    public let hasCheckoutClosed: Bool
    public let hasConsultationApproved: Bool

    public init(
        afterCount: Int,
        hasAfterPhoto: Bool,
        hasAftercareDraft: Bool,
        hasFinalizedAftercare: Bool,
        hasPaymentCollected: Bool,
        hasCheckoutClosed: Bool,
        hasConsultationApproved: Bool
    ) {
        self.afterCount = afterCount
        self.hasAfterPhoto = hasAfterPhoto
        self.hasAftercareDraft = hasAftercareDraft
        self.hasFinalizedAftercare = hasFinalizedAftercare
        self.hasPaymentCollected = hasPaymentCollected
        self.hasCheckoutClosed = hasCheckoutClosed
        self.hasConsultationApproved = hasConsultationApproved
    }
}

public enum ProSessionCloseoutKey: String, Sendable, Equatable {
    case afterPhotos
    case aftercare
    case payment
    case checkout
    case consultation
}

public struct ProSessionCloseoutItem: Sendable, Equatable, Identifiable {
    public let key: ProSessionCloseoutKey
    public let title: String
    public let subtitle: String
    public let done: Bool

    public var id: String { key.rawValue }
}

public struct ProSessionCloseoutChecklist: Sendable, Equatable {
    public let canComplete: Bool
    public let helpText: String
    public let items: [ProSessionCloseoutItem]
}

public enum ProSessionCloseout {
    public static let readyHelpText =
        "All closeout requirements are ready. Finish closeout from aftercare."
    public static let blockedHelpText =
        "Requires approved consultation, after photos, finalized aftercare, collected payment, and paid or waived checkout."

    /// Port of `buildProSessionCloseoutChecklist`.
    public static func checklist(_ input: ProSessionCloseoutInput) -> ProSessionCloseoutChecklist {
        let aftercareStatus = input.hasFinalizedAftercare
            ? "finalized + sent"
            : input.hasAftercareDraft ? "draft saved" : "missing"

        let paymentStatus = input.hasPaymentCollected ? "collected" : "not collected"
        let checkoutStatus = input.hasCheckoutClosed ? "paid or waived" : "not closed"
        let consultationStatus = input.hasConsultationApproved ? "approved" : "not approved"

        let canComplete =
            input.hasAfterPhoto &&
            input.hasFinalizedAftercare &&
            input.hasPaymentCollected &&
            input.hasCheckoutClosed &&
            input.hasConsultationApproved

        return ProSessionCloseoutChecklist(
            canComplete: canComplete,
            helpText: canComplete ? readyHelpText : blockedHelpText,
            items: [
                ProSessionCloseoutItem(
                    key: .afterPhotos,
                    title: "After photos",
                    subtitle: input.hasAfterPhoto ? "\(input.afterCount) photos captured" : "Missing",
                    done: input.hasAfterPhoto,
                ),
                ProSessionCloseoutItem(
                    key: .aftercare,
                    title: "Aftercare sent to client",
                    subtitle: aftercareStatus,
                    done: input.hasFinalizedAftercare,
                ),
                ProSessionCloseoutItem(
                    key: .payment,
                    title: "Payment collected",
                    subtitle: paymentStatus,
                    done: input.hasPaymentCollected,
                ),
                ProSessionCloseoutItem(
                    key: .checkout,
                    title: "Checkout paid or waived",
                    subtitle: checkoutStatus,
                    done: input.hasCheckoutClosed,
                ),
                ProSessionCloseoutItem(
                    key: .consultation,
                    title: "Consultation approved",
                    subtitle: consultationStatus,
                    done: input.hasConsultationApproved,
                ),
            ],
        )
    }
}
