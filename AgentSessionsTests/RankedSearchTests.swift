import XCTest
@testable import AgentSessions

private final class RankedSearchTestStore: SearchSessionStoring {
    func transcriptCache(for source: SessionSource) -> TranscriptCache? { nil }
    func updateSession(_ session: Session) {}
    /// Like a real parse: the same events, without the title the list resolved for the session.
    func parseFull(session: Session) async -> Session? {
        Session(id: session.id, startTime: session.startTime, endTime: session.endTime, model: nil,
                filePath: session.filePath, eventCount: session.eventCount, events: session.events)
    }
    /// A read of what is on disk now: the file's text when the file exists, else the events
    /// the session holds, standing in for a file these tests do not write.
    func scan(session: Session, query: SearchQuery) async -> SearchScanResult {
        let texts = (try? String(contentsOfFile: session.filePath, encoding: .utf8)).map { [$0] }
            ?? session.events.compactMap(\.text)
        var truth = SearchQuery.Truth.unknown
        if let tokenizer = try? SearchTokenizer() {
            let predicate = SearchPredicateAccumulator(query: query, tokenizer: tokenizer)
            for text in texts { try? predicate.consume(field: text) }
            truth = predicate.truth(complete: true)
        }
        return SearchScanResult(key: .init(session), truth: truth,
                                summary: SearchScanSummary(revision: SearchSourceRevision()), snippet: nil)
    }
}

final class RankedSearchTests: XCTestCase {
    private func makeDB() throws -> (IndexDB, () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = IndexDBTestHooks.applicationSupportDirectoryProvider
        IndexDBTestHooks.applicationSupportDirectoryProvider = { dir }
        let db = try IndexDB()
        return (db, {
            IndexDBTestHooks.applicationSupportDirectoryProvider = original
            try? FileManager.default.removeItem(at: dir)
        })
    }

    private func ranked(_ db: IndexDB, _ text: String, fields: [TranscriptField] = TranscriptField.allCases) async throws -> [String] {
        let matches = try await db.searchFields(query: SearchTextMatcher.rankedQuery(text, forIndex: true),
                                                fields: fields, sources: ["codex"])
        var total: [String: Double] = [:]
        for match in matches { total[match.sessionID, default: 0] += match.score }
        return total.sorted { $0.value > $1.value }.map(\.key)
    }

    func testPlainWordsBecomePhraseOrAnyWordWithLastWordAsPrefix() {
        XCTAssertEqual(SearchTextMatcher.rankedQueryParts("cafe menu prices"),
                       ["\"cafe menu prices\"", "\"cafe\"", "\"menu\"", "\"prices\"", "\"prices\"*"])
        XCTAssertEqual(SearchTextMatcher.rankedQueryParts("UTF-8"), ["\"UTF-8\""])
        XCTAssertEqual(SearchTextMatcher.rankedQueryParts("\"exit code\" NOT zsh"), ["\"exit code\" NOT zsh"])
        XCTAssertEqual(SearchTextMatcher.rankedQueryParts("personal and work list"),
                       ["\"personal and work list\"", "\"personal\"", "\"work\"", "\"list\"", "\"list\"*"],
                       "a sentence with \"and\" in it is plain words; only AND in capitals is an operator")
        XCTAssertEqual(SearchTextMatcher.rankedQuery("tee"), "tee")
        XCTAssertEqual(SearchTextMatcher.rankedQuery("tee", forIndex: true), "\"tee\" OR \"tee\"*")
    }

    func testFillerWordsAreNotLookedUpOnTheirOwn() {
        XCTAssertEqual(SearchTextMatcher.rankedQueryParts("lettre pour les fournisseurs"),
                       ["\"lettre pour les fournisseurs\"", "\"lettre\"", "\"fournisseurs\"", "\"fournisseurs\"*"])
        XCTAssertEqual(SearchTextMatcher.rankedQueryParts("to be"), ["\"to be\"", "\"to\"", "\"be\""],
                       "a query of filler words alone keeps them")
        XCTAssertTrue(SearchTextMatcher.rankedQueryParts("inférence d'IA confidentielle").contains("\"d'IA\""),
                      "a word that only starts with filler is kept")
    }

