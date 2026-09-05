// The one thing that owes the server a photo, for as long as it takes.
//
// 🔴 Why this exists, concretely: before it, a session photo's upload was an
// unstructured `Task` spawned by the camera VIEW, on a foreground URLSession,
// with the retry queue living in that view's `@State`. Three consequences, all
// observed in production on 2026-08-20:
//
//   • Every shot uploaded at once. A dozen full-resolution captures inside a
//     minute all raced the same pipe, so none of them finished.
//   • Closing the camera killed the queue. `.onDisappear` stopped the retry
//     scheduler, and stranded bytes were only ever re-offered the next time the
//     camera reopened ON THAT SAME BOOKING — which, after checkout, never.
//   • Backgrounding the app killed the transfers outright.
//
// The server logs for that day are unambiguous: ~25 session presigns, zero
// completed uploads. The bytes never left the phone.
//
// So custody moves here: an app-lifetime queue over a BACKGROUND URLSession.
// The system keeps transferring while the app is suspended, and relaunches the
// app to finish (`sessionSendsLaunchEvents`) if it was killed mid-flight. That
// is what makes "shoot it, close the camera, close out the session, walk away"
// actually land — and what makes an offline shoot land later without the pro
// doing anything.
//
// ⚠️ TWO pieces of durable state, and they are not the same thing:
//
//   • `SessionByteVault.pendingUpload` — the BYTES. The source of truth for
//     "what is still owed". A file there means a photo exists that the server
//     has not accepted; it is deleted only on a confirmed upload or an explicit
//     discard. The queue is rebuilt from this directory on every launch, so
//     nothing depends on this class's in-memory state surviving anything.
//   • `journal` — the in-flight LEG. Which storage path a given vault file was
//     presigned to, and whether its bytes already landed. Purely an optimization
//     against re-uploading bytes that are already up; losing it costs one repeat
//     PUT, never a photo.
//
// Uploads run ONE AT A TIME on purpose (`httpMaximumConnectionsPerHost = 1`, and
// only one task in flight). Six concurrent uploads on a salon connection is how
// the old code managed to complete zero of them; one at a time, each finishes.
import Foundation
import TovisKit

@MainActor
@Observable
final class SessionUploadQueue {
    static let shared = SessionUploadQueue()

    /// Photos whose bytes the server has not accepted yet — the number the pro
    /// is shown, and the number that must reach zero before the shoot is safe.
    private(set) var pendingCount = 0

    /// Whether the queue's most recent attempt actually FAILED (offline, a 5xx,
    /// a timeout) and it is waiting out a backoff. False while photos are merely
    /// queued or in flight — that is the difference between "still uploading"
    /// (background work, a hairline, no words) and "waiting on signal" (the
    /// lane's alert + RETRY). Cleared by the next confirmed photo or by the
    /// queue draining empty; deliberately NOT cleared when a retry attempt
    /// starts, so the alert doesn't flap off/on around every backoff cycle.
    private(set) var stalled = false

    /// What the camera lane should raise an ALERT about: everything owed, but
    /// only once an attempt has actually failed — the whole serial queue is
    /// stuck behind the failing head, so the full count is the honest number.
    /// 0 while the queue is healthy: an in-flight upload is not a warning.
    var stalledPendingCount: Int { stalled ? pendingCount : 0 }

    /// Photos the server REFUSED (a 4xx it will repeat). These are not retried;
    /// they need a decision, and they keep their bytes until they get one.
    private(set) var blockedCount = 0

    /// The last transient failure worth showing, cleared on the next success.
    private(set) var statusMessage: String?

    /// The same two counts broken down by custody scope (a booking id, or
    /// `"practice"`), so a booking's own screen can speak only about its own
    /// photos rather than about everything the app happens to owe.
    ///
    /// Recomputed alongside the totals rather than derived on demand: the source
    /// is a directory listing, and a view that read it every render would hit the
    /// filesystem on every render.
    private(set) var pendingByScope: [String: Int] = [:]
    private(set) var blockedByScope: [String: Int] = [:]

    /// Vault files the server has not accepted yet, as a set, so a thumbnail can
    /// ask "is MY photo still owed?" with a lookup instead of a stat() — and
    /// without the camera needing a `.onChange` modifier to keep badges honest.
    /// (That modifier is not a free abstraction: adding one to the capture
    /// view's chain pushed an unrelated expression over the compiler's
    /// type-check budget on CI. See `ProCapturePhotosView.pendingSync`.)
    private(set) var pendingURLs: Set<URL> = []

