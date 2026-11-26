import SwiftUI
import XCTest
@testable import AgentSessions

/// The layout behind the history rail: prompts get room, tool runs are squeezed, and a place on
/// the rail maps back to a block.
final class TranscriptRailTests: XCTestCase {
    private func block(_ kind: SessionTranscriptBuilder.LogicalBlock.Kind, _ text: String = "x") -> SessionTranscriptBuilder.LogicalBlock {
        SessionTranscriptBuilder.LogicalBlock(kind: kind, text: text, timestamp: nil,
            messageID: nil, toolName: kind == .toolCall ? "shell" : nil, isDelta: false, toolInput: nil,
            isErrorOutput: false, eventID: UUID().uuidString, rawJSON: "")
    }

    /// prompt, 200 tool blocks, reply, prompt, reply
    private var session: [SessionTranscriptBuilder.LogicalBlock] {
        [block(.user, "first  prompt&#x20;\nsecond line")]
            + (0..<100).flatMap { _ in [block(.toolCall), block(.toolOut)] }
            + [block(.assistant, String(repeating: "a", count: 4000)), block(.user, "second"), block(.assistant)]
    }

    private func marks(_ roles: Set<TranscriptRoleFilter> = []) -> [TranscriptRail.Mark] {
        TranscriptRail.marks(blocks: session, promptBlocks: [0, 202], shownRoles: roles, source: .codex)
    }

    func testToolRunIsOneMarkAndPromptsKeepTheirRoom() {
        let marks = marks()
        XCTAssertEqual(marks.map(\.kind), [.prompt, .tools, .reply, .prompt, .reply])
        XCTAssertEqual(marks[1].blocks, 1...200)
        XCTAssertEqual(marks.first?.start, 0)
        XCTAssertEqual(marks.last?.end ?? 0, 1, accuracy: 1e-9)
        // 200 tool blocks take less room than the one long reply after them.
        XCTAssertLessThan(marks[1].end - marks[1].start, marks[2].end - marks[2].start)
        XCTAssertEqual(marks[3].ordinal, 2)
        XCTAssertEqual(marks[0].preview, "first prompt second line")
    }

    func testHiddenRoleTakesNoRoom() {
        let marks = marks([.user, .assistant, .errors])
        XCTAssertEqual(marks.map(\.kind), [.prompt, .other, .reply, .prompt, .reply])
        XCTAssertEqual(marks[1].start, marks[1].end)
    }

    func testPlaceOnRailMapsToBlock() {
        let marks = marks()
        // A prompt answers where it is drawn, its room or 7 points when its room is smaller, and
        // nowhere beside that: just past it, inside the tool run, is a tool block.
        let drawn = max(marks[0].end, 7.0 / 600)
        XCTAssertEqual(TranscriptRail.block(at: drawn - 0.001, length: 600, promptSize: 7, in: marks), 0)
        XCTAssertNil(TranscriptRail.prompt(at: drawn + 0.001, length: 600, promptSize: 7, in: marks))
        XCTAssertGreaterThan(TranscriptRail.block(at: drawn + 0.001, length: 600, promptSize: 7, in: marks) ?? 0, 0)
        // The middle of the tool run is a tool block near its middle.
        let middle = (marks[1].start + marks[1].end) / 2
        XCTAssertNil(TranscriptRail.prompt(at: middle, length: 600, promptSize: 7, in: marks))
        XCTAssertEqual(TranscriptRail.block(at: middle, length: 600, promptSize: 7, in: marks) ?? 0, 101, accuracy: 2)
        XCTAssertEqual(TranscriptRail.block(at: 1, length: 600, promptSize: 7, in: marks), 203)
        XCTAssertEqual(TranscriptRail.span(of: 150...201, in: marks), marks[1].start...marks[2].end)
        XCTAssertNil(TranscriptRail.span(of: 150...999, in: marks))
    }

