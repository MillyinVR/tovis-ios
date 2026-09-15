import Foundation
import Testing
import UIKit

@testable import Tovis

@Suite("Inline JPEG reference transport")
struct ImageDownsampleDataURLTests {
    @MainActor
    @Test func urlSessionLoadsSyntheticJPEGDataURL() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80))
        let source = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        let jpeg = try #require(source.jpegData(compressionQuality: 0.8))
        let url = try #require(URL(string: "data:image/jpeg;base64,\(jpeg.base64EncodedString())"))
        let (received, _) = try await URLSession.shared.data(from: url)
        #expect(received == jpeg)
        let thumbnail = try #require(await ImageDownsample.thumbnail(from: received, maxPixel: 60))
        #expect(max(thumbnail.size.width, thumbnail.size.height) <= 60)

        // Cropped cards share this canonical reference store. Exercise its real
        // URLSession + decode path, rather than substituting image bytes for it.
        let reference = try #require(await ConsultInspirationReferenceStore().image(for: url))
        #expect(reference.cgImage != nil)
        let fullscreen = try #require(FullscreenMedia.remote(
            id: "synthetic-reference", urlString: url.absoluteString, isVideo: false
        ))
        guard case let .remote(fullscreenURL, isVideo) = fullscreen.source else {
            Issue.record("The JPEG reference did not remain an image URL")
            return
        }
        #expect(!isVideo)
        #expect(fullscreenURL == url)
        // ZoomableRemoteImage performs this exact transport and bounded decode.
        let (fullBytes, _) = try await URLSession.shared.data(from: fullscreenURL)
        #expect(fullBytes == jpeg)
        #expect(await ImageDownsample.thumbnail(from: fullBytes, maxPixel: ImageDownsample.screenMaxPixel) != nil)
    }
}
