import Foundation
import Testing
@testable import TovisKit

// The background-upload request and the path it can be recognised by later.
//
// 🔴 Why these matter more than they look: a session photo's upload now runs on
// a BACKGROUND URLSession, which means the app can be suspended — or killed —
// between starting the transfer and hearing that it landed. When the system
// hands the completion back (possibly to a brand new process), the ONLY thing
// guaranteed to come with it is the task's original request. `storagePath` is
// how that request is matched back to the photo it belongs to; if it returns the
// wrong string, or nil, the upload succeeds and is never confirmed — the bytes
// sit in storage, no MediaAsset is ever written, and the photo is missing from
// the session exactly as if nothing had been fixed at all.
//
// And a background task with an in-memory body is rejected outright by
// URLSession, so `httpBody` being nil is not a detail either.
@Suite struct SupabaseSignedUploadTests {
    private let base = URL(string: "https://example.supabase.co")!
    private let bucket = "media-private"
    private let path = "bookings/bkg_123/after/2026/08/20/1787265806478_bed93e8.jpg"

    private func request() -> URLRequest? {
        SupabaseSignedUpload.backgroundUploadRequest(
            supabaseURL: base, supabaseKey: "publishable-key",
            bucket: bucket, path: path, token: "tok-abc", contentType: "image/jpeg"
        )
    }

    // MARK: - The request

    @Test func carriesNoBodyBecauseBackgroundTasksUploadFromAFile() throws {
        let request = try #require(request())
        #expect(request.httpBody == nil)
        #expect(request.httpBodyStream == nil)
    }

    @Test func isAPutWithTheApikeyAndNoAuthorizationBearer() throws {
        let request = try #require(request())
        // ⚠️ The signed token authorizes the write and bypasses RLS only on PUT;
        // a POST runs as anon and fails the media-private INSERT policy.
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "apikey") == "publishable-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        // Paths are minted unique per upload — an overwrite would be a bug.
        #expect(request.value(forHTTPHeaderField: "x-upsert") == "false")
        // The token is the sole authorizer; a bearer would break the exemption.
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func addressesTheSignedUploadEndpointWithTheToken() throws {
        let url = try #require(request()?.url)
        #expect(url.path == "/storage/v1/object/upload/sign/\(bucket)/\(path)")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.contains(URLQueryItem(name: "token", value: "tok-abc")) == true)
    }

    @Test func refusesToBuildWithoutStorageCredentials() {
        #expect(SupabaseSignedUpload.backgroundUploadRequest(
            supabaseURL: nil, supabaseKey: "k", bucket: bucket, path: path,
            token: "t", contentType: "image/jpeg") == nil)
        #expect(SupabaseSignedUpload.backgroundUploadRequest(
            supabaseURL: base, supabaseKey: nil, bucket: bucket, path: path,
            token: "t", contentType: "image/jpeg") == nil)
    }

    // MARK: - Recognising the request again, later, in another process

    @Test func recoversTheStoragePathFromItsOwnRequest() throws {
        let url = try #require(request()?.url)
        #expect(SupabaseSignedUpload.storagePath(fromSignedUploadURL: url) == path)
    }

    /// The practice namespace has a different shape and depth to a booking's —
    /// the bucket is stripped, everything after it is the path, however deep.
    @Test func recoversAPracticePathToo() throws {
        let practice = "pro/cmq9p645v0002/practice_private/2026-08/1787265772627_97d6f9.jpg"
        let url = try #require(SupabaseSignedUpload.backgroundUploadRequest(
            supabaseURL: base, supabaseKey: "k", bucket: bucket, path: practice,
            token: "t", contentType: "image/jpeg")?.url)
        #expect(SupabaseSignedUpload.storagePath(fromSignedUploadURL: url) == practice)
    }

    @Test func returnsNilForAnythingThatIsNotASignedUpload() {
        // A signed READ url, not an upload — matching it would confirm a photo
        // against a completely unrelated request.
        let read = URL(string: "https://example.supabase.co/storage/v1/object/sign/media-private/x.jpg")!
        #expect(SupabaseSignedUpload.storagePath(fromSignedUploadURL: read) == nil)
        #expect(SupabaseSignedUpload.storagePath(
            fromSignedUploadURL: URL(string: "https://example.com/")!) == nil)
        // Prefix present but no object path after the bucket.
        let bucketOnly = URL(string:
            "https://example.supabase.co/storage/v1/object/upload/sign/media-private")!
        #expect(SupabaseSignedUpload.storagePath(fromSignedUploadURL: bucketOnly) == nil)
    }
}
