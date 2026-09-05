// The one thing that owes the consult server a photograph, for as long as it takes.
//
// 🔴 Why this exists, concretely. The prod audit of consult session
// `cmtnulymz0002ju0422splbqb` found shots that had a `UploadSession` row and no
// `ConsultCapture` — bytes the phone had promised and never delivered. The
// cause was structural, not a bug in any one line:
//
//   • The whole issue→PUT→attach→quality chain was ONE foreground `Task` owned
//     by the camera view, and `.onDisappear`/`cancel()` cancelled it. Dismissing
//     the camera the instant the shutter fired dropped the photograph — silently,
//     because `ConsultTransientPhotoPipeline` returns `.cancelled` and the view
//     model treats that as nothing having happened.
//   • The bytes lived only in RAM (`ConsultFlowViewModel.pendingPhoto`), so
//     backgrounding, a jetsam kill or a crash lost them outright.
//   • The issued ticket and all three idempotency keys lived in an in-memory
//     actor (`ConsultCaptureAttemptStore`), so even a survivable failure could
//     not resume — a retry minted a SECOND upload session and spent a SECOND
//     paid quality check for the same photograph.
//   • Retry was one manual button over a single slot, and the flow refreshed
//     capture state only from a mutation's own response. A shot stuck anywhere
//     rendered as "Required": indistinguishable from one never taken.
//
// So custody moves here, on the same design as `SessionUploadQueue`: an
// app-lifetime queue over a BACKGROUND `URLSession`, fed from bytes on disk,
// rebuilt from that disk on every launch. A shot survives the camera closing,
// the app backgrounding, and the process dying.
//
// ⚠️ TWO durable things, and they are not the same:
//
//   • `SessionByteVault.consultCapture` — the BYTES plus that shot's manifest
//     (which consult, which slot, which three idempotency keys, how far the
//     chain got). This is the source of truth for "what is still owed"; the
//     queue holds no state that has to survive anything.
//   • The system's own background session — the in-flight PUT. Losing track of
//     it costs one repeat transfer, never a photograph.
//
// Uploads run ONE AT A TIME, for the same reason the pro queue does: a pack is
// seven full-resolution captures inside a couple of minutes, and seven of those
// racing one salon connection is how none of them finish.
//
// 🔴 The chain's order of recovery is not arbitrary — it is dictated by the
// server contract in lib/consult/captureContract.ts:
//
//   • Re-issuing under the SAME key returns the same upload session and storage
//     path with a FRESH signed URL, but throws CONSULT_CAPTURE_UPLOAD_EXPIRED
//     (410) once that session is no longer PENDING or has passed its ONE HOUR
//     TTL. Attach is what marks it CONSUMED.
//   • So attach is ALWAYS tried before re-issuing. A lost attach response
//     replays by key and returns the same captureId; re-issuing first would hit
//     the consumed session and look like an expiry.
//   • The PUT is `x-upsert: false` against a fixed path. A second PUT after a
//     lost completion callback is therefore a duplicate, not a retry — which is
//     why a PUT that came back with an HTTP STATUS goes to attach (the server
//     inspects the object and decides), while only a PUT that never reached
//     storage at all (a transport failure) is re-sent.
import Foundation
import TovisKit

@MainActor
@Observable
final class ConsultCaptureUploadQueue {
    static let shared = ConsultCaptureUploadQueue()

    typealias Item = SessionByteVault.ConsultCaptureItem

    /// Where each owed shot has got to, by consult and then by slot. The
    /// capture screen reads this so an in-flight shot is never rendered as one
    /// that was never taken.
    ///
    /// ⚠️ Keyed by CONSULT as well as slot, not by slot alone. The vault can
    /// legitimately hold owed shots from an earlier consult the client walked
    /// away from mid-pack, and a slot-only key would paint the new consult's
    /// `hair_back` with the old one's progress.
    ///
    /// Recomputed on every change rather than derived on demand, for the reason
    /// `SessionUploadQueue.pendingURLs` spells out: the source is a directory
    /// listing plus a JSON decode per file, and a view that read it on every
    /// render would hit the filesystem on every render.
    private(set) var stages: [String: [ConsultCaptureShotKey: ConsultCaptureStage]] = [:]

    /// The server's refusal per refused slot, by consult — same reasoning.
    private(set) var blockedReasons: [String: [ConsultCaptureShotKey: String]] = [:]

    /// How many shots each consult still owes, and which have a refusal that
    /// needs a decision. Both observable, so the screen never stats a directory.
    private(set) var owedByConsult: [String: Int] = [:]
    private(set) var blockedConsults: Set<String> = []

