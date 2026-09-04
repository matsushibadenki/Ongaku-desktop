import Foundation

struct LRCLIBRecord: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let name: String?
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: TimeInterval
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?

    var hasUsableLyrics: Bool {
        instrumental
            || !(plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !(syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func trackLyrics(fetchedAt: Date = .now) -> TrackLyrics? {
        if let syncedLyrics,
           let parsed = try? LRCParser.parse(
               syncedLyrics,
               source: .lrclib,
               updatedAt: fetchedAt
           ) {
            var result = parsed
            result.sourceIdentifier = String(id)
            return result
        }
        if let plainLyrics {
            let text = plainLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return TrackLyrics(
                    plainText: text,
                    source: .lrclib,
                    sourceIdentifier: String(id),
                    updatedAt: fetchedAt
                )
            }
        }
        guard instrumental else { return nil }
        return TrackLyrics(
            plainText: "",
            source: .lrclib,
            sourceIdentifier: String(id),
            updatedAt: fetchedAt
        )
    }
}

struct LRCLIBCandidate: Identifiable, Equatable, Sendable {
    enum MatchKind: Equatable, Sendable {
        case exact
        case search
        case titleHint
        case albumHint
    }

    let record: LRCLIBRecord
    let confidence: Double
    let durationDifference: TimeInterval
    let matchKind: MatchKind

    var id: Int { record.id }
}

enum LRCLIBError: LocalizedError, Equatable {
    case invalidResponse
    case rateLimited
    case serviceUnavailable(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: L10n.text("lrclib.error.invalidResponse")
        case .rateLimited: L10n.text("lrclib.error.rateLimited")
        case .serviceUnavailable: L10n.text("lrclib.error.unavailable")
        }
    }
}

