import Foundation
import Testing
@testable import TovisKit

// MediaHash.sha256Hex must match the server's `createHash('sha256').digest('hex')`
// byte-for-byte — verified here against known SHA-256 test vectors, not just
// "produces 64 hex characters".
@Suite struct MediaHashTests {
    @Test func hashesEmptyDataToTheKnownVector() {
        #expect(
            MediaHash.sha256Hex(Data())
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    @Test func hashesAbcToTheKnownVector() {
        #expect(
            MediaHash.sha256Hex(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test func isDeterministicForTheSameBytes() {
        let data = Data((0..<200).map { UInt8($0 % 256) })
        #expect(MediaHash.sha256Hex(data) == MediaHash.sha256Hex(data))
    }

    @Test func differsForDifferentBytes() {
        #expect(MediaHash.sha256Hex(Data("a".utf8)) != MediaHash.sha256Hex(Data("b".utf8)))
    }

    @Test func isLowercaseHexOfTheRightLength() {
        let hash = MediaHash.sha256Hex(Data("tovis".utf8))
        #expect(hash.count == 64)
        #expect(hash == hash.lowercased())
        #expect(hash.allSatisfy { $0.isHexDigit })
    }
}