    /// A nearby compaction or fork wins, then the prompt drawn there, then the mark there; a place with
    /// nothing to name has no target.
    func testTargetPrefersEventsThenPrompts() {
        let bar = TranscriptRail.byTurn(marks())
        let fork = TranscriptRail.Event(kind: .fork, block: 203, title: "Child")
        func target(_ fraction: Double) -> TranscriptRail.Target? {
            TranscriptRail.target(at: fraction, length: 600, promptSize: 7, marks: bar, events: [fork])
        }
        XCTAssertEqual(target(bar[4].start + 0.002), .event(fork))
        XCTAssertEqual(target(bar[3].start + 0.001), .mark(bar[3]))
        // Just before the prompt is the reply before it.
        XCTAssertEqual(target(bar[3].start - 0.001), .mark(bar[2]))
        XCTAssertEqual(target((bar[2].start + bar[2].end) / 2), .mark(bar[2]))
        XCTAssertEqual(target(bar[4].start + 0.002)?.block, 203)
        // A chat with no prompt at all still names its replies and tool runs (the rail showed
        // nothing there), and context alone names nothing.
        let noPrompts = TranscriptRail.marks(blocks: [block(.meta), block(.meta), block(.toolCall), block(.assistant, "done")],
                                             promptBlocks: [], shownRoles: [], source: .codex)
        XCTAssertEqual(noPrompts.map(\.kind), [.other, .tools, .reply])
        XCTAssertNil(TranscriptRail.target(at: noPrompts[0].end / 2, length: 600, promptSize: 7, marks: noPrompts, events: []))
        XCTAssertEqual(TranscriptRail.target(at: 0.99, length: 600, promptSize: 7, marks: noPrompts, events: []), .mark(noPrompts[2]))
    }

    /// A tool run names each of its calls when they have 2 points each, and itself when not.
    func testToolRunNamesItsCallsWhenTheyFit() {
        let short = TranscriptRail.marks(blocks: [block(.user), block(.toolCall), block(.toolOut), block(.toolCall), block(.toolOut),
                                                  block(.toolCall), block(.assistant, "done")],
                                         promptBlocks: [0], shownRoles: [], source: .codex)
        let run = short[1]
        XCTAssertEqual(run.calls, [1, 3, 5])
        XCTAssertTrue(TranscriptRail.showsCalls(run, length: 300))
        // The last third of the run is its third call, whose block a click goes to.
        let place = run.start + (run.end - run.start) * 0.9
        XCTAssertEqual(TranscriptRail.target(at: place, length: 300, promptSize: 7, marks: short, events: []), .call(run, 2))
        XCTAssertEqual(TranscriptRail.target(at: place, length: 300, promptSize: 7, marks: short, events: [])?.block, 5)
        XCTAssertEqual(TranscriptRail.place(ofCall: 1, in: run), (run.start + run.end) / 2, accuracy: 1e-9)
        // 100 calls in a sliver of a 300-point rail stay one mark; a click still lands on a call.
        let long = marks()
        XCTAssertFalse(TranscriptRail.showsCalls(long[1], length: 300))
        XCTAssertEqual(TranscriptRail.target(at: (long[1].start + long[1].end) / 2, length: 300, promptSize: 7, marks: long, events: []), .mark(long[1]))
        XCTAssertEqual(TranscriptRail.block(at: long[1].end - 1e-6, length: 300, promptSize: 7, in: long), 199)
    }

    func testMarksSayWhatTheyHold() {
        let marks = marks()
        XCTAssertEqual(marks[1].size, 100, "one per call, not per block")
        XCTAssertEqual(marks[1].calls.count, 100)
        XCTAssertEqual(marks[1].calls.first, 1)
        XCTAssertEqual(marks[1].preview, "shell")
        XCTAssertEqual(marks[2].size, 4000)
        XCTAssertEqual(marks[3].preview, "second")
    }

    /// In the bar a short turn after 200 tool blocks and a long reply still gets a slot of its own.
    func testBarGivesEveryTurnItsSlot() {
        let rail = marks()
        let bar = TranscriptRail.byTurn(rail)
        XCTAssertEqual(bar.map(\.blocks), rail.map(\.blocks))
        XCTAssertEqual(bar.first?.start, 0)
        XCTAssertEqual(bar.last?.end ?? 0, 1, accuracy: 1e-9)
        for (before, after) in zip(bar, bar.dropFirst()) { XCTAssertEqual(before.end, after.start, accuracy: 1e-9) }
        // The second turn (a prompt and a short reply) has a quarter of the bar, and its prompt
        // opens it; on the rail the whole turn has under a twentieth.
        XCTAssertGreaterThan(bar[4].end - bar[3].start, 0.25)
        XCTAssertGreaterThan(bar[3].end - bar[3].start, 0.02)
        XCTAssertLessThan(rail[4].end - rail[3].start, 0.05)
        // Context before the first prompt gets next to nothing.
        var leading = rail
        leading.insert(.init(blocks: -1...(-1), kind: .other, start: -0.01, end: 0), at: 0)
        XCTAssertLessThan(TranscriptRail.byTurn(leading)[0].end, 0.01)
        XCTAssertEqual(TranscriptRail.byTurn(leading).last?.end ?? 0, 1, accuracy: 1e-9)
        XCTAssertTrue(TranscriptRail.byTurn([]).isEmpty)
    }

