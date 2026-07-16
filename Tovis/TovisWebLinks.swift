// The canonical web pages the app links out to.
//
// Deliberately pinned to production rather than derived from `TovisConfig`:
// these are legal/brand pages whose canonical text only exists on the marketing
// host, so a local/staging build should still show the real Terms. (Config's
// `baseURL` is the API root — `…/api/v1` — and isn't the web root anyway.)
import Foundation

enum TovisWebLinks {
    private static let host = "https://www.tovis.app"

    static let terms = URL(string: "\(host)/terms")!
    static let privacy = URL(string: "\(host)/privacy")!
}
