import Foundation

/// A part of a conversation that search can rank and be limited to, in priority order.
enum TranscriptField: String, CaseIterable, Identifiable, Sendable {
    case title, user, assistant, toolCall, toolOutput

    var id: String { rawValue }

    /// How much one hit counts. A rare phrase in a low field still outranks a common
    /// word in a high one, because every hit is first scored by how rare its words are.
    /// Settings → Search scales it by Less, Normal or More.
    var weight: Double {
        let base: Double
        switch self {
        case .title: base = 4
        case .user: base = 3
        case .assistant: base = 2
        case .toolCall: base = 1
        case .toolOutput: base = 0.6
        }
        return base * SearchPreferences.weightFactor(self)
    }

    /// Index table holding this field. Titles are matched in memory instead, so a
    /// renamed chat is found under its new name without reindexing.
    var table: String? {
        switch self {
        case .title: return nil
        case .user: return "field_user"
        case .assistant: return "field_assistant"
        case .toolCall: return "field_tool_call"
        case .toolOutput: return "field_tool_output"
        }
    }

    /// Tool text is indexed in full but not stored, which keeps the index small.
    /// Its excerpts are read from the transcript itself.
    var storesText: Bool { self == .user || self == .assistant }

    var label: String {
        switch self {
        case .title: return String(localized: "Title", comment: "Search field name: the session title.")
        case .user: return String(localized: "My prompts", comment: "Search field name: text the user typed.")
        case .assistant: return String(localized: "Replies", comment: "Search field name: assistant replies.")
        case .toolCall: return String(localized: "Tool calls", comment: "Search field name: tool call inputs.")
        case .toolOutput: return String(localized: "Tool output", comment: "Search field name: tool call results.")
        }
    }
}

/// Why a session is in the search results: the field that matched best and the passage.
struct SearchHit: Equatable, Sendable {
    /// Wrap each matched word inside an excerpt.
    static let markStart: Character = "\u{1}"
    static let markEnd: Character = "\u{2}"

    let field: TranscriptField
    var excerpt: String?
    /// For a chat stored as several files: which one matched (1-based) and how many there are.
    var part: Int? = nil
    var partCount: Int? = nil
    /// Other fields of the same chat that match too, in priority order.
    var also: [TranscriptField] = []
    /// The passage comes from one of the chat's sub-agents, folded into this row.
    var inSubagent = false

    /// The passage around the first match of query in text, with the match marked.
    static func excerpt(in text: String, query: String) -> String? {
        guard let match = SearchTextMatcher.matchRanges(in: text, query: query).first,
              let range = Range(match, in: text) else { return nil }
        let before = text[..<range.lowerBound].suffix(80)
        let after = text[range.upperBound...].prefix(160)
        let marked = "\(before)\(markStart)\(text[range])\(markEnd)\(after)"
        return focused(marked.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }

    /// Cuts the lead-in to a few words so the match stays visible in a narrow row.
    static func focused(_ excerpt: String) -> String {
        guard let mark = excerpt.firstIndex(of: markStart) else { return excerpt }
        let lead = excerpt[..<mark]
        guard lead.count > 32 else { return excerpt }
        let kept = lead.suffix(32)
        let words = kept.firstIndex(of: " ").map { kept[kept.index(after: $0)...] } ?? kept
        return "…" + words + excerpt[mark...]
    }

    /// The passage as plain text: Markdown marks and table pipes, which only add noise in
    /// a one- or two-line preview, are dropped. Match marks are kept.
    static func plain(_ excerpt: String) -> String {
        var out = excerpt.replacingOccurrences(of: "**", with: "")
        out.removeAll { $0 == "`" }
        out = out.replacingOccurrences(of: " | ", with: " · ").replacingOccurrences(of: "|", with: " ")
        out = out.replacingOccurrences(of: #"(^|\s)(#{1,6}|>)\s"#, with: "$1", options: .regularExpression)
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The choices in Settings → Search. Every default works with no setup.
enum SearchPreferences {
    enum Key {
        static let bestMatchFirst = "SearchBestMatchFirst"
        static let excerptLines = "SearchExcerptLines"
        static let subagents = "SearchSubagents"
        static let oneRowPerChat = "SearchOneRowPerChat"
        static let prefixWhileTyping = "SearchPrefixWhileTyping"
        static let indexToolOutput = "SearchIndexToolOutput"
        static func fieldOn(_ field: TranscriptField) -> String { "SearchField.\(field.rawValue).On" }
        /// -1 Less, 0 Normal, 1 More.
        static func fieldWeight(_ field: TranscriptField) -> String { "SearchField.\(field.rawValue).Weight" }
    }

    /// Where a sub-agent chat's matches go.
    enum Subagents: String, CaseIterable, Identifiable {
        case fold, separate, hide
        var id: String { rawValue }
    }

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    static var bestMatchFirst: Bool { bool(Key.bestMatchFirst, true) }
    static var oneRowPerChat: Bool { bool(Key.oneRowPerChat, true) }
    static var prefixWhileTyping: Bool { bool(Key.prefixWhileTyping, true) }
    static var indexToolOutput: Bool { bool(Key.indexToolOutput, true) }
    static var excerptLines: Int { min(3, max(1, UserDefaults.standard.object(forKey: Key.excerptLines) as? Int ?? 2)) }
    static var subagents: Subagents {
        UserDefaults.standard.string(forKey: Key.subagents).flatMap(Subagents.init) ?? .fold
    }

    /// Fields searched: those switched on, less tool output when it is not indexed.
    static var fields: [TranscriptField] {
        TranscriptField.allCases.filter { bool(Key.fieldOn($0), true) && ($0 != .toolOutput || indexToolOutput) }
    }

    static func weightFactor(_ field: TranscriptField) -> Double {
        switch UserDefaults.standard.integer(forKey: Key.fieldWeight(field)) {
        case ..<0: return 0.5
        case 1...: return 2
        default: return 1
        }
    }

    /// Back to the defaults for every field: searched, at Normal weight.
    static func resetFields() {
        for field in TranscriptField.allCases {
            UserDefaults.standard.removeObject(forKey: Key.fieldOn(field))
            UserDefaults.standard.removeObject(forKey: Key.fieldWeight(field))
        }
    }
}

enum RankedSearch {
    /// Title scores for the parts of a ranked query, weighted like the index's BM25
    /// scores: a part counts more the fewer titles contain it.
    static func titleScores(titles: [(key: SearchCoordinator.SessionKey, title: String)],
                            parts: [String]) -> [SearchCoordinator.SessionKey: Double] {
        var matched: [Int: [Int]] = [:]
        var containing = Array(repeating: 0.0, count: parts.count)
        for (i, entry) in titles.enumerated() where !entry.title.isEmpty {
            for (j, part) in parts.enumerated() where SearchTextMatcher.hasMatch(in: entry.title, query: part) {
                matched[i, default: []].append(j)
                containing[j] += 1
            }
        }
        let total = Double(titles.count)
        var scores: [SearchCoordinator.SessionKey: Double] = [:]
        for (i, partIndexes) in matched {
            let rarity = partIndexes.reduce(0.0) { $0 + log(1 + (total - containing[$1] + 0.5) / (containing[$1] + 0.5)) }
            scores[titles[i].key] = rarity * TranscriptField.title.weight
        }
        return scores
    }
}
