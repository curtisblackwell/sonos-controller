import Testing
@testable import SonosMenuBar

struct SpotifyReleaseDateTests {
    @Test func fullDateGetsYearMonthNameOrdinalDay() {
        #expect(SpotifyReleaseDate.formatted("2026-08-29") == "2026 August 29th")
    }

    @Test func monthPrecisionGetsMonthNameThenYear() {
        #expect(SpotifyReleaseDate.formatted("2026-08") == "August 2026")
    }

    @Test func yearPrecisionIsUnchanged() {
        #expect(SpotifyReleaseDate.formatted("2026") == "2026")
    }

    @Test func ordinalSuffixesFollowEnglishRules() {
        #expect(SpotifyReleaseDate.formatted("2026-01-01") == "2026 January 1st")
        #expect(SpotifyReleaseDate.formatted("2026-01-02") == "2026 January 2nd")
        #expect(SpotifyReleaseDate.formatted("2026-01-03") == "2026 January 3rd")
        #expect(SpotifyReleaseDate.formatted("2026-01-04") == "2026 January 4th")
        // The 11th-13th exception to the 1st/2nd/3rd pattern.
        #expect(SpotifyReleaseDate.formatted("2026-01-11") == "2026 January 11th")
        #expect(SpotifyReleaseDate.formatted("2026-01-12") == "2026 January 12th")
        #expect(SpotifyReleaseDate.formatted("2026-01-13") == "2026 January 13th")
        #expect(SpotifyReleaseDate.formatted("2026-01-21") == "2026 January 21st")
    }

    @Test func garbageIsReturnedUnchanged() {
        #expect(SpotifyReleaseDate.formatted("") == "")
        #expect(SpotifyReleaseDate.formatted("2026-13-01") == "2026")
    }
}
