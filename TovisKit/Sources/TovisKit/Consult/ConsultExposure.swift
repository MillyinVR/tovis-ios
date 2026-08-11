import Foundation

/// Fail-closed mirror of the web C5/C6/C7 ship gate. C8 code may be exercised
/// with deterministic mocks, but no production entry or result surface exists
/// until BOTH reviewed live-evidence outcomes are deliberately checked in.
public struct ConsultExposurePolicy: Sendable, Equatable {
    public static let founderProfessionalIDs: Set<String> = [
        "cmq9p645v0002jp04fttoatlq",
    ]

    public static let c5LiveBaselineApproved = false
    public static let c5LiveCandidatePassed = false

    public static let production = ConsultExposurePolicy(
        founderProfessionalIDs: founderProfessionalIDs,
        liveBaselineApproved: c5LiveBaselineApproved,
        liveCandidatePassed: c5LiveCandidatePassed
    )

    private let founderProfessionalIDs: Set<String>
    private let liveBaselineApproved: Bool
    private let liveCandidatePassed: Bool

    public init(founderProfessionalIDs: Set<String>, liveBaselineApproved: Bool,
                liveCandidatePassed: Bool) {
        self.founderProfessionalIDs = founderProfessionalIDs
        self.liveBaselineApproved = liveBaselineApproved
        self.liveCandidatePassed = liveCandidatePassed
    }

    public func allows(professionalId: String?) -> Bool {
        guard let professionalId, founderProfessionalIDs.contains(professionalId) else { return false }
        return liveBaselineApproved && liveCandidatePassed
    }
}
