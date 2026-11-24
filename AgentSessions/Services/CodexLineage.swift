import Foundation

/// What Codex rollout files say about forks and compactions. The session parser keeps neither (it
/// does not read `forked_from_id`, and a compaction line can be larger than it accepts), so the
/// history views read them here, from the first bytes of a file or of a line.
enum CodexLineage {
    struct Fork: Equatable {
        /// Thread ids.
        var child: String
        var parent: String
        /// The first line of the parent the fork does not have, when Codex recorded it.
        var ordinal: Int?
        var created: Date?
    }

    struct Scan: Equatable {
        var compactions: [Date] = []
        /// Times of the lines asked for, by ordinal.
        var lineTimes: [Int: Date] = [:]
    }

    /// The thread a rollout belongs to: the first UUID in its file name. Pages of a long chat
    /// share it.
    static func threadID(ofPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard let range = name.range(of: "[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}", options: .regularExpression) else { return nil }
        return String(name[range])
    }

    // MARK: Pages of a long chat

    /// A long chat is stored as several rollout files, its pages. Codex starts a new page when
    /// a prompt is sent again; the page names the one it continues and how much of that one
    /// still belongs to the chat (what came after was the attempt that was replaced).
    struct HistoryBase: Equatable {
        /// The page continued: the chat's own id for the first page, else the id after the
        /// underscore in the page's file name.
        var page: String
        /// Lines of the whole chat up to the cut, counted from its first page.
        var endOrdinal: Int?
        /// Bytes of the continued page that belong to the chat.
        var endByteOffset: UInt64
    }

    /// One page a rollout continues, and the part of it that belongs to the chat.
    struct BasePage: Equatable {
        var url: URL
        var byteCount: UInt64
        /// The same cut in lines of this page, when Codex recorded ordinals.
        var lineCount: Int?
    }

    /// What the first line of a rollout (`session_meta`) says it continues; nil for a chat in
    /// one file and for the first page of a long one.
    static func historyBase(inHeadOf url: URL) -> HistoryBase? {
        // The key sits after the instructions, some 22 KB into the line.
        guard let data = try? CodexRolloutStorage.readHead(for: url, maxBytes: 1_048_576) else { return nil }
        let line = String(decoding: data.prefix { $0 != 0x0A }, as: UTF8.self)
        guard let key = line.range(of: "\"history_base\":{") else { return nil }
        let fields = String(line[key.upperBound...].prefix(400))
        guard let page = value(of: "thread_id", in: fields),
              let end = value(of: "end_byte_offset", in: fields).flatMap({ UInt64($0) }) else { return nil }
        return HistoryBase(page: page, endOrdinal: value(of: "end_ordinal_exclusive", in: fields).flatMap { Int($0) }, endByteOffset: end)
    }

    /// Whether a rollout path is the given page of a chat: "…-<chat>.jsonl" for the first page,
    /// "…-<chat>_<page>.jsonl" for a later one.
    static func isPage(_ page: String, ofChat chat: String, path: String) -> Bool {
        let name = CodexRolloutStorage.canonicalURL(for: URL(fileURLWithPath: path)).lastPathComponent
        return name.hasPrefix("rollout-") && name.hasSuffix(page == chat ? "-\(chat).jsonl" : "-\(chat)_\(page).jsonl")
    }

    /// The pages a rollout continues, oldest first. Empty for a chat in one file and for a first
    /// page. `paths` are the rollouts already known; the folders beside the rollout are read
    /// for a page that is not among them. A page that cannot be found ends the walk, so the
    /// result is always the unbroken run of pages just before this one.
    static func basePages(of url: URL, rollouts paths: [String]) -> [BasePage] {
        guard let chat = threadID(ofPath: url.path), var base = historyBase(inHeadOf: url) else { return [] }
        var known = paths.filter { $0.contains(chat) }
        var searchedFolders = false
        func path(of page: String) -> String? {
            if let found = known.first(where: { isPage(page, ofChat: chat, path: $0) }) { return found }
            guard !searchedFolders else { return nil }
            searchedFolders = true
            known += rollouts(ofChat: chat, near: url)
            return known.first { isPage(page, ofChat: chat, path: $0) }
        }
        var pages: [BasePage] = []
        var ends: [Int?] = []
        var seen: Set<String> = [url.path]
        while pages.count < 64, let found = path(of: base.page), seen.insert(found).inserted {
            let page = URL(fileURLWithPath: found)
            pages.append(BasePage(url: page, byteCount: base.endByteOffset, lineCount: nil))
            ends.append(base.endOrdinal)
            guard let next = historyBase(inHeadOf: page) else { ends.append(0); break }
            base = next
        }
        // Ordinals count from the first page: a page's own lines are its cut less the cut of the
        // page before it (the cut the last page found names, when the walk stopped at a missing one).
        if ends.count == pages.count { ends.append(base.endOrdinal) }
        for index in pages.indices {
            if let end = ends[index], let before = ends[index + 1], end >= before { pages[index].lineCount = end - before }
        }
        return pages.reversed()
    }