    /// Whether the most recent attempt actually FAILED (offline, a 5xx, a
    /// timeout) and the queue is waiting out a backoff — as opposed to merely
    /// being busy. Drives the "waiting for a connection" line, and deliberately
    /// stays set across a backoff cycle so it doesn't flap.
    private(set) var stalled = false

    /// The last refusal worth showing, cleared by the next accepted photo.
    private(set) var statusMessage: String?

    /// Called on the main actor whenever a leg completes, so the flow can
    /// re-read capture state from the SERVER rather than from a mutation's own
    /// response. Set by `ConsultFlowViewModel`.
    var onStageCompleted: ((String) -> Void)?

    /// UIKit's completion handler for a relaunch that exists to deliver this
    /// session's events; must be called, on the main thread, when it's done.
    var backgroundEventsCompletion: (() -> Void)?

    static let backgroundSessionIdentifier = "app.tovis.consult-capture-uploads"

    /// A consult shot that has waited longer than this is past saving: the
    /// server's raw-object TTL is 24h, after which attach and quality both
    /// refuse. Holding the client's photograph on disk beyond the point where
    /// it can still be delivered is storage of a private image for no purpose,
    /// so it is released with an honest message instead.
    private static let maximumOwedAge: TimeInterval = 24 * 60 * 60

    /// See `drainLoop`. Four legs plus slack; a correct chain never reaches it.
    private static let maximumAdvancesPerPass = 6

    /// What the queue needs to talk to the world. A struct rather than a
    /// `TovisClient` so the queue can be driven by a stub in tests — the
    /// durability rules below (resume at the right leg, never mint a second
    /// upload session, treat a 429 quality cap as terminal) are the part most
    /// worth testing and the part hardest to reach through a live client.
    struct Dependencies {
        let service: any ConsultServicing
        let supabaseURL: URL?
        let supabaseKey: String?

        init(service: any ConsultServicing, supabaseURL: URL?, supabaseKey: String?) {
            self.service = service
            self.supabaseURL = supabaseURL
            self.supabaseKey = supabaseKey
        }

        init(client: TovisClient) {
            self.init(
                service: client.consult,
                supabaseURL: client.supabaseURL,
                supabaseKey: client.supabaseAnonKey
            )
        }
    }

    /// What happened when the bytes were handed off.
    enum TransferHandoff {
        /// The system has it; its delegate will call back, possibly in another
        /// process. This is what the real background session always returns.
        case handedToSystem
        /// It finished here and now. Only a substituted transfer does this.
        case completed(status: Int?, error: Error?)
    }

    /// How bytes reach storage. The default hands the file to the BACKGROUND
    /// `URLSession`, which is the entire reason this class exists; a test
    /// substitutes something that completes inline so a "round trip" is
    /// deterministic rather than a race against a real socket.
    typealias Transfer = @MainActor (URLRequest, URL, UUID) async -> TransferHandoff

    @ObservationIgnored private var dependencies: Dependencies?
    @ObservationIgnored private var transfer: Transfer?
    /// Item ids whose PUT is currently with the system.
    @ObservationIgnored private var inFlight: Set<UUID> = []
    /// The tail of the serial chain drains form, so a caller can wait for the
    /// queue to stop moving instead of racing a detached task.
    @ObservationIgnored private var drainTail: Task<Void, Never>?
    @ObservationIgnored private let retry = UploadRetryScheduler(steps: [3, 8, 20, 45, 90])
    @ObservationIgnored private let connectivity = ConnectivityMonitor()

    @ObservationIgnored
    private lazy var delegate = Delegate(owner: self)