actor LRCLIBService {
    static let shared = LRCLIBService()

    private static let baseURL = URL(string: "https://lrclib.net/api")!
    private static let requestSpacing = Duration.milliseconds(350)
    private static let maximumCandidates = 20
    private static var clientIdentifier: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.2"
        return "Ongaku Desktop/\(version) (https://github.com/matsushibadenki/Ongaku-desktop)"
    }

    private let session: URLSession
    private let clock = ContinuousClock()
    private var nextRequestAt: ContinuousClock.Instant?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 25
            configuration.httpAdditionalHeaders = [
                "User-Agent": Self.clientIdentifier,
                "Lrclib-Client": Self.clientIdentifier,
                "Accept": "application/json"
            ]
            self.session = URLSession(configuration: configuration)
        }
    }

    func candidates(for track: Track) async throws -> [LRCLIBCandidate] {
        var candidatesByID: [Int: LRCLIBCandidate] = [:]
        if let exact = try await exactMatch(for: track), exact.hasUsableLyrics {
            candidatesByID[exact.id] = LRCLIBCandidate(
                record: exact,
                confidence: 1,
                durationDifference: abs(exact.duration - track.duration),
                matchKind: .exact
            )
        }

        for record in try await search(track: track) where record.hasUsableLyrics {
            let candidate = Self.evaluate(record, against: track, matchKind: .search)
            if let existing = candidatesByID[record.id], existing.confidence >= candidate.confidence {
                continue
            }
            candidatesByID[record.id] = candidate
        }

        if candidatesByID.isEmpty {
            let fallbackSearches: [(URL, LRCLIBCandidate.MatchKind)] = [
                (Self.titleOnlySearchURL(for: track), .titleHint),
                (Self.albumOnlySearchURL(for: track), .albumHint)
            ]
            for (url, matchKind) in fallbackSearches {
                for record in try await search(url: url) where record.hasUsableLyrics {
                    let candidate = Self.evaluate(record, against: track, matchKind: matchKind)
                    guard Self.isUsefulFallback(candidate, for: track) else { continue }
                    if let existing = candidatesByID[record.id],
                       existing.confidence >= candidate.confidence {
                        continue
                    }
                    candidatesByID[record.id] = candidate
                }
            }
        }

        return candidatesByID.values.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            if $0.durationDifference != $1.durationDifference {
                return $0.durationDifference < $1.durationDifference
            }
            return $0.record.id < $1.record.id
        }
        .prefix(Self.maximumCandidates)
        .map { $0 }
    }

    nonisolated static func evaluate(
        _ record: LRCLIBRecord,
        against track: Track,
        matchKind: LRCLIBCandidate.MatchKind = .search
    ) -> LRCLIBCandidate {
        let titleScore = similarity(record.trackName, track.title)
        let artistScore = similarity(record.artistName, track.artist)
        let albumScore = similarity(record.albumName, track.album)
        let durationDifference = abs(record.duration - track.duration)
        let durationScore = max(0, 1 - durationDifference / 12)
        let confidence = min(
            1,
            titleScore * 0.38 + artistScore * 0.32 + albumScore * 0.12
                + durationScore * 0.18
        )
        return LRCLIBCandidate(
            record: record,
            confidence: confidence,
            durationDifference: durationDifference,
            matchKind: matchKind
        )
    }

    nonisolated static func exactMatchURL(for track: Track) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("get"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "album_name", value: track.album),
            URLQueryItem(name: "duration", value: String(Int(track.duration.rounded())))
        ]
        return components.url!
    }

    nonisolated static func searchURL(for track: Track) -> URL {
        searchURL(queryItems: [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album)
        ])
    }

    nonisolated static func titleOnlySearchURL(for track: Track) -> URL {
        searchURL(queryItems: [URLQueryItem(name: "track_name", value: track.title)])
    }

    nonisolated static func albumOnlySearchURL(for track: Track) -> URL {
        searchURL(queryItems: [URLQueryItem(name: "album_name", value: track.album)])
    }

    nonisolated private static func searchURL(queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = queryItems
        return components.url!
    }

    private func exactMatch(for track: Track) async throws -> LRCLIBRecord? {
        let (data, response) = try await request(Self.exactMatchURL(for: track))
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else {
            throw LRCLIBError.serviceUnavailable(response.statusCode)
        }
        do { return try JSONDecoder().decode(LRCLIBRecord.self, from: data) }
        catch { throw LRCLIBError.invalidResponse }
    }

    private func search(track: Track) async throws -> [LRCLIBRecord] {
        try await search(url: Self.searchURL(for: track))
    }

    private func search(url: URL) async throws -> [LRCLIBRecord] {
        let (data, response) = try await request(url)
        guard response.statusCode == 200 else {
            throw LRCLIBError.serviceUnavailable(response.statusCode)
        }
        do { return try JSONDecoder().decode([LRCLIBRecord].self, from: data) }
        catch { throw LRCLIBError.invalidResponse }
    }

    nonisolated static func isUsefulFallback(
        _ candidate: LRCLIBCandidate,
        for track: Track
    ) -> Bool {
        switch candidate.matchKind {
        case .titleHint:
            similarity(candidate.record.trackName, track.title) >= 0.55
        case .albumHint:
            similarity(candidate.record.albumName, track.album) >= 0.55
        case .exact, .search:
            true
        }
    }

    private func request(_ url: URL, retryingAfterRateLimit: Bool = true) async throws
        -> (Data, HTTPURLResponse) {
        try await waitForRequestSlot()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LRCLIBError.invalidResponse
        }
        nextRequestAt = clock.now.advanced(by: Self.requestSpacing)

        if httpResponse.statusCode == 429 {
            let delay = retryDelay(from: httpResponse) ?? 1
            nextRequestAt = clock.now.advanced(by: .seconds(delay))
            guard retryingAfterRateLimit else { throw LRCLIBError.rateLimited }
            try await waitForRequestSlot()
            return try await self.request(url, retryingAfterRateLimit: false)
        }
        return (data, httpResponse)
    }

    private func waitForRequestSlot() async throws {
        guard let nextRequestAt, nextRequestAt > clock.now else { return }
        try await clock.sleep(until: nextRequestAt)
    }

    private func retryDelay(from response: HTTPURLResponse) -> Double? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }

    private nonisolated static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let normalizedLHS = CatalogSearch.normalize(lhs)
        let normalizedRHS = CatalogSearch.normalize(rhs)
        let lhs = normalizedLHS
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        let rhs = normalizedRHS
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        guard !lhs.isEmpty, !rhs.isEmpty else { return lhs == rhs ? 1 : 0 }
        if lhs == rhs { return 1 }
        if lhs.contains(rhs) || rhs.contains(lhs) {
            return Double(min(lhs.count, rhs.count)) / Double(max(lhs.count, rhs.count))
        }
        let lhsTokens = Set(
            normalizedLHS.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        let rhsTokens = Set(
            normalizedRHS.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        let union = lhsTokens.union(rhsTokens)
        guard !union.isEmpty else { return 0 }
        return Double(lhsTokens.intersection(rhsTokens).count) / Double(union.count)
    }
}
