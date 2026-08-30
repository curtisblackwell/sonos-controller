import Testing
import Foundation
@testable import SonosMenuBar

struct SpotifyAuthTests {
    @Test func verifierIsURLSafeAndDefaultLength() {
        let verifier = SpotifyAuth.randomVerifier()
        #expect(verifier.count == 64)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect(verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    @Test func verifiersAreNotConstant() {
        // Not proof of randomness, just that this isn't a hardcoded string.
        #expect(SpotifyAuth.randomVerifier() != SpotifyAuth.randomVerifier())
    }

    /// The challenge is SHA256(verifier), base64url with no padding - Spotify rejects `+`, `/`,
    /// and `=` in `code_challenge`.
    @Test func challengeIsBase64URLWithNoPadding() {
        let challenge = SpotifyAuth.codeChallenge(for: "test-verifier")
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))
        #expect(!challenge.contains("="))
        #expect(!challenge.isEmpty)
    }

    @Test func challengeIsDeterministicForTheSameVerifier() {
        #expect(SpotifyAuth.codeChallenge(for: "same") == SpotifyAuth.codeChallenge(for: "same"))
        #expect(SpotifyAuth.codeChallenge(for: "same") != SpotifyAuth.codeChallenge(for: "different"))
    }

    @Test func tokenNotYetExpiredIsValid() {
        let now: TimeInterval = 1_000_000
        #expect(!SpotifyAuth.isExpired(expiresAt: now + 3600, now: now))
    }

    @Test func tokenPastExpiryIsExpired() {
        let now: TimeInterval = 1_000_000
        #expect(SpotifyAuth.isExpired(expiresAt: now - 1, now: now))
    }

    /// A 60s cushion refreshes a token before it actually lapses, rather than handing out one
    /// that expires mid-request.
    @Test func tokenWithinCushionCountsAsExpired() {
        let now: TimeInterval = 1_000_000
        #expect(SpotifyAuth.isExpired(expiresAt: now + 30, now: now))
    }
}
