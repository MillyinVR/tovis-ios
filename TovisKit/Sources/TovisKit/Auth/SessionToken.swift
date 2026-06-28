import Foundation

/// Read-only helpers for the session JWT we already store in the Keychain.
///
/// The backend signs a `userId` claim into the token (see lib/auth.ts). Decoding
/// it locally lets the app know its live-sync channel (`user:{userId}`) even on a
/// cold launch from a stored token — no extra network call or endpoint.
///
/// NOTE: this does NOT verify the signature (the server does that on every
/// request). It's only used to read a non-sensitive claim for channel routing.
public enum SessionToken {
    public static func userId(from token: String) -> String? {
        claim("userId", from: token)
    }

    static func claim(_ name: String, from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }

        guard
            let data = Data(base64Encoded: base64),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json[name] as? String
    }
}