    func testHighlightMatchesAnyWordAndIgnoresAccents() {
        let text = "Déjeuner au Café Olimpico hier"
        let query = SearchTextMatcher.rankedQuery("cafe receipt")
        let found = SearchTextMatcher.matchRanges(in: text, query: query).map { (text as NSString).substring(with: $0) }
        XCTAssertEqual(found, ["Café"])
        XCTAssertTrue(SearchTextMatcher.hasMatch(in: text, query: "cafe"))
        XCTAssertFalse(SearchTextMatcher.hasMatch(in: "the steering committee", query: SearchTextMatcher.rankedQuery("tee")))
    }

    func testFieldPriorityFullCoverageAndSingleFieldSearch() async throws {
        let (db, cleanup) = try makeDB()
        defer { cleanup() }
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 20_000)  // about 540,000 characters
        try await db.begin()
        for i in 0..<30 {
            try await db.upsertSessionFields(sessionID: "filler-\(i)", source: "codex",
                                             fields: [.user: "plan the release \(i)", .assistant: "done \(i)",
                                                      .toolCall: "ls -la", .toolOutput: "total \(i)"])
        }
        try await db.upsertSessionFields(sessionID: "prompt", source: "codex", fields: [.user: "print the envelope for the landlord"])
        try await db.upsertSessionFields(sessionID: "reply", source: "codex", fields: [.assistant: "I printed the envelope"])
        try await db.upsertSessionFields(sessionID: "deep-output", source: "codex", fields: [.toolOutput: filler + " envelope " + filler])
        try await db.upsertSessionFields(sessionID: "accent", source: "codex", fields: [.user: "un café à Montréal"])
        try await db.upsertSessionFields(sessionID: "inside-word", source: "codex", fields: [.user: "the steering committee"])
        try await db.upsertSessionFields(sessionID: "phrase-in-reply", source: "codex", fields: [.assistant: "the late departure notice was mailed"])
        try await db.upsertSessionFields(sessionID: "word-in-prompt", source: "codex", fields: [.user: "departure"])
        try await db.commit()

        let envelope = try await ranked(db, "envelope")
        XCTAssertEqual(envelope, ["prompt", "reply", "deep-output"], "prompt outranks reply outranks tool output; the deep match is not cut off")
        let outputOnly = try await ranked(db, "envelope", fields: [.toolOutput])
        XCTAssertEqual(outputOnly, ["deep-output"])
        let accent = try await ranked(db, "montreal")
        XCTAssertEqual(accent, ["accent"])
        let tee = try await ranked(db, "tee")
        XCTAssertEqual(tee, [], "a word must not match inside a longer word")
        let phrase = try await ranked(db, "late departure notice")
        XCTAssertEqual(phrase.first, "phrase-in-reply",
                       "an exact phrase in a reply outranks one of its words in a prompt")

