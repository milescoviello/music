import Foundation

/// The spans Plexamp's charts ("Aural Fixations") come in.
enum ChartSpan: String, CaseIterable, Codable, Identifiable, Sendable {
    case week, month, season, year, decade, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "Week"
        case .month: return "Month"
        case .season: return "Season"
        case .year: return "Year"
        case .decade: return "Decade"
        case .all: return "All Time"
        }
    }

    /// Plexamp's rule: a period less than this far through (percent) is too young to chart,
    /// so the one before it is shown instead — on the 2nd of the month, last month's chart
    /// says more than two days of this one.
    var minimumProgress: Double? {
        switch self {
        case .week: return 15
        case .month: return 20
        case .season, .year: return 8
        case .decade: return 10
        case .all: return nil
        }
    }
}

enum Hemisphere: String, CaseIterable, Codable, Sendable {
    case north, south
}

/// One chart period: a week, a month, a meteorological season, a year, a decade, or all
/// of it. Foundation-only, so the edges are tested rather than trusted.
struct ChartPeriod: Equatable, Sendable {
    let span: ChartSpan
    let start: Date
    let end: Date

    /// The period to open on: the current one, or the one before if the current is
    /// younger than Plexamp's threshold.
    static func current(_ span: ChartSpan, now: Date = .now, calendar: Calendar = .current) -> ChartPeriod {
        let containing = period(span, containing: now, calendar: calendar)
        guard let minimum = span.minimumProgress else { return containing }
        let length = containing.end.timeIntervalSince(containing.start)
        let progress = now.timeIntervalSince(containing.start) / length * 100
        return progress < minimum ? containing.offset(by: -1, calendar: calendar) : containing
    }

    /// The period `count` steps before (negative) or after this one.
    func offset(by count: Int, calendar: Calendar = .current) -> ChartPeriod {
        guard span != .all, count != 0 else { return self }
        let (component, step) = Self.step(for: span)
        guard let moved = calendar.date(byAdding: component, value: step * count, to: start) else { return self }
        return Self.period(span, containing: moved, calendar: calendar)
    }

    func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    /// Whether a later period exists yet.
    func hasNext(now: Date = .now) -> Bool {
        span != .all && end <= now
    }

    func title(hemisphere: Hemisphere = .north, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let year = calendar.component(.year, from: start)

        switch span {
        case .week:
            formatter.dateStyle = .medium
            let last = calendar.date(byAdding: .day, value: -1, to: end) ?? end
            return "\(formatter.string(from: start)) – \(formatter.string(from: last))"
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
            return formatter.string(from: start)
        case .season:
            return "\(Self.seasonName(startMonth: calendar.component(.month, from: start), hemisphere: hemisphere)) \(year)"
        case .year:
            return String(year)
        case .decade:
            return "\(year)s"
        case .all:
            return "All Time"
        }
    }

    // MARK: - Edges

    private static func step(for span: ChartSpan) -> (Calendar.Component, Int) {
        switch span {
        case .week: return (.weekOfYear, 1)
        case .month: return (.month, 1)
        case .season: return (.month, 3)
        case .year: return (.year, 1)
        case .decade: return (.year, 10)
        case .all: return (.year, 0)
        }
    }

    private static func period(_ span: ChartSpan, containing date: Date, calendar: Calendar) -> ChartPeriod {
        switch span {
        case .week:
            // ISO weeks, Monday to Sunday, whatever the locale's first weekday: Plexamp's.
            var iso = Calendar(identifier: .iso8601)
            iso.timeZone = calendar.timeZone
            let interval = iso.dateInterval(of: .weekOfYear, for: date)!
            return ChartPeriod(span: span, start: interval.start, end: interval.end)

        case .month:
            let interval = calendar.dateInterval(of: .month, for: date)!
            return ChartPeriod(span: span, start: interval.start, end: interval.end)

        case .season:
            // Meteorological seasons: December, March, June, September.
            let parts = calendar.dateComponents([.year, .month], from: date)
            let month = parts.month!, year = parts.year!
            let (startYear, startMonth): (Int, Int)
            switch month {
            case 12: (startYear, startMonth) = (year, 12)
            case 1, 2: (startYear, startMonth) = (year - 1, 12)
            case 3...5: (startYear, startMonth) = (year, 3)
            case 6...8: (startYear, startMonth) = (year, 6)
            default: (startYear, startMonth) = (year, 9)
            }
            let start = calendar.date(from: DateComponents(year: startYear, month: startMonth, day: 1))!
            let end = calendar.date(byAdding: .month, value: 3, to: start)!
            return ChartPeriod(span: span, start: start, end: end)

        case .year:
            let interval = calendar.dateInterval(of: .year, for: date)!
            return ChartPeriod(span: span, start: interval.start, end: interval.end)

        case .decade:
            let year = calendar.component(.year, from: date)
            let first = year - year % 10
            let start = calendar.date(from: DateComponents(year: first, month: 1, day: 1))!
            let end = calendar.date(from: DateComponents(year: first + 10, month: 1, day: 1))!
            return ChartPeriod(span: span, start: start, end: end)

        case .all:
            return ChartPeriod(span: span, start: .distantPast, end: .distantFuture)
        }
    }

