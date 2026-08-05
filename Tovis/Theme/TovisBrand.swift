import Foundation

/// The tenant's display name, in one place.
///
/// Web resolves this per tenant (`lib/brand`) and its white-label guard fails any
/// hardcoded brand string in user-facing copy; the app has no tenant resolution
/// yet, so this constant is the seam that will read from one when it lands. It
/// exists because the name had started being re-typed at each call site — the
/// membership page, the profile tab, and now the export signature, which draws it
/// into a file a pro publishes.
enum TovisBrand {
    static let displayName = "Tovis"
}