    /// Whether this exact vault file is still owed to the server.
    func isPending(_ url: URL?) -> Bool {
        guard let url else { return false }
        return pendingURLs.contains(url)
    }

    /// Photos still owed for one booking (or for practice).
    func pendingCount(scope: String) -> Int { pendingByScope[scope] ?? 0 }

    /// Photos the server refused for one booking (or for practice).
    func blockedCount(scope: String) -> Int { blockedByScope[scope] ?? 0 }

    /// Set once the pro is signed in — presign and confirm are authenticated.
    /// Until then the queue holds its bytes and does nothing.
    private var client: TovisClient?

    private var journal: [String: Job] = [:]
    /// Storage paths whose PUT is currently with the system.
    private var inFlight: Set<String> = []
    /// Vault files the server refused; excluded from draining until released.
    private var blocked: Set<URL> = []
    private var isDraining = false
    private let retry = UploadRetryScheduler(steps: [3, 8, 20, 45, 90])
    private let connectivity = ConnectivityMonitor()

    /// Fires on the main actor each time a photo is accepted server-side, so
    /// whatever is on screen (the session hub's gallery) can refetch. Set by the
    /// app root; the queue itself knows nothing about the UI.
    var onMediaConfirmed: (() -> Void)?

    /// UIKit hands this over when it relaunches us to deliver background events;
    /// it must be called, on the main thread, once the session says it's done.
    var backgroundEventsCompletion: (() -> Void)?

    // MARK: - The background session

    /// Named, not a literal, so `AppDelegate` can ROUTE a relaunch's background
    /// events to the queue that owns them — there is more than one background
    /// session in the app now (see `ConsultCaptureUploadQueue`).
    static let backgroundSessionIdentifier = "app.tovis.session-photo-uploads"

