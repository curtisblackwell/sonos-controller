import Foundation

/// Formats an album's `release_date` for display. Spotify gives the date at one of three
/// precisions - year, year-month, or a full date - and doesn't send the precision alongside it
/// here (see `SpotifyModels.Album.release_date`), so the string's own length is what's read to
/// tell them apart.
enum SpotifyReleaseDate {
    /// `"2026"` stays `"2026"`, `"2026-08"` becomes `"August 2026"`, and `"2026-08-29"` becomes
    /// `"2026 August 29th"`. Anything that doesn't parse is returned unchanged rather than
    /// hidden, since a raw date still reads better than nothing.
    static func formatted(_ raw: String) -> String {
        let parts = raw.split(separator: "-").map(String.init)
        guard let year = parts.first else { return raw }
        guard parts.count >= 2, let month = Int(parts[1]), (1...12).contains(month) else { return year }
        let monthName = Calendar.current.monthSymbols[month - 1]
        guard parts.count >= 3, let day = Int(parts[2]), day >= 1 else { return "\(monthName) \(year)" }
        return "\(year) \(monthName) \(ordinal(day))"
    }

    /// A zero-padded `"YYYY-MM-DD"` key so two release dates at different precisions
    /// (`"2026"` vs `"2026-03"`) still compare correctly by string order.
    static func sortKey(_ raw: String) -> String {
        let parts = raw.split(separator: "-").map(String.init)
        let year = parts.first ?? "0000"
        let month = parts.count >= 2 ? parts[1] : "01"
        let day = parts.count >= 3 ? parts[2] : "01"
        return "\(year)-\(month)-\(day)"
    }

    private static func ordinal(_ day: Int) -> String {
        switch (day % 10, day % 100) {
        case (1, let hundreds) where hundreds != 11: return "\(day)st"
        case (2, let hundreds) where hundreds != 12: return "\(day)nd"
        case (3, let hundreds) where hundreds != 13: return "\(day)rd"
        default: return "\(day)th"
        }
    }
}
