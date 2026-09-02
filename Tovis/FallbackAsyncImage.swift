// `AsyncImage` with a second URL to try when the first fails to load.
//
// The booking sheet's cover (and the add-ons / consult-review strips that carry
// it forward) is now the server's downscaled render of the look, served from
// Supabase's image-transformation endpoint — documented as a Pro-plan feature
// while this project is on Free. It works today; if it ever stops, every cover
// would fail at once. Falling back to the stored original turns a blank well
// into a slow one, which is where these surfaces were before the renders. The
// same reasoning as `LookFeedImage.fallbackURL`, for a surface that has no
// need of that view's decode-and-crop machinery.
//
// The SwiftUI twin of web's `useImageSrcWithFallback`.
import SwiftUI

struct FallbackAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL
    /// Tried ONLY if `url` fails. nil, or equal to `url`, means no fallback.
    let fallbackURL: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var primaryFailed = false

    private var activeURL: URL {
        guard primaryFailed, let fallbackURL, fallbackURL != url else { return url }
        return fallbackURL
    }

    var body: some View {
        // Changing the URL is what makes `AsyncImage` load again.
        AsyncImage(url: activeURL) { phase in
            switch phase {
            case .success(let image):
                content(image)
            case .failure:
                if !primaryFailed, let fallbackURL, fallbackURL != url {
                    // Flip once; a failure on the fallback lands in the branch
                    // below, so there is no loop.
                    placeholder().onAppear { primaryFailed = true }
                } else {
                    placeholder()
                }
            default:
                placeholder()
            }
        }
    }
}