    /// ⚠️ Created exactly once per process. A second `URLSession` with the same
    /// background identifier is a hard crash, so this is `lazy` and nothing else
    /// may construct one.
    @ObservationIgnored
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: Self.backgroundSessionIdentifier
        )
        // The pro is standing in front of a client waiting on these — the system
        // must not defer them to a "convenient" moment tonight on wifi.
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        // One at a time. This is the whole fix for "twelve uploads, none landed".
        config.httpMaximumConnectionsPerHost = 1
        // A generous resource budget: a photo taken in a basement salon should
        // still land when the phone finds signal an hour later, not time out.
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    @ObservationIgnored
    private lazy var delegate = Delegate(owner: self)

    private init() {}

    // MARK: - Lifecycle

    /// Called once the client exists (sign-in, or app launch when already signed
    /// in). Rebuilds the queue from disk and starts draining whatever is owed —
    /// including photos captured in a previous launch.
    func configure(client: TovisClient) {
        self.client = client
        journal = Journal.load()
        connectivity.onReconnect = { [weak self] in
            guard let self else { return }
            self.retry.scheduleRetry(resetBackoff: true) { await self.drain() }
        }
        connectivity.start()
        // Adopt anything the system was still carrying for us across the
        // relaunch, so we neither re-upload it nor wait forever on a task this
        // process doesn't know about.
        Task {
            let carried = await session.allTasks
            for task in carried {
                if let path = Self.storagePath(of: task) { inFlight.insert(path) }
            }
            await drain()
        }
    }

    /// Bring the background session into existence NOW, without waiting for
    /// sign-in.
    ///
    /// 🔴 The relaunch path depends on this. When iOS wakes the app purely to
    /// deliver a finished transfer, `configure` has not run yet — it hangs off
    /// the signed-in shell, which is behind `bootstrap()`, which is behind the
    /// network. Until a `URLSession` with this identifier exists there is no
    /// delegate, so the events never arrive and the completion handler UIKit
    /// gave us is never called — which iOS penalises the app for.
    ///
    /// Touching `session` is the whole job: it is `lazy`, so this constructs it
    /// and registers the delegate. A confirm that then needs an authenticated
    /// client and doesn't have one is fine — the journal already records that
    /// the bytes landed, so the next foreground launch finishes that leg
    /// instead of re-uploading anything.
    func prepareForBackgroundEvents() {
        _ = session
    }

    /// A photo has just been written to the vault and is owed to the server.
    func enqueue() {
        refreshPendingCount()
        Task { await drain() }
    }

    // MARK: - Draining

    /// Send the next owed photo, if nothing is already in flight. Re-entrant-safe
    /// and cheap to call — every completion calls it again, so the queue walks
    /// itself to empty.
    func drain() async {
        guard !isDraining, let client else { return }
        isDraining = true
        defer { isDraining = false }
        await drainLoop(client: client)
    }

    /// ⚠️ A LOOP, not recursion. Every step that finishes a photo without
    /// starting a transfer (a confirm that was still owed, a refusal that parks
    /// the photo) has to move on to the next one — and calling `drain()` again
    /// from in here cannot do that: `isDraining` is still true, so the nested
    /// call returns immediately and the queue simply stops until something
    /// external happens to kick it.
    private func drainLoop(client: TovisClient) async {
        while true {
            refreshPendingCount()

            // One PUT at a time: the delegate calls back when it lands.
            //
            // ⚠️ Reconcile first. `inFlight` is the only thing stopping the
            // queue from starting more work, so a path left in it by a task the
            // system no longer has (killed mid-flight, a callback lost across a
            // relaunch) would stall every remaining photo — permanently, and
            // silently. Trust the session's own list over ours.
            if !inFlight.isEmpty {
                let live = Set(await session.allTasks.compactMap(Self.storagePath(of:)))
                inFlight.formIntersection(live)
            }
            guard inFlight.isEmpty else { return }

            let owed = SessionByteVault.allPendingUploads()
                .filter { !blocked.contains($0.url) }
            guard let next = owed.first else {
                statusMessage = nil
                stalled = false
                return
            }

            // Bytes already up, only the confirm still owed — finish that leg
            // rather than paying for the transfer twice.
            if let job = journal.values.first(where: {
                $0.vaultPath == next.url.path && $0.bytesUploaded
            }) {
                // ⚠️ `.retryLater` MUST stop the loop: the photo stays owed and
                // still first in the queue, so continuing would pick it straight
                // back up and spin.
                if await confirm(job, client: client) == .retryLater { return }
                continue
            }

            do {
                let job = try await presign(next, client: client)
                journal[job.storagePath] = job
                Journal.save(journal)
                // Only in flight once the system actually has it: a path sitting
                // in `inFlight` with no task behind it halts the whole queue.
                try startUpload(job, client: client)
                inFlight.insert(job.storagePath)
                return   // the delegate drives the next step
            } catch let error as APIError where !error.isRetryable {
                // The signing route REFUSED these bytes — not a bad connection,
                // an answer. Retrying reproduces it forever, so park the photo
                // for a decision, exactly as a refused confirm does. (This is
                // the shape of a booking that is no longer the pro's, or one
                // completed longer ago than the server's post-closeout grace.)
                block(next.url, reason: error.userMessage)
                continue
            } catch {
                // Offline, or a 5xx. The bytes are untouched on disk; back off
                // and try the whole leg again.
                handleTransient(error)
                return
            }
        }
    }

    /// Park one photo as refused: keep its bytes, stop retrying, and say so.
    /// The pro decides — save it to their own library, or drop it.
    ///
    /// 🔴 Never deletes anything. A refusal is the one case where the server
    /// will never take these bytes, which makes them the ONLY copy of a photo
    /// the pro actually took.
    private func block(_ url: URL, reason: String) {
        blocked.insert(url)
        blockedCount = blocked.count
        statusMessage = reason
        refreshPendingCount()   // also re-buckets it under `blockedByScope`
    }

    /// Mint a signed upload target for one vault file.
    private func presign(
        _ pending: SessionByteVault.PendingUpload, client: TovisClient
    ) async throws -> Job {
        guard let data = SessionByteVault.read(pending.url) else {
            // The file vanished under us — nothing is owed for it any more.
            throw QueueError.bytesGone
        }
        let isPractice = pending.scope == ProCameraDestination.practice.custodyScope
        let target: MediaUploadInit = isPractice
            ? try await client.proPractice.presign(contentType: "image/jpeg", size: data.count)
            : try await client.proMedia.presign(
                bookingId: pending.scope, phase: pending.phase,
                contentType: "image/jpeg", size: data.count
            )
        return Job(
            storageBucket: target.bucket,
            storagePath: target.path,
            token: target.token,
            uploadSessionId: target.uploadSessionId,
            scope: pending.scope,
            phaseRaw: pending.phase.rawValue,
            vaultPath: pending.url.path,
            focalX: pending.focal?.x,
            focalY: pending.focal?.y,
            capturedAt: pending.capturedAt,
            // The hash of the EXACT bytes being sent. A pure function of the
            // file, so it is identical on a first attempt or a retry days later
            // — same contract as before, just computed once per job instead of
            // once per in-memory send.
            checksumSha256: MediaHash.sha256Hex(data),
            bytesUploaded: false
        )
    }

    /// Hand the transfer to the system. From here the app can be backgrounded,
    /// suspended, or killed — the upload continues and we get called back.
    private func startUpload(_ job: Job, client: TovisClient) throws {
        guard let request = SupabaseSignedUpload.backgroundUploadRequest(
            supabaseURL: client.supabaseURL,
            supabaseKey: client.supabaseAnonKey,
            bucket: job.storageBucket,
            path: job.storagePath,
            token: job.token,
            contentType: "image/jpeg"
        ) else { throw QueueError.storageUnconfigured }

        let task = session.uploadTask(with: request, fromFile: job.vaultURL)
        task.taskDescription = job.storagePath
        task.resume()
    }

    // MARK: - Completion (called from the delegate)

    fileprivate func uploadFinished(storagePath: String, status: Int?, error: Error?) async {
        inFlight.remove(storagePath)
        guard let client, let job = journal[storagePath] else {
            await drain()
            return
        }

        guard error == nil, let status, (200..<300).contains(status) else {
            // The signed token is spent either way, so drop the leg and let the
            // next drain re-presign from the same untouched bytes.
            journal[storagePath] = nil
            Journal.save(journal)
            handleTransient(error ?? QueueError.uploadRejected(status ?? 0))
            return
        }

        var landed = job
        landed.bytesUploaded = true
        journal[storagePath] = landed
        Journal.save(journal)
        // Not inside `drainLoop`, so a fresh drain is both safe and needed to
        // start the next photo.
        if await confirm(landed, client: client) != .retryLater {
            await drain()
        }
    }

    /// Record the MediaAsset (or PracticeShot) now the bytes are up, then let
    /// the photo go.
    /// What the confirm leg settled, so `drainLoop` knows whether it may move
    /// on to the next photo or must stop and wait for a retry.
    private enum ConfirmOutcome {
        /// Accepted server-side; the bytes are released.
        case released
        /// Refused; parked for the pro to decide. The queue may move on.
        case blocked
        /// Transient; this photo is STILL first in the queue, so the loop must
        /// stop rather than pick it straight back up.
        case retryLater
    }

    @discardableResult
    private func confirm(_ job: Job, client: TovisClient) async -> ConfirmOutcome {
        do {
            let focal = MediaFocalPoint(x: job.focalX, y: job.focalY)
            if job.scope == ProCameraDestination.practice.custodyScope {
                _ = try await client.proPractice.confirm(
                    uploadSessionId: job.uploadSessionId, mediaType: .image, focal: focal
                )
            } else {
                _ = try await client.proMedia.confirm(
                    bookingId: job.scope,
                    uploadSessionId: job.uploadSessionId,
                    phase: MediaPhase(rawValue: job.phaseRaw) ?? .other,
                    mediaType: .image,
                    focal: focal,
                    capturedAt: job.capturedAt,
                    checksumSha256: job.checksumSha256
                )
            }
            // Safe server-side — release the bytes and move on. A confirmed
            // photo proves the pipe works, so any earlier stall is over.
            SessionByteVault.remove(job.vaultURL)
            journal[job.storagePath] = nil
            Journal.save(journal)
            statusMessage = nil
            stalled = false
            retry.stop()
            onMediaConfirmed?()
            return .released
        } catch let error as APIError where !error.isRetryable {
            // A refusal repeats forever. Stop spending the pro's battery on it,
            // keep the bytes, and say so.
            journal[job.storagePath] = nil
            Journal.save(journal)
            block(job.vaultURL, reason: error.userMessage)
            return .blocked
        } catch {
            // Transient: the bytes are up, so keep the leg and retry the confirm
            // alone rather than paying for the transfer again.
            handleTransient(error)
            return .retryLater
        }
    }

    private func handleTransient(_ error: Error) {
        let apiError = error as? APIError
        statusMessage = apiError?.userMessage
            ?? "Still uploading — waiting for a better connection."
        // An attempt genuinely failed — from here the lane may raise its alert.
        stalled = true
        refreshPendingCount()
        retry.scheduleRetry { [weak self] in
            guard let self else { return }
            await self.drain()
        }
    }

    // MARK: - Pro-facing actions

    /// Try everything again now, including photos parked as refused — a pro tap
    /// is a fresh decision and deserves one honest attempt.
    func retryNow() async {
        blocked.removeAll()
        blockedCount = 0
        statusMessage = nil
        retry.stop()
        refreshPendingCount()
        await drain()
    }

    /// Give up on the refused photos and delete their bytes. The pro's explicit
    /// choice; nothing else in this class ever deletes an unconfirmed photo.
    func discardBlocked() {
        for url in blocked { SessionByteVault.remove(url) }
        blocked.removeAll()
        blockedCount = 0
        refreshPendingCount()
    }


    /// The refused photos' bytes, so the pro can keep them out of the app.
    func blockedPayloads() -> [URL] { Array(blocked) }

    private func refreshPendingCount() {
        let all = SessionByteVault.allPendingUploads()
        let (refused, owed) = (
            all.filter { blocked.contains($0.url) },
            all.filter { !blocked.contains($0.url) }
        )
        pendingCount = owed.count
        pendingURLs = Set(owed.map(\.url))
        pendingByScope = Dictionary(grouping: owed, by: \.scope).mapValues(\.count)
        blockedByScope = Dictionary(grouping: refused, by: \.scope).mapValues(\.count)
    }

    // MARK: - Types

    /// One upload leg: which storage target a vault file was presigned to, and
    /// whether its bytes already landed.
    private struct Job: Codable {
        let storageBucket: String
        let storagePath: String
        let token: String
        let uploadSessionId: String
        /// Booking id, or `"practice"` — see `ProCameraDestination.custodyScope`.
        let scope: String
        let phaseRaw: String
        let vaultPath: String
        let focalX: Double?
        let focalY: Double?
        let capturedAt: Date?
        let checksumSha256: String
        var bytesUploaded: Bool

        var vaultURL: URL { URL(fileURLWithPath: vaultPath) }
    }

    private enum QueueError: Error {
        case bytesGone
        case storageUnconfigured
        case uploadRejected(Int)
    }

    /// Which upload a system callback belongs to. `taskDescription` is set when
    /// we create the task, but a task resurrected into a NEW process after the
    /// app was killed is not guaranteed to carry it — so the storage path is
    /// recovered from the request URL as the durable fallback.
    fileprivate nonisolated static func storagePath(of task: URLSessionTask) -> String? {
        if let described = task.taskDescription, !described.isEmpty { return described }
        guard let url = task.originalRequest?.url else { return nil }
        return SupabaseSignedUpload.storagePath(fromSignedUploadURL: url)
    }

    // MARK: - Journal persistence

    private enum Journal {
        private static var url: URL? {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("session-upload-journal.json")
        }

        static func load() -> [String: Job] {
            guard let url, let data = try? Data(contentsOf: url) else { return [:] }
            return (try? JSONDecoder().decode([String: Job].self, from: data)) ?? [:]
        }

        static func save(_ journal: [String: Job]) {
            guard let url, let data = try? JSONEncoder().encode(journal) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Forwards the background session's callbacks onto the main actor. Separate
    /// from the queue itself so the queue can stay `@MainActor` and `@Observable`
    /// rather than an NSObject with nonisolated mutable state.
    ///
    /// `owner` is `nonisolated(unsafe)` deliberately: `weak` storage is never
    /// statically Sendable (the reference can drop between check and use), but
    /// this instance satisfies the invariant anyway — the property is written
    /// ONCE in init, before the delegate is handed to its URLSession, and only
    /// ever read via `[weak owner]` in delegate callbacks. URLSession invokes
    /// its delegate on a single serial queue, so there is no concurrent write
    /// to race with. The unsafe annotation documents that reasoning at the
    /// site instead of letting the conformance lie about it.
    private final class Delegate: NSObject, URLSessionDataDelegate {
        private nonisolated(unsafe) weak var owner: SessionUploadQueue?

        init(owner: SessionUploadQueue) {
            self.owner = owner
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
        ) {
            let path = SessionUploadQueue.storagePath(of: task)
            let status = (task.response as? HTTPURLResponse)?.statusCode
            Task { @MainActor [weak owner] in
                guard let owner, let path else { return }
                await owner.uploadFinished(storagePath: path, status: status, error: error)
            }
        }

        /// The system finished delivering everything it held for us after a
        /// relaunch — UIKit's completion handler must run now, on the main
        /// thread, or the app is killed for not answering.
        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            Task { @MainActor [weak owner] in
                guard let owner else { return }
                owner.backgroundEventsCompletion?()
                owner.backgroundEventsCompletion = nil
            }
        }
    }
}
