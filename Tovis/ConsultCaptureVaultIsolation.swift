import Foundation

/// TEST-ONLY isolation for the process-wide byte vault.
///
/// The vault is one directory per bucket for the whole app, which is exactly
/// right in production — there is one queue, and it must be able to see every
/// photograph anything owes. It is wrong under Swift Testing, which runs
/// separate suites in PARALLEL: two suites that both write owed photos would
/// race each other's cleanup, and one suite's queue would drain the other's
/// items and record the wrong idempotency keys.
///
/// A task-local rather than a plain static, deliberately: a static would be
/// clobbered by whichever parallel suite set it last, which is the same race
/// wearing a different hat. Each test runs in its own task tree, so a value
/// bound with `$suffix.withValue` is that test's alone — and the queue's own
/// `Task { … }` drains inherit it, because they are child tasks.
///
/// Nothing in the app ever binds it, so `suffix` is nil in every shipping path
/// and the vault directories are exactly where they have always been.
enum ConsultCaptureVaultIsolation {
    @TaskLocal static var suffix: String?
}
