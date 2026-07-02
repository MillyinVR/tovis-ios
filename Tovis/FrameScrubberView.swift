// Frame-by-frame review of a recorded session clip. The pro scrubs the video,
// picks the exact best frame, and extracts it as a still — or saves the whole
// clip. Both land in the same session media as the before/after photos.
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
    /// (the saved VIDEO clip stays uncorrected — video correction is a
    /// different pipeline). Nil = no card scanned.
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
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
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

            Button { Task { await saveVideo() } } label: {
                label("Save the whole clip", system: "video.badge.plus", filled: false)
            }
            .disabled(working)

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
        var payload = data
        if let correction, let corrected = await CardCorrection.apply(correction, to: data) {
            payload = corrected
        }
        do {
            try await session.client.proMedia.uploadSessionPhoto(
                bookingId: bookingId, phase: phase, imageData: payload
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

    private func saveVideo() async {
        working = true; message = nil
        defer { working = false }
        do {
            try await session.client.proMedia.uploadSessionVideo(
                bookingId: bookingId, phase: phase, fileURL: videoURL
            )
            session.signalRefresh()
            message = "Saved the clip."
            dismiss()
        } catch let error as APIError {
            message = error.userMessage
        } catch {
            message = "Couldn’t save the clip."
        }
    }
}