        let excerpts = try await db.fieldExcerpts(query: "\"envelope\"", field: .user, sessionIDs: ["prompt"])
        XCTAssertEqual(excerpts["prompt"], "print the \u{1}envelope\u{2} for the landlord")
    }

    func testRemovingASessionRemovesItFromEveryFieldIndex() async throws {
        let (db, cleanup) = try makeDB()
        defer { cleanup() }
        try await db.begin()
        try await db.upsertSessionSearch(sessionID: "gone", source: "codex", mtime: 1, size: 1, text: "x")
        try await db.upsertSessionFields(sessionID: "gone", source: "codex", fields: [.user: "envelope", .toolOutput: "envelope"])
        try await db.commit()
        try await db.exec("DELETE FROM session_search WHERE session_id = 'gone';")
        let after = try await ranked(db, "envelope")
        XCTAssertEqual(after, [])
        let indexed = try await db.fieldIndexedSessionIDs(sources: ["codex"])
        XCTAssertEqual(indexed, [])
    }

    func testTitleScoresFavourRareWords() {
        let key = { SearchCoordinator.SessionKey(source: .codex, id: $0) }
        var titles = (0..<20).map { (key: key("common-\($0)"), title: "Fix the report") }
        titles.append((key: key("rare"), title: "Montréal trip notes"))
        let scores = RankedSearch.titleScores(titles: titles, parts: SearchTextMatcher.rankedQueryParts("montreal report"))
        XCTAssertGreaterThan(scores[key("rare")] ?? 0, scores[key("common-0")] ?? 0)
        XCTAssertNil(scores[key("missing")])
    }

    // MARK: - The ranked path, end to end through SearchCoordinator

    func testFillerAndTheLastWordDoNotOutweighTheOtherWords() async throws {
        let (db, cleanup) = try makeDB()
        defer { cleanup() }
        let both = session("both"), last = session("last"), french = session("french"), heron = session("heron")
        try await db.begin()
        for i in 0..<30 { try await index(db, session("other-\(i)"), [.user: "plan the release number \(i) today"]) }
        try await index(db, both, [.user: "the egret nests by the lagoon today"])
        try await index(db, last, [.user: "quota check and quota reset today"])
        try await index(db, french, [.user: "pour les notes pour les amis"])
        try await index(db, heron, [.user: "one heron on the shore today"])
        let longer = session("longer")
        try await index(db, longer, [.user: "quotas quotas quotas quotas today"])
        try await db.commit()
        let all = [both, last, french, heron, longer] + (0..<30).map { session("other-\($0)") }

        // Counted as a word and again as a prefix, "quota" twice in one chat outweighed two matching words.
        let lastWord = try await search("egret lagoon quota", in: all, db: db)
        XCTAssertEqual(lastWord.results.prefix(2).map(\.id), ["both", "last"])
        // "pour" and "les" are rare here, so they outweighed the one word that says something.
        let filler = try await search("heron pour les", in: all, db: db)
        XCTAssertEqual(filler.results.first?.id, "heron")
        // A whole word still beats a longer word that only starts with it.
        let exact = try await search("quota", in: all, db: db)
        XCTAssertEqual(exact.results.map(\.id), ["last", "longer"])
    }

    private func session(_ id: String, lastEvent: TimeInterval = 100, chat: String? = nil, file: String? = nil,
                         subagent: Bool = false, said: String? = nil, title: String? = nil) -> Session {
        let events = said.map {
            [SessionEvent(id: "\(id)-1", timestamp: Date(timeIntervalSince1970: lastEvent), kind: .user, role: "user",
                          text: $0, toolName: nil, toolInput: nil, toolOutput: nil, messageID: nil, parentID: nil,
                          isDelta: false, rawJSON: "{}")]
        } ?? []
        return Session(id: id, startTime: Date(timeIntervalSince1970: 1), endTime: Date(timeIntervalSince1970: lastEvent),
                       model: nil, filePath: "/tmp/ranked-tests/\(file ?? id).jsonl", eventCount: events.count, events: events,
                       codexInternalSessionIDHint: chat, parentSessionID: subagent ? "parent" : nil,
                       relationshipKind: subagent ? .subagent : nil, customTitle: title)
    }

    /// Index a session as ingest would: its file stat at ingest time 100, then its fields.
    private func index(_ db: IndexDB, _ session: Session, _ fields: [TranscriptField: String]) async throws {
        try await db.upsertFile(path: session.filePath, mtime: 100, size: 1, source: "codex")
        try await db.upsertSessionSearch(sessionID: session.id, source: "codex", mtime: 100, size: 1, text: "")
        try await db.upsertSessionFields(sessionID: session.id, source: "codex", fields: fields)
    }

    private func search(_ query: String, in sessions: [Session], db: IndexDB,
                        field: TranscriptField? = nil) async throws -> SearchCoordinator {
        let coordinator = SearchCoordinator(store: RankedSearchTestStore(), db: db)
        coordinator.field = field
        coordinator.start(query: query, filters: Filters(query: query), allowed: [.codex], enableDeepScan: false, all: sessions)
        try await Task.sleep(nanoseconds: 50_000_000)
        for _ in 0..<100 where coordinator.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(coordinator.isRunning, "search did not finish")
        return coordinator
    }

    // MARK: - Passages

    func testPassagesBreakAtLineEndsAndOverlap() {
        let text = Array((String(repeating: "a", count: 1000) + "\n" + String(repeating: "b", count: 1000) + "\n"
                          + String(repeating: "c", count: 4000)).unicodeScalars)
        let parts = Passages.ranges(in: text)
        XCTAssertTrue(parts.allSatisfy { $0.count <= Passages.size + 1 })
        XCTAssertEqual(parts.first, 0..<1000, "breaks at the line end")
        XCTAssertEqual(parts[1].lowerBound, 1000 - Passages.overlap, "repeats the end of the one before")
        XCTAssertEqual(parts.last?.upperBound, text.count, "covers the text to its end")
        XCTAssertTrue(zip(parts, parts.dropFirst()).allSatisfy { $1.lowerBound < $0.upperBound }, "no gap between passages")
        XCTAssertEqual(Passages.ranges(in: []), [])
        XCTAssertEqual(Passages.ranges(in: Array("hi".unicodeScalars)), [0..<2])
    }

    func testChatWhoseWordsSitTogetherOutranksOneThatScattersThem() async throws {
        let (db, cleanup) = try makeDB()
        defer { cleanup() }
        // More than one passage long, so words on either side of it never share a passage.
        let filler = String(repeating: "lorem ipsum dolor sit amet\n", count: 80)
        let scattered = session("scattered"), together = session("together")
        let others = (0..<20).map { session("other-\($0)") }
        try await db.begin()
        for other in others { try await index(db, other, [.assistant: "nothing here\n" + filler]) }
        try await index(db, scattered, [.assistant: (0..<3).map { _ in "the quota was raised\n" + filler + "gemini answered\n" + filler }.joined()])
        try await index(db, together, [.assistant: filler + filler + filler + "so we give gemini its own quota\n" + filler + filler + filler])
        try await db.commit()

        let byWholeChat = try await ranked(db, "gemini quota")
        XCTAssertEqual(byWholeChat.first, "scattered", "scored as whole chats, the one that repeats the words wins")
        let found = try await search("gemini quota", in: [scattered, together] + others, db: db)
        XCTAssertEqual(found.results.first?.id, "together", "its best passage holds both words")
        let hit = try XCTUnwrap(found.hits[SearchCoordinator.SessionKey(together)])
        XCTAssertEqual(hit.excerpt?.contains("\u{1}gemini\u{2} its own \u{1}quota\u{2}"), true, "the excerpt is that passage: \(hit.excerpt ?? "-")")
        XCTAssertEqual(hit.anchor, "gemini its own quota", "and a click can land on it")
    }

    func testPassagesAreDroppedWhenASessionIsReadAgainAndCutFromStoredText() async throws {
        let (db, cleanup) = try makeDB()
        defer { cleanup() }
        try await index(db, session("chat"), [.user: "print the envelope for the landlord"])
        var found = try await db.searchPassages(query: "\"envelope\"", sources: ["codex"])
        XCTAssertEqual(found.map(\.sessionID), ["chat"])

        // An older build rewrites the session's row and knows nothing of passages: they are
        // dropped, and cut again from the stored text, as for an index made before passages.
        try await db.exec("UPDATE field_docs SET skipped = skipped;")
        found = try await db.searchPassages(query: "\"envelope\"", sources: ["codex"])
        XCTAssertEqual(found.count, 0, "passages of the earlier text are gone")
        let filled = try await db.fillPassages()
        XCTAssertEqual(filled, 1)
        found = try await db.searchPassages(query: "\"envelope\"", sources: ["codex"])
        XCTAssertEqual(found.map(\.ord), [0])
        let texts = try await db.passageTexts(field: .user, passages: [("chat", 0)])
        XCTAssertEqual(texts, ["print the envelope for the landlord"])
        let left = try await db.fillPassages()
        XCTAssertEqual(left, 0)
    }

    func testRankedSearchOrdersByFieldExplainsEachRowAndSearchesOneField() async throws {
        let (db, cleanup) = try makeDB()
        defer { cleanup() }
        let prompt = session("prompt"), reply = session("reply"), output = session("output")
        let brief = session("brief", subagent: true), other = session("other")
        try await db.begin()
        try await index(db, prompt, [.user: "print the envelope for the landlord"])
        try await index(db, reply, [.assistant: "I printed the envelope"])
        try await index(db, output, [.toolOutput: "envelope.pdf written"])
        try await index(db, brief, [.user: "check the envelope size"])
        try await index(db, other, [.user: "nothing to see"])
        try await db.commit()
        let all = [prompt, reply, output, brief, other]

        let everything = try await search("envelope", in: all, db: db)
        XCTAssertEqual(everything.results.map(\.id), ["prompt", "reply", "brief", "output"])
        XCTAssertTrue(everything.isRanked)
        XCTAssertEqual(everything.unindexedCount, 0)
        XCTAssertEqual(everything.updatingCount, 0)
        let promptHit = everything.hits[SearchCoordinator.SessionKey(prompt)]
        XCTAssertEqual(promptHit?.field, .user)
        XCTAssertEqual(promptHit?.excerpt, "print the \u{1}envelope\u{2} for the landlord")
        XCTAssertEqual(everything.hits[SearchCoordinator.SessionKey(brief)]?.field, .toolCall,
                       "a sub-agent's prompt is its parent's brief")

        let outputOnly = try await search("envelope", in: all, db: db, field: .toolOutput)
        XCTAssertEqual(outputOnly.results.map(\.id), ["output"])
        let briefs = try await search("envelope", in: all, db: db, field: .toolCall)
        XCTAssertEqual(briefs.results.map(\.id), ["brief"])
    }

    func testChatStoredInSeveralFilesIsOneRowAtItsBestPage() async throws {
        let (db, cleanup) = try makeDB()
        defer { cleanup() }
        let first = session("p1", chat: "chat-a", file: "rollout-2026-10-09T16-37-06-a")
        let second = session("p2", chat: "chat-a", file: "rollout-2026-10-10T08-15-17-a_b")
        let third = session("p3", chat: "chat-a", file: "rollout-2026-10-27T20-39-31-a_c")
        let lone = session("lone", chat: "chat-b")
        try await db.begin()
        try await index(db, first, [.toolOutput: "a zeppelin among many other words in a long tool output"])
        try await index(db, second, [.user: "nothing here"])
        try await index(db, third, [.user: "the zeppelin, the zeppelin"])
        try await index(db, lone, [.user: "zeppelin"])
        try await db.commit()

        let found = try await search("zeppelin", in: [first, second, third, lone], db: db)
        XCTAssertEqual(Set(found.results.map(\.id)), ["p3", "lone"], "one row per chat, at its best page")
        let hit = try XCTUnwrap(found.hits[SearchCoordinator.SessionKey(third)])
        XCTAssertEqual(hit.part, 3)
        XCTAssertEqual(hit.partCount, 3)
        XCTAssertNil(found.hits[SearchCoordinator.SessionKey(lone)]?.part)
    }

    func testSubagentFoldsIntoItsParentAndEachFieldIsCounted() async throws {
        let (db, cleanup) = try makeDB()
        defer { cleanup() }
        let parent = session("parent"), child = session("child", subagent: true), other = session("other")
        try await db.begin()
        try await index(db, parent, [.user: "plan the receipts"])
        try await index(db, child, [.user: "find the receipts", .assistant: "found the receipts in Gmail"])
        try await index(db, other, [.toolOutput: "receipts.csv written"])
        try await db.commit()
        let all = [parent, child, other]

        let found = try await search("receipts", in: all, db: db)
        XCTAssertEqual(Set(found.results.map(\.id)), ["parent", "other"], "the sub-agent is folded into its parent")
        XCTAssertEqual(found.fieldCounts[.user], 1, "the folded brief is not counted again")
        XCTAssertEqual(found.fieldCounts[.toolCall], 0)
        XCTAssertEqual(found.fieldCounts[.assistant], 1)
        XCTAssertEqual(found.fieldCounts[.toolOutput], 1)
        XCTAssertEqual(found.matchCount, 2)
        XCTAssertEqual(found.hits[SearchCoordinator.SessionKey(parent)]?.also, [.assistant])

        let replies = try await search("receipts", in: all, db: db, field: .assistant)
        XCTAssertEqual(replies.results.map(\.id), ["parent"])
        XCTAssertEqual(replies.fieldCounts[.toolOutput], 1, "every field is still counted")
        let hit = try XCTUnwrap(replies.hits[SearchCoordinator.SessionKey(parent)])
        XCTAssertTrue(hit.inSubagent)
        XCTAssertEqual(hit.excerpt, "found the \u{1}receipts\u{2} in Gmail")
    }

    func testTextWrittenSinceIngestIsFoundAndCountedAsUpdating() async throws {
        let (db, cleanup) = try makeDB()
        defer { cleanup() }
        // Indexed at time 100. "live" got a new message at 200; "settled" did not, so its
        // in-memory text must not be scanned again.
        let live = session("live", lastEvent: 200, said: "the zebracorn appeared", title: "Live chat")
        let settled = session("settled", lastEvent: 90, said: "a zebracorn the index never saw")
        let fresh = session("fresh", lastEvent: 300, said: "zebracorn in a chat not indexed yet")
        try await db.begin()
        try await index(db, live, [.user: "an older question"])
        try await index(db, settled, [.user: "an older question"])
        try await db.commit()

        let found = try await search("zebracorn unicorn", in: [live, settled, fresh], db: db)
        XCTAssertEqual(Set(found.results.map(\.id)), ["live", "fresh"], "any word matches, as in the index")
        XCTAssertEqual(found.results.first { $0.id == "live" }?.customTitle, "Live chat", "listed with the list's title")
        XCTAssertEqual(found.updatingCount, 1)
        XCTAssertEqual(found.unindexedCount, 1)

        let oneField = try await search("zebracorn", in: [live, settled, fresh], db: db, field: .user)
        XCTAssertEqual(oneField.results.map(\.id), [], "the live read cannot tell fields apart")
    }

    func testChatWhoseFileWasNotWrittenSinceIngestIsNotReadAgain() async throws {
        let (db, cleanup) = try makeDB()
        defer { cleanup() }
        // The list's time for the chat runs ahead of the ingest at 100, but its file, stored
        // compressed, was last written at 50: there is nothing newer to read.
        let quiet = session("quiet", lastEvent: 200, said: "a zebracorn only the list's copy holds")
        try FileManager.default.createDirectory(atPath: "/tmp/ranked-tests", withIntermediateDirectories: true)
        let stored = quiet.filePath + ".zst"
        try "compressed".write(toFile: stored, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 50)], ofItemAtPath: stored)
        defer { try? FileManager.default.removeItem(atPath: stored) }
        try await index(db, quiet, [.user: "an older question"])

        let found = try await search("zebracorn", in: [quiet], db: db)
        XCTAssertEqual(found.updatingCount, 0)
        XCTAssertEqual(found.results.map(\.id), [])
    }

    func testChatsInOneSharedStoreAreNotAllReadWhenTheStoreChanges() async throws {
        let (db, cleanup) = try makeDB()
        defer { cleanup() }
        // OpenCode keeps every chat in one database file, so the file's date says nothing about
        // one chat. Only the chat with an event after the ingest at 100 is read again.
        let quiet = session("quiet", lastEvent: 90, file: "store", said: "an older question")
        let active = session("active", lastEvent: 200, file: "store", said: "an older question")
        try FileManager.default.createDirectory(atPath: "/tmp/ranked-tests", withIntermediateDirectories: true)
        try "the zebracorn arrived".write(toFile: active.filePath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: active.filePath) }
        try await db.begin()
        try await index(db, quiet, [.user: "an older question"])
        try await index(db, active, [.user: "an older question"])
        try await db.commit()

        let found = try await search("zebracorn", in: [quiet, active], db: db)
        XCTAssertEqual(found.updatingCount, 1)
        XCTAssertEqual(found.results.map(\.id), ["active"])
    }

    func testChangedChatIsReadFromItsFileWhenTheListCopyLags() async throws {
        let (db, cleanup) = try makeDB()
        defer { cleanup() }
        // The list holds this chat up to time 90 and has not refreshed it; ingest saw it at 100.
        // Its file has been written since.
        let lagging = session("lagging", lastEvent: 90, said: "an older question", title: "Open elsewhere")
        try FileManager.default.createDirectory(atPath: "/tmp/ranked-tests", withIntermediateDirectories: true)
        try "the quillfeather arrived".write(toFile: lagging.filePath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: lagging.filePath) }
        try await db.begin()
        try await index(db, lagging, [.user: "an older question"])
        try await db.commit()

        let found = try await search("quillfeather", in: [lagging], db: db)
        XCTAssertEqual(found.results.map(\.id), ["lagging"], "found in the file, not the list's copy")
        XCTAssertEqual(found.results.first?.customTitle, "Open elsewhere")
        XCTAssertEqual(found.updatingCount, 1)
    }

    func testRowsOfMissingFilesAreDeletedOnlyWhenTheirFolderExists() async throws {
        let (db, cleanup) = try makeDB()
        defer { cleanup() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ranked-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let moved = folder.appendingPathComponent("rollout-moved.jsonl").path
        let unmounted = "/Volumes/not-mounted-\(UUID().uuidString)/rollout-x.jsonl"
        try await db.begin()
        for (id, path) in [("moved", moved), ("unmounted", unmounted)] {
            try await db.upsertSessionMeta(SessionMetaRow(
                sessionID: id, source: "codex", path: path, mtime: 1, size: 1, startTS: 1, endTS: 2, model: nil,
                cwd: nil, repo: nil, title: nil, codexInternalSessionID: nil, isHousekeeping: false, messages: 1,
                commands: 0, parentSessionID: nil, subagentType: nil, customTitle: nil))
            try await db.upsertSessionSearch(sessionID: id, source: "codex", mtime: 1, size: 1, text: "x")
            try await db.upsertSessionFields(sessionID: id, source: "codex", fields: [.user: "x"])
        }
        try await db.deleteSessionsForMissingFiles(source: "codex", paths: [moved, unmounted])
        try await db.commit()
        let left = try await db.fieldIndexedSessionIDs(sources: ["codex"])
        XCTAssertEqual(left, ["unmounted"])
    }

    func testIngestDoesNotFailWithoutTheFieldTables() async throws {
        let (db, cleanup) = try makeDB()
        defer { cleanup() }
        try await db.exec("DROP TRIGGER field_docs_ad; DROP TABLE field_docs;")
        try await db.upsertSessionFields(sessionID: "s", source: "codex", fields: [.user: "x"])
    }

    // MARK: - Prompts the index used to miss

    private func codexLine(_ payload: [String: Any]) throws -> SessionEvent {
        let data = try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": payload])
        return SessionIndexer.parseLine(String(decoding: data, as: UTF8.self), eventID: UUID().uuidString).0
    }

    func testPromptTaggedWithOnlyATurnIDIsIndexedAsTyped() throws {
        let turnOnly: [String: Any] = ["turn_id": "t1"]
        let prompt = try codexLine(["type": "message", "role": "user", "internal_chat_message_metadata_passthrough": turnOnly,
                                    "content": [["type": "input_text", "text": "On the team chat, add user @sam to 25 groups"]]])
        let context = try codexLine(["type": "message", "role": "user", "internal_chat_message_metadata_passthrough": turnOnly,
                                     "content": [["type": "input_text", "text": "<environment_context><cwd>/x</cwd></environment_context>"]]])
        let session = Session(id: "wire", startTime: nil, endTime: nil, model: nil, filePath: "/tmp/wire.jsonl",
                              eventCount: 2, events: [prompt, context])
        XCTAssertEqual(SessionSearchTextBuilder.buildFields(session: session)[.user], "On the team chat, add user @sam to 25 groups")
    }

    func testDelegatedChatBriefIsIndexedAsItsPrompt() throws {
        let brief = try codexLine(["type": "function_call_output", "call_id": "c1", "name": "create_thread",
                                   "output": "<codex_delegation>\n  <source_thread_id>p</source_thread_id>\n  <input>Plan the zebracorn search</input>\n</codex_delegation>"])
        let session = Session(id: "child", startTime: nil, endTime: nil, model: nil, filePath: "/tmp/child.jsonl",
                              eventCount: 1, events: [brief])
        let fields = SessionSearchTextBuilder.buildFields(session: session)
        XCTAssertEqual(fields[.user], "Plan the zebracorn search")
        XCTAssertNil(fields[.toolOutput])
    }

    func testEventsTooLargeToParseAreCounted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-2026-11-21T00-00-00-big-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = "data:image/png;base64," + String(repeating: "A", count: 6_000_000)
        let lines = [
            #"{"type":"session_meta","payload":{"id":"big","timestamp":"2026-11-21T00:00:00Z","cwd":"/tmp"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"show the screenshot"}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":""# + image + #""}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":""#
                + String(repeating: "x", count: 9_000_000) + #""}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let session = try XCTUnwrap(SessionSourceRegistry.descriptor(for: .codex).parseFullByPath?(url))
        XCTAssertEqual(SessionSearchTextBuilder.skippedEventCount(session: session), 2)
        XCTAssertEqual(SessionSearchTextBuilder.buildFields(session: session)[.user], "show the screenshot")
    }

    // MARK: - Private gate on a real history (skipped unless AS_SEARCH_GATE names a folder)

    /// Runs each search in <folder>/real-searches.json against <folder>/AgentSessions/index.db,
    /// a copy of a real index, and fails when a chat lands below the position its case allows
    /// and below its rank in <folder>/accepted-ranks.json (so a known miss fails only when it
    /// gets worse). Writes gate-report.txt and gate-ranks.json (0 = not found).
    func testRealSearchesFindTheirChats() async throws {
        guard let folder = ProcessInfo.processInfo.environment["AS_SEARCH_GATE"] else {
            throw XCTSkip("Set AS_SEARCH_GATE to a folder holding AgentSessions/index.db and real-searches.json")
        }
        struct Case: Decodable { let query: String; let chat: String; let within: Int }
        let dir = URL(fileURLWithPath: folder)
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: dir.appendingPathComponent("real-searches.json")))
        let accepted = (try? JSONDecoder().decode([String: Int].self,
                                                  from: Data(contentsOf: dir.appendingPathComponent("accepted-ranks.json")))) ?? [:]
        let original = IndexDBTestHooks.applicationSupportDirectoryProvider
        IndexDBTestHooks.applicationSupportDirectoryProvider = { dir }
        defer { IndexDBTestHooks.applicationSupportDirectoryProvider = original }
        let db = try IndexDB()
        while try await db.fillPassages(limit: 200) > 0 {}
        var sessions = try await SessionMetaRepository(db: db).fetchSessions(for: .codex)
            .filter { CodexRolloutStorage.exists(atPath: $0.filePath) }
        // Chats run in the folder AS_SEARCH_GATE_SKIP_CWD names are left out, with their sub-agents:
        // the chats that wrote a set of cases quote them word for word.
        if let skip = ProcessInfo.processInfo.environment["AS_SEARCH_GATE_SKIP_CWD"], !skip.isEmpty {
            let skipped = Set(sessions.filter { ($0.cwd ?? "").contains(skip) }.map(\.id))
            sessions.removeAll { skipped.contains($0.id) || $0.parentSessionID.map(skipped.contains) == true }
        }

        var report: [String] = []
        var ranks: [String: Int] = [:]
        var misses = 0
        for item in cases {
            let coordinator = SearchCoordinator(store: RankedSearchTestStore(), db: db)
            coordinator.start(query: item.query, filters: Filters(query: item.query), allowed: [.codex],
                              enableDeepScan: false, all: sessions)
            // The ranked list is what this measures. The live read of chats changed since the
            // index was copied is cancelled, or it runs on under the next searches.
            for _ in 0..<3_000 where !coordinator.isRanked { try await Task.sleep(nanoseconds: 20_000_000) }
            let rank = coordinator.results.firstIndex { ($0.codexInternalSessionIDHint ?? $0.id) == item.chat }.map { $0 + 1 }
            await coordinator.cancel()
            ranks[item.query] = rank ?? 0
            let worst = { (r: Int) in r == 0 ? Int.max : r }
            let ok = worst(rank ?? 0) <= item.within || accepted[item.query].map { worst(rank ?? 0) <= worst($0) } == true
            if !ok { misses += 1 }
            let mark = !ok ? "WORSE" : (worst(rank ?? 0) <= item.within ? "ok   " : "known")
            report.append("\(mark) \(rank.map(String.init) ?? "-")/\(item.within)  \(item.query)")
        }
        report.append("\(misses) of \(cases.count) got worse than accepted")
        try report.joined(separator: "\n").appending("\n")
            .write(to: dir.appendingPathComponent("gate-report.txt"), atomically: true, encoding: .utf8)
        try JSONEncoder().encode(ranks).write(to: dir.appendingPathComponent("gate-ranks.json"))
        XCTAssertEqual(misses, 0, report.joined(separator: "\n"))
    }
}