    /// ⚠️ Created exactly once per process — a second `URLSession` with the same
    /// background identifier is a hard crash — so this is `lazy` and nothing
    /// else may construct one.
    @ObservationIgnored
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: Self.backgroundSessionIdentifier
        )
        // The client is sitting in the flow waiting on this. It must not be
        // deferred to a convenient moment tonight on wifi.
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        // One at a time — see the header.
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = 120
        // The server's own raw-object TTL is 24h; there is nothing to gain from
        // a transfer the server would refuse on arrival.
        config.timeoutIntervalForResource = Self.maximumOwedAge
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    /// `.shared` is the app's one queue. A fresh instance is for tests only —
    /// two instances must never share the background session identifier, which
    /// is why the real session is created lazily and only by whoever actually
    /// uploads.
    init() {}

    // MARK: - Lifecycle

    /// Called once the client exists (sign-in, or launch when already signed
    /// in). Adopts anything the system was still carrying and drains whatever
    /// is owed — including shots captured in a previous launch.
    func configure(client: TovisClient) {
        configure(dependencies: Dependencies(client: client), transfer: nil)
    }

    /// `transfer` nil means the real background session.
    func configure(dependencies: Dependencies, transfer: Transfer?) {
        self.dependencies = dependencies
        self.transfer = transfer
        connectivity.onReconnect = { [weak self] in
            guard let self else { return }
            ConsultCaptureTelemetry.queue("reconnect")
            self.retry.scheduleRetry(resetBackoff: true) { await self.drain() }
        }
        connectivity.start()
        refreshStages()
        ConsultCaptureTelemetry.queue("configured owed=\(SessionByteVault.allConsultCaptures().count)")
        guard transfer == nil else {
            scheduleDrain()
            return
        }
        Task {
            // Adopt anything the system was still carrying across the relaunch,
            // so we neither re-upload it nor wait forever on a task this process
            // does not know about.
            let carried = await session.allTasks
            for task in carried {
                if let id = Self.itemID(of: task) { inFlight.insert(id) }
            }
            scheduleDrain()
        }
    }

    /// Bring the background session into existence NOW, without waiting for
    /// sign-in.
    ///
    /// 🔴 Same reasoning as `SessionUploadQueue.prepareForBackgroundEvents`:
    /// when iOS wakes the app purely to deliver a finished transfer, `configure`
    /// has not run — it hangs off the signed-in shell, which is behind the
    /// network. Until a session with this identifier exists there is no
    /// delegate, the events never arrive, and UIKit's completion handler is
    /// never called, which the app is penalised for.
    func prepareForBackgroundEvents() {
        _ = session
    }

    /// A consult shot has just been written to the vault and is owed.
    ///
    /// Schedules onto the one drain chain rather than spawning its own task: a
    /// detached drain would race whatever is already running, and the queue
    /// would have no single thing a caller could wait on.
    func enqueue(_ item: Item) {
        ConsultCaptureTelemetry.stage(
            .queued, outcome: .ok, shotKey: item.shotKey, consultId: item.consultId
        )
        refreshStages()
        scheduleDrain()
    }

    /// Wait for the drains already scheduled to finish, WITHOUT adding another.
    ///
    /// The distinction from `drain()` matters: `drain()` schedules a fresh pass,
    /// which is right for a retry tap or a reconnect and wrong for a caller that
    /// only wants to know the queue has caught up — an extra pass would re-try a
    /// leg that has just backed off, which is exactly what made a transient
    /// failure look like a resolved one.
    func settle() async {
        await drainTail?.value
    }

    /// Everything still owed for one consult, in capture order.
    func items(consultId: String) -> [Item] {
        SessionByteVault.allConsultCaptures().filter { $0.consultId == consultId }
    }

    /// Where this slot has got to locally, if anywhere. Nil means the queue owes
    /// nothing for it and the SERVER's slot state is the whole story.
    func stage(consultId: String, shotKey: ConsultCaptureShotKey) -> ConsultCaptureStage? {
        stages[consultId]?[shotKey]
    }

    /// A refusal the client is being shown for one slot.
    func blockedReason(consultId: String, shotKey: ConsultCaptureShotKey) -> String? {
        blockedReasons[consultId]?[shotKey]
    }

    /// Whether this consult still owes the server anything.
    func owesAnything(consultId: String) -> Bool { (owedByConsult[consultId] ?? 0) > 0 }

    /// Whether any of this consult's shots were refused and need a decision.
    func hasBlocked(consultId: String) -> Bool { blockedConsults.contains(consultId) }

    /// Try everything again now, including shots parked as refused — an explicit
    /// tap is a fresh decision and deserves one honest attempt.
    func retryNow() async {
        for var item in SessionByteVault.allConsultCaptures() where item.isBlocked {
            item.blockedReason = nil
            SessionByteVault.saveConsultCapture(item)
        }
        statusMessage = nil
        retry.stop()
        refreshStages()
        await drain()
    }

    /// Release every shot owed for one consult. Called when the client revokes
    /// sensitive-data consent: the server purges its side, and keeping her
    /// photographs on this device afterwards would be the app quietly holding
    /// what she just took back.
    func discardAll(consultId: String) {
        for item in items(consultId: consultId) {
            SessionByteVault.removeConsultCapture(item.id)
            ConsultCaptureTelemetry.stage(
                .released, outcome: .abandoned, shotKey: item.shotKey,
                consultId: item.consultId, detail: "consent_revoked"
            )
        }
        refreshStages()
    }

    // MARK: - Draining

    /// Run the queue and WAIT for it to stop moving.
    ///
    /// Drains are serialized on a chain rather than gated by a re-entrancy flag:
    /// a flag makes an overlapping call return immediately, which is fine for
    /// the app (something else will kick it) and useless for a caller that
    /// actually needs to know the queue has settled.
    func drain() async {
        scheduleDrain()
        await drainTail?.value
    }

    /// Queue a drain behind whatever is already running, without waiting.
    private func scheduleDrain() {
        let ahead = drainTail
        let mine = Task { [weak self] in
            await ahead?.value
            guard let self, let dependencies = self.dependencies else { return }
            await self.drainLoop(dependencies: dependencies)
        }
        drainTail = mine
    }

    /// ⚠️ A LOOP, not recursion — the same trap `SessionUploadQueue` documents.
    /// Every step that finishes a shot without starting a transfer has to move
    /// on to the next one, and a nested `drain()` cannot: `isDraining` is still
    /// true, so it returns immediately and the queue silently stops.
    private func drainLoop(dependencies: Dependencies) async {
        // ⚠️ Every shot that rotates its idempotency keys in THIS pass. A
        // rotation returns `.continueDraining`, so a server that answered the
        // fresh keys the same way would have the loop rotate and re-ask at full
        // speed, forever — a client's phone hammering the API with no ceiling.
        // One rotation per shot per pass; a second is treated as the refusal it
        // evidently is.
        var rotated: Set<UUID> = []
        // ⚠️ And a hard ceiling on how many legs one shot may be advanced in a
        // single pass. This loop terminates only because every `.continueDraining`
        // is supposed to have changed something — and whether it did depends on
        // what a REMOTE SERVER answered. A leg that "succeeds" without moving the
        // shot forward turns the loop into a spin at 100% CPU that also hammers
        // the API; two such paths were found and fixed while writing this (a
        // transient transfer returning continue, and unbounded key rotation), and
        // that is two too many to leave the structure able to do it at all. The
        // chain is four legs, so six is unreachable by correct behaviour.
        var advances: [UUID: Int] = [:]
        // Once per pass, not once per leg: it is a directory listing, and
        // nothing inside the pass can make a shot cross a 24-hour boundary.
        sweepExpired()
        while true {
            refreshStages()

            // ⚠️ Reconcile first. `inFlight` is the only thing stopping the
            // queue from starting more work, so an id left in it by a task the
            // system no longer has (killed mid-flight, a callback lost across a
            // relaunch) would stall every remaining shot — permanently, and
            // silently. Trust the session's own list over ours.
            if !inFlight.isEmpty {
                let live = Set(await session.allTasks.compactMap(Self.itemID(of:)))
                inFlight.formIntersection(live)
            }
            guard inFlight.isEmpty else { return }

            guard let next = SessionByteVault.allConsultCaptures()
                .first(where: { !$0.isBlocked }) else {
                statusMessage = nil
                stalled = false
                return
            }

            advances[next.id, default: 0] += 1
            guard advances[next.id, default: 0] <= Self.maximumAdvancesPerPass else {
                // Something is answering without advancing. Stop the pass and
                // let the backoff own the next attempt; never spin.
                ConsultCaptureTelemetry.stage(
                    .backoff, outcome: .retryLater, shotKey: next.shotKey,
                    consultId: next.consultId, detail: "advance_ceiling"
                )
                handleTransient(ConsultClientFailure.unavailable)
                return
            }

            switch await advance(next, dependencies: dependencies, rotated: &rotated) {
            case .startedTransfer, .retryLater:
                // Either the system has the bytes and its delegate drives the
                // next step, or this shot is STILL first in the queue — both
                // mean the loop must stop rather than spin on it.
                return
            case .continueDraining:
                continue
            }
        }
    }

    private enum Step {
        /// The system now holds a PUT for this shot.
        case startedTransfer
        /// This shot is finished, refused, or otherwise out of the way.
        case continueDraining
        /// Transient failure; the shot is unchanged and still first.
        case retryLater
    }

    /// Move ONE shot forward by exactly one leg.
    private func advance(
        _ item: Item, dependencies: Dependencies, rotated: inout Set<UUID>
    ) async -> Step {
        // Attach before anything else once the bytes are up: attach is what
        // consumes the upload session, and a lost attach RESPONSE replays by
        // key and hands back the same captureId. Re-issuing first would hit a
        // consumed session and read as an expiry.
        if let captureId = item.captureId {
            return await check(item, captureId: captureId, dependencies: dependencies)
        }
        if item.bytesUploaded {
            return await attach(item, dependencies: dependencies, rotated: &rotated)
        }
        // No ticket, or a ticket whose bytes never landed. Either way the next
        // move is the same: issue (or replay) the ticket — a replay returns the
        // same upload session with a FRESH signed URL — and transfer.
        return await issueAndTransfer(item, dependencies: dependencies, rotated: &rotated)
    }

    /// Whether this shot may still start over on fresh keys in this pass.
    private func mayRotate(_ item: Item, rotated: inout Set<UUID>) -> Bool {
        guard !rotated.contains(item.id) else { return false }
        rotated.insert(item.id)
        return true
    }

    // MARK: - Leg 1 + 2: the ticket and the transfer

    private func issueAndTransfer(
        _ item: Item, dependencies: Dependencies, rotated: inout Set<UUID>
    ) async -> Step {
        var item = item
        guard let bytes = SessionByteVault.consultCaptureBytes(item.id) else {
            // The file vanished under us — nothing is owed for it any more.
            SessionByteVault.removeConsultCapture(item.id)
            ConsultCaptureTelemetry.stage(
                .released, outcome: .abandoned, shotKey: item.shotKey,
                consultId: item.consultId, detail: "bytes_gone"
            )
            return .continueDraining
        }

        let ticket: ConsultCaptureUpload
        do {
            ticket = try await dependencies.service.issueCaptureUpload(
                consultId: item.consultId,
                shotKey: item.shotKey,
                shotPackVersion: item.shotPackVersion,
                schemaVersion: item.schemaVersion,
                sizeBytes: item.sizeBytes,
                idempotencyKey: item.keys.issue
            )
        } catch {
            if Self.isUploadExpired(error) {
                guard mayRotate(item, rotated: &rotated) else {
                    // Already started over once in this pass and the fresh keys
                    // were refused the same way. Retrying cannot win; park it.
                    return block(item, reason: ConsultClientFailure.invalidState.message,
                                 stage: .ticketed, detail: "upload_expired_repeat")
                }
                // The ticket is past saving. The bytes are not: rotate all three
                // keys and start this shot's chain over from a clean session.
                // Safe only here — `bytesUploaded` is false, so nothing was ever
                // attached under the old keys and no duplicate can result.
                item.keys = ConsultCaptureMutationKeys()
                item.uploadSessionId = nil
                item.storagePath = nil
                SessionByteVault.saveConsultCapture(item)
                ConsultCaptureTelemetry.stage(
                    .ticketed, outcome: .rotated, shotKey: item.shotKey,
                    consultId: item.consultId, detail: "upload_expired"
                )
                return .continueDraining
            }
            return settle(error, on: item, stage: .ticketed)
        }

        guard let signedURL = ticket.signedUrl.flatMap(URL.init(string:)),
              let request = try? SupabaseSignedUpload.signedURLUploadRequest(
                  supabaseURL: dependencies.supabaseURL,
                  supabaseKey: dependencies.supabaseKey,
                  signedURL: signedURL,
                  expectedToken: ticket.token,
                  contentType: "image/jpeg"
              ) else {
            return block(item, reason: ConsultClientFailure.contractMismatch.message,
                         stage: .ticketed, detail: "bad_signed_url")
        }

        item.uploadSessionId = ticket.uploadSessionId
        item.storagePath = SupabaseSignedUpload.storagePath(fromSignedUploadURL: signedURL)
        SessionByteVault.saveConsultCapture(item)
        ConsultCaptureTelemetry.stage(
            .ticketed, outcome: .ok, shotKey: item.shotKey, consultId: item.consultId
        )

        ConsultCaptureTelemetry.stage(
            .transferring, outcome: .ok, shotKey: item.shotKey, consultId: item.consultId
        )
        switch await (transfer ?? handToBackgroundSession)(request, bytes, item.id) {
        case .handedToSystem:
            refreshStages()
            return .startedTransfer
        case let .completed(status, error):
            return applyTransferResult(id: item.id, status: status, error: error)
        }
    }

    /// The real thing: give the file to the background session. From here the
    /// app can be backgrounded, suspended or killed and the upload continues.
    private func handToBackgroundSession(
        _ request: URLRequest, _ bytes: URL, _ id: UUID
    ) async -> TransferHandoff {
        let task = session.uploadTask(with: request, fromFile: bytes)
        task.taskDescription = id.uuidString
        task.resume()
        // Only in flight once the system actually has it: an id sitting in
        // `inFlight` with no task behind it halts the whole queue.
        inFlight.insert(id)
        return .handedToSystem
    }

    /// Called from the delegate when the system finishes a transfer — possibly
    /// in a process that never started it.
    ///
    /// 🔴 It only kicks the queue again when the transfer did NOT fail
    /// transiently. On a transient failure `handleTransient` has already armed
    /// the backoff, and draining here as well would re-issue and re-PUT the
    /// instant the failure came back — an offline phone would burn its battery
    /// hammering a dead connection at full speed instead of waiting out the
    /// backoff that exists for exactly this.
    fileprivate func transferFinished(id: UUID, status: Int?, error: Error?) async {
        guard applyTransferResult(id: id, status: status, error: error) != .retryLater else {
            return
        }
        await drain()
    }

    /// What a finished transfer MEANS. Shared by the background-session callback
    /// and by a substituted transfer that completed inline, so both take exactly
    /// the same decisions — and both learn whether the queue may move on.
    @discardableResult
    private func applyTransferResult(id: UUID, status: Int?, error: Error?) -> Step {
        inFlight.remove(id)
        guard var item = SessionByteVault.allConsultCaptures().first(where: { $0.id == id })
        else { return .continueDraining }

        if error != nil && status == nil {
            // Never reached storage — offline, TLS, a killed transfer. The bytes
            // are untouched on disk and the ticket is still PENDING, so the next
            // drain re-issues under the same key and sends them again.
            //
            // ⚠️ `.retryLater`, NOT `.continueDraining`. This shot is unchanged
            // and still first in the queue, so telling the loop to continue
            // makes it pick the same shot straight back up and try again with no
            // delay — a tight issue→PUT→fail spin for as long as the connection
            // is down. `.retryLater` stops the loop and leaves the next attempt
            // to the backoff `handleTransient` just armed.
            ConsultCaptureTelemetry.stage(
                .transferring, outcome: .retryLater, shotKey: item.shotKey,
                consultId: item.consultId, detail: "no_response"
            )
            handleTransient(ConsultClientFailure.unavailable)
            return .retryLater
        }

        // 🔴 Anything with an HTTP status REACHED storage, and the object may
        // now exist — including on a 409, which is exactly what a duplicate PUT
        // after a lost callback returns against `x-upsert: false`. Re-sending
        // would repeat that forever. Attach instead and let the server inspect
        // the object: it validates media type, byte count and checksum, and
        // says CAPTURE_OBJECT_INVALID if the bytes are not really there.
        item.bytesUploaded = true
        SessionByteVault.saveConsultCapture(item)
        ConsultCaptureTelemetry.stage(
            .uploaded,
            outcome: (200..<300).contains(status ?? 0) ? .ok : .retryLater,
            shotKey: item.shotKey,
            consultId: item.consultId,
            detail: status.map(String.init)
        )
        notifyStageCompleted(item.consultId)
        return .continueDraining
    }

    // MARK: - Leg 3: attach

    private func attach(
        _ item: Item, dependencies: Dependencies, rotated: inout Set<UUID>
    ) async -> Step {
        var item = item
        guard let uploadSessionId = item.uploadSessionId else {
            // Can't happen — `bytesUploaded` is only ever set after a ticket —
            // but a manifest is a file and files can be edited. Start over.
            item.bytesUploaded = false
            SessionByteVault.saveConsultCapture(item)
            return .continueDraining
        }
        do {
            let attached = try await dependencies.service.attachCapture(
                consultId: item.consultId,
                uploadSessionId: uploadSessionId,
                shotKey: item.shotKey,
                shotPackVersion: item.shotPackVersion,
                schemaVersion: item.schemaVersion,
                idempotencyKey: item.keys.attach
            )
            item.captureId = attached.captureId
            SessionByteVault.saveConsultCapture(item)
            ConsultCaptureTelemetry.stage(
                .attached, outcome: .ok, shotKey: item.shotKey, consultId: item.consultId
            )
            notifyStageCompleted(item.consultId)
            return .continueDraining
        } catch {
            if Self.isObjectInvalid(error) {
                guard mayRotate(item, rotated: &rotated) else {
                    return block(item, reason: ConsultClientFailure.invalidPhoto.message,
                                 stage: .attached, detail: "object_invalid_repeat")
                }
                // Storage does not have these bytes after all: the PUT that
                // "reached storage" wrote nothing usable. The photograph is
                // still on disk, so start the chain over on a clean session
                // rather than telling the client to retake something fine.
                item.keys = ConsultCaptureMutationKeys()
                item.uploadSessionId = nil
                item.storagePath = nil
                item.bytesUploaded = false
                SessionByteVault.saveConsultCapture(item)
                ConsultCaptureTelemetry.stage(
                    .attached, outcome: .rotated, shotKey: item.shotKey,
                    consultId: item.consultId, detail: "object_invalid"
                )
                return .continueDraining
            }
            return settle(error, on: item, stage: .attached)
        }
    }

    // MARK: - Leg 4: the quality verdict

    private func check(_ item: Item, captureId: String, dependencies: Dependencies) async -> Step {
        do {
            let response = try await dependencies.service.checkCaptureQuality(
                consultId: item.consultId,
                captureId: captureId,
                shotPackVersion: item.shotPackVersion,
                schemaVersion: item.schemaVersion,
                idempotencyKey: item.keys.quality
            )
            // Verdict in hand — accepted or not, the server is done with these
            // bytes and so are we. A rejected shot's reviewable copy is the
            // decoded thumbnail the flow already holds, not this file.
            SessionByteVault.removeConsultCapture(item.id)
            statusMessage = nil
            stalled = false
            retry.stop()
            ConsultCaptureTelemetry.stage(
                .checked,
                outcome: response.quality.accepted ? .accepted : .rejected,
                shotKey: item.shotKey,
                consultId: item.consultId
            )
            notifyStageCompleted(item.consultId)
            return .continueDraining
        } catch {
            return settle(error, on: item, stage: .checked)
        }
    }

    // MARK: - Failure handling

    /// Decide what one leg's error means: back off, or park the shot.
    private func settle(_ error: Error, on item: Item, stage: ConsultCaptureStage) -> Step {
        if Self.isRetryable(error) {
            ConsultCaptureTelemetry.stage(
                stage, outcome: .retryLater, shotKey: item.shotKey,
                consultId: item.consultId, detail: Self.detail(error)
            )
            handleTransient(error)
            return .retryLater
        }
        return block(
            item,
            reason: ConsultClientFailure.stable(error).message,
            stage: stage,
            detail: Self.detail(error)
        )
    }

    /// Park one shot as refused: keep its bytes, stop retrying, and say so.
    ///
    /// 🔴 Never deletes anything. A refusal is the one case where the server
    /// will not take these bytes, which makes this the only copy of a
    /// photograph the client actually took.
    private func block(
        _ item: Item, reason: String, stage: ConsultCaptureStage, detail: String?
    ) -> Step {
        var item = item
        item.blockedReason = reason
        SessionByteVault.saveConsultCapture(item)
        statusMessage = reason
        ConsultCaptureTelemetry.stage(
            .blocked, outcome: .refused, shotKey: item.shotKey,
            consultId: item.consultId, detail: detail ?? stage.rawValue
        )
        refreshStages()
        notifyStageCompleted(item.consultId)
        return .continueDraining
    }

    private func handleTransient(_ error: Error) {
        statusMessage = (error as? APIError)?.userMessage
            ?? (error as? ConsultClientFailure)?.message
            ?? "Still sending — waiting for a better connection."
        stalled = true
        refreshStages()
        ConsultCaptureTelemetry.queue("backoff in=\(retry.nextDelay)s", level: .warning)
        retry.scheduleRetry { [weak self] in
            guard let self else { return }
            await self.drain()
        }
    }

    /// Release shots the server can no longer accept.
    ///
    /// The raw-object TTL is 24h server-side; past that, attach and quality both
    /// refuse, so continuing to hold the client's photograph achieves nothing
    /// and storing a private image for no purpose is not neutral.
    private func sweepExpired() {
        let cutoff = Date().addingTimeInterval(-Self.maximumOwedAge)
        for item in SessionByteVault.allConsultCaptures() where item.capturedAt < cutoff {
            SessionByteVault.removeConsultCapture(item.id)
            ConsultCaptureTelemetry.stage(
                .released, outcome: .expired, shotKey: item.shotKey,
                consultId: item.consultId, detail: "raw_ttl"
            )
        }
    }

    private func notifyStageCompleted(_ consultId: String) {
        onStageCompleted?(consultId)
    }

    /// Recompute everything the capture screen renders from — one directory
    /// listing per change, rather than one per render.
    private func refreshStages() {
        var nextStages: [String: [ConsultCaptureShotKey: ConsultCaptureStage]] = [:]
        var nextReasons: [String: [ConsultCaptureShotKey: String]] = [:]
        var nextOwed: [String: Int] = [:]
        var nextBlocked: Set<String> = []
        for item in SessionByteVault.allConsultCaptures() {
            nextStages[item.consultId, default: [:]][item.shotKey] =
                Self.stage(of: item, inFlight: inFlight.contains(item.id))
            nextOwed[item.consultId, default: 0] += 1
            if let reason = item.blockedReason {
                nextReasons[item.consultId, default: [:]][item.shotKey] = reason
                nextBlocked.insert(item.consultId)
            }
        }
        stages = nextStages
        blockedReasons = nextReasons
        owedByConsult = nextOwed
        blockedConsults = nextBlocked
    }

    /// Where a manifest says this shot has got to. Derived, never persisted —
    /// a stored copy of something computable is a second source of truth that
    /// can only ever drift out of agreement with the first.
    private static func stage(of item: Item, inFlight: Bool) -> ConsultCaptureStage {
        if item.isBlocked { return .blocked }
        if item.captureId != nil { return .attached }
        if item.bytesUploaded { return .uploaded }
        if inFlight { return .transferring }
        if item.uploadSessionId != nil { return .ticketed }
        return .queued
    }

    // MARK: - Error classification

    /// 🔴 `APIError.isRetryable` is right about HTTP in general and wrong about
    /// exactly one code on this path: CONSULT_CAPTURE_QUALITY_LIMIT_EXCEEDED is
    /// served as a **429**, which that property calls transient. It is a hard
    /// per-consult cap on paid quality checks — retrying it can never win, and a
    /// queue that kept trying would spin against it until the raw TTL ran out.
    private static func isRetryable(_ error: Error) -> Bool {
        if code(error) == "CONSULT_CAPTURE_QUALITY_LIMIT_EXCEEDED" { return false }
        if let api = error as? APIError { return api.isRetryable }
        // A ConsultClientFailure raised locally (`.unavailable` from a failed
        // transport) is transient; the refusals are all shaped as APIErrors.
        return (error as? ConsultClientFailure) == .unavailable
    }

    private static func isUploadExpired(_ error: Error) -> Bool {
        code(error) == "CONSULT_CAPTURE_UPLOAD_EXPIRED"
    }

    private static func isObjectInvalid(_ error: Error) -> Bool {
        code(error) == "CONSULT_CAPTURE_OBJECT_INVALID"
    }

    private static func code(_ error: Error) -> String? {
        switch error as? APIError {
        case let .server(_, _, code), let .serverDetails(_, _, code, _): return code
        default: return nil
        }
    }

    /// A bounded, non-identifying label for the log — a server error code or a
    /// status, never a message lifted from a response body.
    private static func detail(_ error: Error) -> String? {
        if let code = code(error) { return code }
        switch error as? APIError {
        case let .server(status, _, _), let .serverDetails(status, _, _, _):
            return String(status)
        case .transport: return "transport"
        case .unauthorized: return "unauthorized"
        case .decoding: return "decoding"
        case .invalidResponse: return "invalid_response"
        case nil: return (error as? ConsultClientFailure).map { "\($0)" }
        }
    }

    /// Which item a system callback belongs to.
    ///
    /// `taskDescription` is set when we create the task, but a task resurrected
    /// into a NEW process after the app was killed is not guaranteed to carry
    /// it — so the storage path is recovered from the request URL and matched
    /// against the manifests, the same durable fallback `SessionUploadQueue`
    /// uses. The two identifying fields are read OFF the task by the caller,
    /// because a `URLSessionTask` is not Sendable and must not cross an actor
    /// hop.
    fileprivate static func itemID(described: String?, requestURL: URL?) -> UUID? {
        if let described, let id = UUID(uuidString: described) { return id }
        guard let requestURL,
              let path = SupabaseSignedUpload.storagePath(fromSignedUploadURL: requestURL)
        else { return nil }
        return SessionByteVault.allConsultCaptures()
            .first { $0.storagePath == path }?.id
    }

    fileprivate static func itemID(of task: URLSessionTask) -> UUID? {
        itemID(described: task.taskDescription, requestURL: task.originalRequest?.url)
    }

    /// Forwards the background session's callbacks onto the main actor.
    ///
    /// `owner` is `nonisolated(unsafe)` for the same reason
    /// `SessionUploadQueue.Delegate`'s is, and satisfies the same invariant: it
    /// is written ONCE in init before the delegate is handed to its session, and
    /// only ever read via `[weak owner]` from callbacks URLSession delivers on a
    /// single serial queue.
    private final class Delegate: NSObject, URLSessionDataDelegate {
        private nonisolated(unsafe) weak var owner: ConsultCaptureUploadQueue?

        init(owner: ConsultCaptureUploadQueue) {
            self.owner = owner
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
        ) {
            let status = (task.response as? HTTPURLResponse)?.statusCode
            let described = task.taskDescription
            let requestURL = task.originalRequest?.url
            Task { @MainActor [weak owner] in
                guard let owner,
                      let id = ConsultCaptureUploadQueue.itemID(
                          described: described, requestURL: requestURL
                      ) else { return }
                await owner.transferFinished(id: id, status: status, error: error)
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
