// Frame-by-frame review of a recorded session clip. The pro scrubs the video
// and can pull the exact best frame out as a still. The clip ITSELF is already
// saving — recording auto-uploads on stop (ClipVault owns the file); this
// screen is an optional extra, and closing it never discards anything.
// (Part of the "Session Reel" — B3a.)
import AVFoundation
import SwiftUI
import TovisKit

struct FrameScrubberView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let videoURL: URL
    let bookingId: String
    let phase: MediaPhase
    /// Card-solved color correction — baked into an extracted still at upload
    /// (the clip's own upload bakes it into the video separately). Nil = no
    /// card scanned.
    var correction: ColorMatrix3x3? = nil

    @State private var duration: Double = 0
    @State private var position: Double = 0           // seconds
    @State private var frame: UIImage?
    @State private var generator: AVAssetImageGenerator?
    @State private var previewTask: Task<Void, Never>?
    @State private var working = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                preview

                if duration > 0 {
                    VStack(spacing: 6) {
                        Slider(value: $position, in: 0...duration)
                            .tint(BrandColor.accent)
                            .onChange(of: position) { schedulePreview() }
                        Text(timecode)
                            .font(BrandFont.mono(11))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                    frameStepper
                }

                if let message {
                    Text(message).font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                }

                actions
            }
            .padding(20)
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Pick the best frame")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.tint(BrandColor.textSecondary)
                }
            }
        }
        .tint(BrandColor.accent)
        .task { await loadAsset() }
    }

    private var preview: some View {
        ZStack {
            BrandColor.bgSecondary
            if let frame {
                Image(uiImage: frame).resizable().scaledToFit()
            } else {
                ProgressView().tint(BrandColor.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 380)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Nudge one frame at a time (assumes ~30 fps).
    private var frameStepper: some View {
        HStack(spacing: 24) {
            Button { step(-1) } label: { Image(systemName: "backward.frame.fill") }
            Button { step(1) } label: { Image(systemName: "forward.frame.fill") }
        }
        .font(.system(size: 22))
        .foregroundStyle(BrandColor.accent)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button { Task { await extractFrame() } } label: {
                label("Use this frame", system: "photo.badge.plus", filled: true)
            }
            .disabled(working || frame == nil)

            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                Text("The whole clip is saving to your session media.")
            }
            .font(BrandFont.body(12))
            .foregroundStyle(BrandColor.textMuted)

            if working { ProgressView().tint(BrandColor.accent) }
        }
    }

    private func label(_ text: String, system: String, filled: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: system)
            Text(text).font(BrandFont.body(16, .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .foregroundStyle(filled ? BrandColor.onAccent : BrandColor.accent)
        .background(filled ? BrandColor.accent : .clear)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(filled ? .clear : BrandColor.accent.opacity(0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Asset + scrubbing

    private func loadAsset() async {
        let asset = AVURLAsset(url: videoURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        generator = gen
        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite {
            duration = seconds
        }
        await renderFrame(at: 0)
    }

    private func step(_ frames: Int) {
        let delta = Double(frames) / 30.0
        position = min(max(position + delta, 0), duration)
        schedulePreview()
    }

    private func schedulePreview() {
        previewTask?.cancel()
        let target = position
        previewTask = Task { await renderFrame(at: target) }
    }

    private func renderFrame(at seconds: Double) async {
        guard let generator else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        if let result = try? await generator.image(at: time), !Task.isCancelled {
            frame = UIImage(cgImage: result.image)
        }
    }

    private var timecode: String {
        String(format: "%.2fs / %.2fs", position, duration)
    }

    // MARK: - Save

    private func extractFrame() async {
        guard let frame, let data = frame.jpegData(compressionQuality: 0.9) else { return }
        working = true; message = nil
        defer { working = false }
        // Subject focal for the smart 9:16 feed crop (camera C6). The extracted
        // frame is already upright (the generator applies the preferred track
        // transform), so PhotoQC's EXIF-corrected face rect maps directly onto the
        // render. checkBlink:false — we only want the focal, not a QC verdict.
        let focal = MediaFocalPoint(
            faceCenter: await PhotoQC.evaluate(data, checkBlink: false).focalPoint)
        var payload = data
        if let correction, let corrected = await CardCorrection.apply(correction, to: data) {
            payload = corrected
        }
        do {
            try await session.client.proMedia.uploadSessionPhoto(
                bookingId: bookingId, phase: phase, imageData: payload, focal: focal
            )
            session.signalRefresh()
            message = "Saved that frame."
            dismiss()
        } catch let error as APIError {
            message = error.userMessage
        } catch {
            message = "Couldn’t save that frame."
        }
    }

}