    func testEventsSitBeforeTheFirstBlockWrittenAfterThem() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let blocks = (0..<10).map { index -> SessionTranscriptBuilder.LogicalBlock in
            var item = block(index == 0 ? .user : .assistant)
            item.timestamp = start.addingTimeInterval(Double(index) * 60)
            return item
        }
        let lineage = TranscriptRail.Lineage(
            sessionID: "s", compactions: [start.addingTimeInterval(150), start.addingTimeInterval(9_000)], forkedFrom: "Parent",
            forks: [.init(title: "Child", at: start.addingTimeInterval(299))])
        XCTAssertEqual(TranscriptRail.events(lineage, blocks: blocks), [
            .init(kind: .forkedFrom, block: 0, title: "Parent"),
            .init(kind: .compaction, block: 3),
            .init(kind: .fork, block: 5, title: "Child"),
            .init(kind: .compaction, block: 9, after: true),
        ])
        let marks = TranscriptRail.marks(blocks: blocks, promptBlocks: [0], shownRoles: [], source: .codex)
        XCTAssertEqual(TranscriptRail.place(of: .init(kind: .compaction, block: 9, after: true), in: marks) ?? 0, 1, accuracy: 1e-9)
        XCTAssertTrue(TranscriptRail.events(lineage, blocks: []).isEmpty)
    }

    /// The fork and compaction facts come from the first bytes of a rollout and of its lines.
    func testLineageReadsForksAndCompactionsFromRollouts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rail-lineage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let parentID = "01a19fb4-c66b-7910-bb97-5e10c53ede21", childID = "01a1a439-9b86-75b3-9c2e-9222873194f5"
        let parent = folder.appendingPathComponent("rollout-2026-11-03T10-00-00-\(parentID).jsonl")
        let child = folder.appendingPathComponent("rollout-2026-11-03T20-43-21-\(childID).jsonl")
        let filler = String(repeating: "x", count: 5_000)
        try [
            #"{"timestamp":"2026-11-03T15:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"session_id":"\#(parentID)","id":"\#(parentID)","timestamp":"2026-11-03T15:00:00.000Z","base_instructions":"\#(filler)"}}"#,
            #"{"timestamp":"2026-11-03T15:01:00.500Z","ordinal":1,"type":"response_item","payload":{"type":"message","role":"user"}}"#,
            #"{"timestamp":"2026-11-03T15:02:00.000Z","ordinal":2,"type":"compacted","payload":{"message":"","replacement_history":"\#(filler)"}}"#,
            #"{"timestamp":"2026-11-03T15:03:00Z","ordinal":3,"type":"response_item","payload":{"type":"message","role":"assistant"}}"#,
        ].joined(separator: "\n").write(to: parent, atomically: true, encoding: .utf8)
        try #"{"timestamp":"2026-11-04T01:43:21.246Z","ordinal":0,"type":"session_meta","payload":{"session_id":"\#(childID)","id":"\#(childID)","forked_from_id":"\#(parentID)","attached_thread":true,"forked_from_ordinal_exclusive":4,"timestamp":"2026-11-04T01:43:21.236Z","base_instructions":"\#(filler)"}}"#
            .write(to: child, atomically: true, encoding: .utf8)

        XCTAssertEqual(CodexLineage.threadID(ofPath: child.path), childID)
        XCTAssertNil(CodexLineage.fork(inHeadOf: parent))
        let fork = try XCTUnwrap(CodexLineage.fork(inHeadOf: child))
        XCTAssertEqual(fork.child, childID)
        XCTAssertEqual(fork.parent, parentID)
        XCTAssertEqual(fork.ordinal, 4)
        XCTAssertEqual(fork.created, CodexLineage.date("2026-11-04T01:43:21.246Z"))

        let scan = CodexLineage.scan(parent, ordinals: [3, 99])
        XCTAssertEqual(scan.compactions, [CodexLineage.date("2026-11-03T15:02:00.000Z")!])
        XCTAssertEqual(scan.lineTimes, [3: CodexLineage.date("2026-11-03T15:03:00Z")!])

        let index = CodexLineage.ForkIndex()
        let around = index.forks(around: parentID, rollouts: [parent.path, child.path])
        XCTAssertNil(around.own)
        XCTAssertEqual(around.children, [fork])
        XCTAssertEqual(index.forks(around: childID, rollouts: []).own, fork)
    }

    /// Draws both history views to PNG files for a look, when AS_RAIL_PREVIEW_DIR names a folder
    /// (pass it to xcodebuild as TEST_RUNNER_AS_RAIL_PREVIEW_DIR): a long chat, and a short one
    /// whose tool calls each have a line.
    @MainActor
    func testDrawsPreviewImages() throws {
        guard let folder = ProcessInfo.processInfo.environment["AS_RAIL_PREVIEW_DIR"], !folder.isEmpty else {
            throw XCTSkip("AS_RAIL_PREVIEW_DIR is not set")
        }
        /// A place two fifths into a mark.
        func inside(_ mark: TranscriptRail.Mark?) -> Double? { mark.map { $0.start + ($0.end - $0.start) * 0.4 } }
        func draw(_ name: String, turns: Int, calls: (Int) -> Int, pointAt: (TranscriptRailModel) -> (bar: Double?, rail: Double?)) throws {
        var blocks: [SessionTranscriptBuilder.LogicalBlock] = []
        var prompts = Set<Int>()
        for turn in 0..<turns {
            prompts.insert(blocks.count)
            blocks.append(block(.user, "Prompt number \(turn + 1): " + String(repeating: "please look into this ", count: turn == 4 ? 60 : 2)))
            for step in 0..<(turn % 3 + 1) {
                blocks += (0..<calls(turn)).flatMap { _ in [block(.toolCall), block(.toolOut)] }
                blocks.append(block(.assistant, String(repeating: "Here is what I found. ", count: 10 + 40 * step)))
            }
        }
        let model = TranscriptRailModel()
        model.marks = TranscriptRail.marks(blocks: blocks, promptBlocks: prompts, shownRoles: [], source: .codex)
        model.barMarks = TranscriptRail.byTurn(model.marks)
        model.describe = { "Ran rg -n \"history\" Sources (block \($0))" }
        model.matches = [12, 40, 41, 200, 420].filter { $0 < blocks.count }
        model.visible = (blocks.count / 3)...(blocks.count / 3 + blocks.count / 12)
        model.events = [.init(kind: .forkedFrom, block: 0, title: "Plan the release"), .init(kind: .compaction, block: blocks.count / 4),
                        .init(kind: .fork, block: blocks.count * 2 / 3, title: "Try the other layout"), .init(kind: .compaction, block: blocks.count - 1, after: true)]
        let pointed = pointAt(model)
        let onBar = try XCTUnwrap(pointed.bar), onRail = try XCTUnwrap(pointed.rail)
        let view = VStack(spacing: 0) {
            TranscriptHistoryBar(model: model)
            Divider()
            Color(nsColor: .textBackgroundColor)
                .overlay(alignment: .trailing) {
                    TranscriptRailView(model: model, pointerY: 4 + CGFloat(onRail) * 392)
                }
                .overlay(alignment: .topLeading) { TranscriptHistoryBarCard(model: model) }
                .frame(height: 400)
        }
        .frame(width: 700)
        for scheme in [ColorScheme.light, .dark] {
            // Set for each drawing: the bar clears it when it goes away.
            model.barPointerX = 12 + CGFloat(onBar) * 676
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(scheme == .light ? "light" : "dark").png"))
        }
        }
        // Long: the pointer on the long fifth prompt in the bar and on the last prompt in the rail.
        try draw("history", turns: 9, calls: { $0 * 7 + 3 }) { model in
            (inside(model.barMarks.first { $0.ordinal == 5 }), inside(model.marks.last { $0.kind == .prompt }))
        }
        // Short: the pointer on a tool call in each.
        try draw("history-short", turns: 2, calls: { $0 * 3 + 4 }) { model in
            (inside(model.barMarks.last { $0.kind == .tools }), inside(model.marks.first { $0.kind == .tools }))
        }
        // The pointer on a reply in the bar and on a tool run that does not show its calls in the rail.
        try draw("history-reply", turns: 9, calls: { $0 * 7 + 3 }) { model in
            (inside(model.barMarks.last { $0.kind == .reply && $0.blocks.upperBound < 130 }), inside(model.marks.last { $0.kind == .tools }))
        }
        // The pointer on a tool run that shows its number in the bar and on a reply in the rail.
        try draw("history-run", turns: 9, calls: { $0 * 7 + 3 }) { model in
            (inside(model.barMarks.first { $0.kind == .tools && $0.size == 45 }), inside(model.marks.last { $0.kind == .reply }))
        }
        // The pointer on the fork in the bar and on the compaction in the rail.
        try draw("history-flag", turns: 9, calls: { $0 * 7 + 3 }) { model in
            (model.events.first { $0.kind == .fork }.flatMap { TranscriptRail.place(of: $0, in: model.barMarks) },
             model.events.first { $0.kind == .compaction }.flatMap { TranscriptRail.place(of: $0, in: model.marks) })
        }
    }

    // MARK: Pages of a long chat

    /// Three pages of one chat, as Codex writes them: each later page names the one it continues
    /// and where it takes over, and what the earlier page held after that point was replaced.
    private func writePagedChat(in root: URL) throws -> (pages: [URL], cuts: [UInt64]) {
        let chat = "01a205b6-5bd9-7d40-9b50-74486e1d4537", second = "01a206c1-4877-7030-a8a8-119aab3f7c8f",
            third = "01a206c1-e2bb-7a13-b1b6-766715ee153d"
        func meta(_ time: String, base: String = "") -> String {
            "{\"timestamp\":\"\(time)\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(chat)\",\"timestamp\":\"\(time)\",\"cwd\":\"/tmp\",\"originator\":\"Codex Desktop\",\"history_mode\":\"paginated\"\(base)}}"
        }
        func message(_ time: String, _ role: String, _ text: String) -> String {
            "{\"timestamp\":\"\(time)\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"\(role)\",\"content\":[{\"type\":\"\(role == "user" ? "input_text" : "output_text")\",\"text\":\"\(text)\"}]}}"
        }
        func base(_ page: String, ordinal: Int, bytes: UInt64) -> String {
            ",\"history_base\":{\"thread_id\":\"\(page)\",\"end_ordinal_exclusive\":\(ordinal),\"end_byte_offset\":\(bytes)}"
        }
        /// Writes the lines and returns the size of the first `kept` of them.
        func write(_ lines: [String], kept: Int, to url: URL) throws -> UInt64 {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return UInt64(lines.prefix(kept).reduce(0) { $0 + $1.utf8.count + 1 })
        }
        let first = root.appendingPathComponent("2026/11/22/rollout-2026-11-22T19-02-46-\(chat).jsonl")
        let firstCut = try write([meta("2026-11-22T19:02:46.000Z"),
                                  message("2026-11-22T19:02:47.000Z", "user", "prompt one"),
                                  message("2026-11-22T19:03:00.000Z", "assistant", "reply one"),
                                  message("2026-11-22T23:51:00.000Z", "user", "prompt two, first try"),
                                  message("2026-11-22T23:52:00.000Z", "assistant", "abandoned work")], kept: 3, to: first)
        let middle = root.appendingPathComponent("2026/11/22/rollout-2026-11-22T23-54-59-\(chat)_\(second).jsonl")
        let middleCut = try write([meta("2026-11-22T23:54:59.000Z", base: base(chat, ordinal: 3, bytes: firstCut)),
                                   message("2026-11-22T23:55:00.000Z", "user", "prompt two"),
                                   message("2026-11-22T23:56:00.000Z", "assistant", "reply two"),
                                   message("2026-11-23T09:42:00.000Z", "user", "prompt three, first try")], kept: 3, to: middle)
        let last = root.appendingPathComponent("2026/11/23/rollout-2026-11-23T11-41-54-\(chat)_\(third).jsonl")
        _ = try write([meta("2026-11-23T11:41:54.000Z", base: base(second, ordinal: 6, bytes: middleCut)),
                       message("2026-11-23T11:41:58.000Z", "user", "prompt three"),
                       message("2026-11-23T11:43:00.000Z", "assistant", "reply three")], kept: 3, to: last)
        return ([first, middle, last], [firstCut, middleCut])
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSessions-Pages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testALaterPageNamesThePagesItContinues() throws {
        let (pages, cuts) = try writePagedChat(in: temporaryRoot())
        XCTAssertNil(CodexLineage.historyBase(inHeadOf: pages[0]))
        XCTAssertEqual(CodexLineage.historyBase(inHeadOf: pages[2]),
                       CodexLineage.HistoryBase(page: "01a206c1-4877-7030-a8a8-119aab3f7c8f", endOrdinal: 6, endByteOffset: cuts[1]))
        // Found in the day folders, oldest first, each with its cut in bytes and in its own lines.
        let found = CodexLineage.basePages(of: pages[2], rollouts: [])
        XCTAssertEqual(found.map(\.url.lastPathComponent), [pages[0].lastPathComponent, pages[1].lastPathComponent])
        XCTAssertEqual(found.map(\.byteCount), cuts)
        XCTAssertEqual(found.map(\.lineCount), [3, 3])
        XCTAssertEqual(CodexLineage.basePages(of: pages[2], rollouts: pages.map(\.path)), found)
        XCTAssertEqual(CodexLineage.basePages(of: pages[1], rollouts: []).map(\.url.lastPathComponent), [pages[0].lastPathComponent])
        XCTAssertEqual(CodexLineage.basePages(of: pages[0], rollouts: []), [])
        // A page that is gone ends the run: nothing older is joined across the gap.
        try FileManager.default.removeItem(at: pages[1])
        XCTAssertEqual(CodexLineage.basePages(of: pages[2], rollouts: []), [])
    }

    /// Opening the newest page shows the chat from its first prompt, without the attempts that
    /// were replaced; the file read on its own (the list, the index) is unchanged.
    func testOpeningTheNewestPageShowsTheWholeChat() throws {
        let (pages, _) = try writePagedChat(in: temporaryRoot())
        let indexer = SessionIndexer()
        let alone = try XCTUnwrap(indexer.parseFileFull(at: pages[2]))
        func said(_ session: Session) -> [String] {
            session.events.filter { $0.kind == .user || $0.kind == .assistant }.compactMap(\.text)
        }
        XCTAssertEqual(said(alone), ["prompt three", "reply three"])
        indexer.installSessionsForReloadTesting([alone])
        indexer.reloadSession(id: alone.id, force: true, reason: .manualRefresh)
        XCTAssertTrue(indexer.waitForReloadToFinishForTesting(id: alone.id, timeout: 10))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let row = try XCTUnwrap(indexer.allSessions.first { $0.id == alone.id })
        XCTAssertEqual(said(row), said(alone), "Search and the session list still see the selected file")
        let whole = row.transcriptPresentation
        XCTAssertEqual(said(whole), ["prompt one", "reply one", "prompt two", "reply two", "prompt three", "reply three"])
        XCTAssertEqual(Set(whole.events.map(\.id)).count, whole.events.count)
        XCTAssertEqual(whole.events.compactMap(\.timestamp).min(), CodexLineage.date("2026-11-22T19:02:46.000Z"))
        XCTAssertEqual(whole.filePath, pages[2].path)
    }

    /// A real table fills the rail, reports the blocks on screen, and takes a jump to a prompt
    /// outside the 400 blocks it loads first.
    @MainActor
    func testTableFillsTheRailAndTakesItsJumps() {
        let blocks = TranscriptTestFixtures.sequence((0..<600).map { block($0 % 50 == 0 ? .user : .assistant, "block \($0)") })
        let controller = BlockTableController()
        let views = BlockTableController.makeScrollView(selectionOwner: controller)
        let frame = NSRect(x: 0, y: 0, width: 640, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        views.scroll.frame = frame
        window.contentView = views.scroll
        controller.attach(table: views.table, scroll: views.scroll)
        let rail = TranscriptRailModel()
        controller.railModel = rail
        func settle() {
            views.table.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        controller.apply(allBlocks: blocks, totalBlockCount: blocks.count, fontSize: 13, source: .codex, sessionID: "rail")
        controller.scheduleRailPublish()
        settle()
        XCTAssertEqual(rail.marks.filter { $0.kind == .prompt }.map(\.blocks.lowerBound), Array(stride(from: 0, to: 600, by: 50)))
        XCTAssertEqual(rail.visible?.upperBound, 599, "a session opens at its end")

        rail.jump(0, false)
        settle()
        XCTAssertEqual(rail.visible?.lowerBound, 0)

        rail.jump(450, true)
        settle()
        XCTAssertEqual(rail.visible?.lowerBound, 450)
        controller.tearDown()
    }

    /// A mouse click on the drawn rail reaches the jump, and lands on the prompt it is on.
    @MainActor
    func testClickOnThePromptMarkJumpsToIt() {
        let model = TranscriptRailModel()
        model.marks = marks()
        var jumps: [Int] = []
        model.jump = { block, _ in jumps.append(block) }
        let frame = NSRect(x: 0, y: 0, width: TranscriptRailView.width, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: TranscriptRailView(model: model))
        host.frame = frame
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let prompt = model.marks[3]
        let fromTop = 4 + CGFloat((prompt.start + prompt.end) / 2) * 592
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 15, y: 600 - fromTop), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.orderOut(nil)
        XCTAssertEqual(jumps, [202])
    }
}

