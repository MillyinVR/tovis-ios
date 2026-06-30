// SwiftUI wrapper for the AVFoundation live preview layer. Phase B will draw the
// coaching overlays (readiness ring, pose template, onion-skin) on top of this.
import AVFoundation
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// Handed the backing preview layer once, so the controller can convert
    /// tap-to-focus points from layer space to device space.
    var onLayer: ((AVCaptureVideoPreviewLayer) -> Void)? = nil

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        onLayer?(view.videoPreviewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    /// A UIView whose backing layer IS the preview layer (no manual frame sync).
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            // Safe: layerClass guarantees this layer type.
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