    /// The rollouts of a chat in the day folders around one of them (sessions/YYYY/MM/DD), or
    /// in its own folder when it is not in such a tree.
    private static func rollouts(ofChat chat: String, near url: URL) -> [String] {
        let fileManager = FileManager.default
        let day = url.deletingLastPathComponent()
        func files(in folder: URL) -> [String] {
            ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasPrefix("rollout-") && $0.contains(chat) }
                .map { CodexRolloutStorage.canonicalURL(for: folder.appendingPathComponent($0)).path }
        }
        func folders(in folder: URL) -> [URL] {
            ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
                .map { folder.appendingPathComponent($0, isDirectory: true) }
        }
        let root = day.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let isDayTree = [day, day.deletingLastPathComponent(), day.deletingLastPathComponent().deletingLastPathComponent()]
            .allSatisfy { $0.lastPathComponent.allSatisfy(\.isNumber) && !$0.lastPathComponent.isEmpty }
        guard isDayTree else { return files(in: day) }
        return folders(in: root).flatMap(folders).flatMap(folders).flatMap(files)
    }

    /// The fork recorded at the start of a rollout's first line (`session_meta`); nil for a chat
    /// that is not a fork.
    static func fork(inHeadOf url: URL) -> Fork? {
        guard let data = try? CodexRolloutStorage.readHead(for: url, maxBytes: 2048) else { return nil }
        let head = String(decoding: data, as: UTF8.self)
        guard let parent = value(of: "forked_from_id", in: head), let child = value(of: "id", in: head) else { return nil }
        return Fork(child: child, parent: parent,
                    ordinal: value(of: "forked_from_ordinal_exclusive", in: head).flatMap { Int($0) },
                    created: value(of: "timestamp", in: head).flatMap(date))
    }

    /// The compactions in a rollout and the times of the given lines, read from the start of each
    /// line. Streams the whole file, or its first `byteLimit` bytes (a page of a long chat up to
    /// where the next page took over), so call it off the main thread.
    static func scan(_ url: URL, ordinals: Set<Int>, byteLimit: UInt64? = nil) -> Scan {
        var scan = Scan()
        guard let reader = CodexRolloutStorage.lineReader(for: url, maximumBytes: byteLimit) else { return scan }
        try? reader.forEachLine { line in
            let start = String(line.prefix(120))
            let compacted = start.contains("\"type\":\"compacted\"")
            let ordinal = ordinals.isEmpty ? nil : value(of: "ordinal", in: start).flatMap { Int($0) }
            let wanted = ordinal.map(ordinals.contains) == true
            guard compacted || wanted, let time = value(of: "timestamp", in: start).flatMap(date) else { return }
            if compacted { scan.compactions.append(time) }
            if wanted, let ordinal { scan.lineTimes[ordinal] = time }
        }
        return scan
    }

    /// The string or number after `"key":`.
    static func value(of key: String, in text: String) -> String? {
        guard let range = text.range(of: "\"\(key)\":") else { return nil }
        let rest = text[range.upperBound...]
        if rest.first == "\"" { return rest.dropFirst().split(separator: "\"", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) }
        let digits = rest.prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    private static let fractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func date(_ text: String) -> Date? {
        fractionalSeconds.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// The forks among the Codex chats on this Mac. It reads the start of each rollout once; a
    /// later call reads only the files it has not seen.
    final class ForkIndex: @unchecked Sendable {
        static let shared = ForkIndex()
        private let lock = NSLock()
        private var seen = Set<String>()
        private var byChild: [String: Fork] = [:]

        /// Reads the files not seen yet, then returns the fork that made `thread` and the forks
        /// made from it, oldest first.
        func forks(around thread: String, rollouts paths: [String]) -> (own: Fork?, children: [Fork]) {
            lock.lock()
            defer { lock.unlock() }
            for path in paths where seen.insert(path).inserted {
                // Every page of a forked chat repeats the fork; the first one read is kept.
                if let fork = CodexLineage.fork(inHeadOf: URL(fileURLWithPath: path)), byChild[fork.child] == nil {
                    byChild[fork.child] = fork
                }
            }
            let children = byChild.values.filter { $0.parent == thread }
                .sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
            return (byChild[thread], children)
        }
    }
}

