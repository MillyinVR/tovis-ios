// Looks video playback — a chromeless, auto-looping player for the full-screen
// Looks feed (TikTok/Reels style). Deliberately NOT `VideoPlayer` /
// `AVPlayerViewController`: those bring Apple's transport controls, which would
// look like a "player" bolted into the feed. Instead we host a bare
// `AVPlayerLayer` in a UIView, fill the slide edge-to-edge, loop seamlessly, and
// let the feed's own overlays (caption + action rail) sit on top.
//
// Only the ACTIVE slide plays — the feed passes `isActive` (driven by scroll
// position) so a single decoder runs at a time. Muted is shared across slides so
// an unmute sticks as the user scrolls; unmuting switches the audio session to
// playback so sound plays through the ringer switch (IG behavior).
import SwiftUI
import AVFoundation

struct LookVideoView: UIViewRepresentable {
    let url: URL
    let isActive: Bool
    let isMuted: Bool

    func makeUIView(context: Context) -> LoopingPlayerView {
        LoopingPlayerView()
    }

    func updateUIView(_ view: LoopingPlayerView, context: Context) {
        view.configure(url: url)
        view.setMuted(isMuted)
        view.setActive(isActive)
    }

    static func dismantleUIView(_ view: LoopingPlayerView, coordinator: ()) {
        view.teardown()
    }
}

/// A UIView whose backing layer IS an `AVPlayerLayer` (no extra layer to size).
/// Owns an `AVQueuePlayer` + `AVPlayerLooper` for gapless looping.
final class LoopingPlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?   // strong-held: it stops looping if released
    private var currentURL: URL?
    private var isActive = false

    /// (Re)load when the cell is bound to a new video (LazyVStack reuses views).
    func configure(url: URL) {
        guard url != currentURL else { return }
        currentURL = url

        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.actionAtItemEnd = .advance
        looper = AVPlayerLooper(player: queue, templateItem: item)

        playerLayer.player = queue
        playerLayer.videoGravity = .resizeAspectFill
        player = queue
    }

    func setMuted(_ muted: Bool) {
        player?.isMuted = muted
        if !muted { LookAudioSession.activatePlayback() }
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        guard let player else { return }
        if active {
            player.play()
        } else {
            player.pause()
            player.seek(to: .zero) // restart from the top next time it's shown
        }
    }

    func teardown() {
        player?.pause()
        playerLayer.player = nil
        looper = nil
        player = nil
        currentURL = nil
    }
}

/// Flips the shared audio session to playback the first time a video is unmuted,
/// so audio plays even with the ringer switch silenced (matches IG/TikTok).
enum LookAudioSession {
    private static var activated = false
    static func activatePlayback() {
        guard !activated else { return }
        activated = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}