    /// Plexamp's names, flipped south of the equator.
    static func seasonName(startMonth: Int, hemisphere: Hemisphere) -> String {
        let north = hemisphere == .north
        switch startMonth {
        case 3: return north ? "Spring" : "Fall"
        case 6: return north ? "Summer" : "Winter"
        case 9: return north ? "Fall" : "Spring"
        default: return north ? "Winter" : "Summer"
        }
    }
}

/// One play, as the charts need it.
struct ChartPlay: Sendable {
    let songID: String
    let title: String
    let artist: String
    let album: String
    var albumID: String?
    var artistID: String?
    var coverArt: String?
    let at: Date
}

/// A charted track, album or artist: what it is, how many plays, and enough to open it.
struct ChartRow: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let plays: Int
    var songID: String?
    var albumID: String?
    var artistID: String?
    var coverArt: String?
}

enum Charts {
    /// Plexamp's choices for how long a chart is.
    static let limits = [10, 25, 50, 100]

    static func topTracks(_ plays: [ChartPlay], in period: ChartPeriod, limit: Int) -> [ChartRow] {
        rank(plays, in: period, limit: limit, key: \.songID) { play in
            ChartRow(id: play.songID, title: play.title, subtitle: play.artist, plays: 0,
                     songID: play.songID, albumID: play.albumID, artistID: play.artistID, coverArt: play.coverArt)
        }
    }

    static func topAlbums(_ plays: [ChartPlay], in period: ChartPeriod, limit: Int) -> [ChartRow] {
        rank(plays, in: period, limit: limit, key: { $0.albumID ?? "\($0.album)\u{1F}\($0.artist)" }) { play in
            ChartRow(id: play.albumID ?? play.album, title: play.album, subtitle: play.artist, plays: 0,
                     albumID: play.albumID, artistID: play.artistID, coverArt: play.coverArt)
        }
    }

    static func topArtists(_ plays: [ChartPlay], in period: ChartPeriod, limit: Int) -> [ChartRow] {
        rank(plays, in: period, limit: limit, key: { $0.artistID ?? $0.artist }) { play in
            ChartRow(id: play.artistID ?? play.artist, title: play.artist, subtitle: nil, plays: 0,
                     artistID: play.artistID, coverArt: play.coverArt)
        }
    }

    /// Counts by key within the period. The row is built from the most recent play of
    /// each, so a renamed album or newer artwork wins. Ties go to whoever got there last.
    private static func rank(
        _ plays: [ChartPlay],
        in period: ChartPeriod,
        limit: Int,
        key: (ChartPlay) -> String,
        row: (ChartPlay) -> ChartRow
    ) -> [ChartRow] {
        var counts: [String: (count: Int, latest: ChartPlay)] = [:]
        for play in plays where period.contains(play.at) {
            let name = key(play)
            guard !name.isEmpty else { continue }
            if let existing = counts[name] {
                counts[name] = (existing.count + 1, play.at > existing.latest.at ? play : existing.latest)
            } else {
                counts[name] = (1, play)
            }
        }

        return counts.values
            .sorted { $0.count == $1.count ? $0.latest.at > $1.latest.at : $0.count > $1.count }
            .prefix(limit)
            .map { entry in
                let base = row(entry.latest)
                return ChartRow(id: base.id, title: base.title, subtitle: base.subtitle, plays: entry.count,
                                songID: base.songID, albumID: base.albumID, artistID: base.artistID, coverArt: base.coverArt)
            }
    }
}
