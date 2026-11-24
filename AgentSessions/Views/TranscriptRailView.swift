import SwiftUI

/// Where the Session view draws the session's history: the rail down the side, the bar across
/// the top, both, or neither.
enum TranscriptHistoryPlacement: String, CaseIterable {
    case side, top, both, none

    var showsRail: Bool { self == .side || self == .both }
    var showsBar: Bool { self == .top || self == .both }

    /// The toolbar button draws the current choice.
    var symbol: String {
        switch self {
        case .side: return "rectangle.rightthird.inset.filled"
        case .top: return "rectangle.topthird.inset.filled"
        case .both: return "rectangle.inset.topright.filled"
        case .none: return "rectangle"
        }
    }
}

/// A small button on the history itself that moves it to the other place: at the top of the rail
/// it moves the history to the bar, at the right end of the bar it moves it to the rail. It draws
/// an arrow that makes the move: up the rail and left across the top, or right along the bar and
/// down the side. The toolbar menu still offers every choice.
struct TranscriptHistoryFlipButton: View {
    /// Its width at the end of the bar, and its height at the top of the rail.
    static let size: CGFloat = 30

    /// Where the button moves the history to: top or side.
    let destination: TranscriptHistoryPlacement
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: destination == .top ? "arrow.turn.up.left" : "arrow.turn.right.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(isHovered ? 0.14 : 0.06)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }

    private var label: Text {
        destination == .top
            ? Text("Show the history across the top", comment: "Tooltip and accessibility label of the small button at the top of the history strip beside the transcript: it moves the session history to a bar across the top of the transcript.")
            : Text("Show the history down the side", comment: "Tooltip and accessibility label of the small button at the right end of the history bar above the transcript: it moves the session history to a strip down the right side of the transcript.")
    }
}

/// The history views of the Session view: the whole session drawn as marks, first block first.
/// The rail runs down the right of the transcript and gives each block room in proportion to its
/// text, like the scroll bar. The bar runs across the top and gives each turn its own slot, so it
/// can show more. In both, prompts are drawn large because they are what a reader aims for, and
/// tool calls are squeezed.
enum TranscriptRail {
    typealias Block = SessionTranscriptBuilder.LogicalBlock

    enum Kind: Equatable { case prompt, reply, tools, error, other }

    struct Mark: Equatable {
        /// Global block indices the mark stands for.
        var blocks: ClosedRange<Int>
        var kind: Kind
        /// Position along the view, 0 at the first block and 1 after the last.
        var start: Double
        var end: Double
        /// Prompts: 1-based position among the prompts.
        var ordinal = 0
        /// Prompts and replies: the start of the text. Tool runs: the first tool names.
        var preview = ""
        /// Prompts and replies: bytes of text. Tool runs: number of calls.
        var size = 0
        /// Tool runs: the block of each call, in order.
        var calls: [Int] = []
    }

    /// Something that happened to the session between two blocks.
    struct Event: Equatable {
        enum Kind: Equatable { case compaction, forkedFrom, fork }
        var kind: Kind
        /// The block it sits before, or after when `after` is set (nothing was written since).
        var block: Int
        var after = false
        /// Forks: the other chat's title.
        var title = ""
    }

    /// What a session's files say happened to it, with times; `events` places it on blocks.
    struct Lineage: Equatable {
        struct ForkPoint: Equatable {
            var title: String
            var at: Date
        }
        var sessionID = ""
        var compactions: [Date] = []
        /// Title of the chat this one was forked from.
        var forkedFrom: String?
        var forks: [ForkPoint] = []
    }

    /// The least width, in points, the bar draws a prompt at.
    static let barPromptSize: CGFloat = 7

    /// The height, in points, of the bar the rail draws at the start of each prompt: 7, less when
    /// there are so many prompts that the bars would merge.
    static func railPromptSize(length: CGFloat, in marks: [Mark]) -> CGFloat {
        let prompts = marks.reduce(0) { $1.kind == .prompt ? $0 + 1 : $0 }
        return max(2, min(7, length / (CGFloat(max(prompts, 1)) * 1.5)))
    }

    /// One mark per prompt, reply and error, and one per run of anything else. The prompt blocks
    /// are the ones the User chip's arrows stop at. A role the chips hide gets no room.
    static func marks(blocks: [Block], promptBlocks: Set<Int>, shownRoles: Set<TranscriptRoleFilter>,
                      source: SessionSource) -> [Mark] {
        func shown(_ role: TranscriptRoleFilter) -> Bool { shownRoles.isEmpty || shownRoles.contains(role) }
        func firstWords(_ text: String) -> String {
            // Codex writes a trailing space in a typed line as the entity.
            String(text.prefix(400)).replacingOccurrences(of: "&#x20;", with: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        var marks: [Mark] = []
        var position = 0.0
        var prompts = 0
        for (index, block) in blocks.enumerated() {
            let role = TranscriptRoleFilter.governing(block, source: source)
            // About the lines the block's card takes: its header plus its text.
            let lines = 1.5 + min(Double(block.text.utf8.count) / 100, 400)
            var kind = Kind.other
            var weight = 0.5
            if promptBlocks.contains(index) {
                (kind, weight) = (.prompt, lines)
            } else if role == .assistant {
                (kind, weight) = (.reply, lines)
            } else if role == .tools {
                (kind, weight) = (.tools, 1.5)
            } else if role == .errors {
                (kind, weight) = (.error, 2)
            }
            if let role, !shown(role) { (kind, weight) = (.other, 0) }
            let end = position + weight
            let tool = kind == .tools && block.kind == .toolCall ? (block.toolName ?? "") : nil
            if kind == .tools || kind == .other, let last = marks.indices.last, marks[last].kind == kind {
                marks[last].blocks = marks[last].blocks.lowerBound...index
                // A run of tool blocks grows with the square root of its length, so a long run stays small.
                marks[last].end = kind == .tools ? marks[last].start + 1.5 * Double(marks[last].blocks.count).squareRoot() : end
                position = marks[last].end
                if let tool {
                    marks[last].size += 1
                    marks[last].calls.append(index)
                    let names = marks[last].preview.components(separatedBy: ", ")
                    if !tool.isEmpty, !names.contains(tool), names.count < 4 {
                        marks[last].preview += marks[last].preview.isEmpty ? tool : ", " + tool
                    }
                }
            } else {
                var mark = Mark(blocks: index...index, kind: kind, start: position, end: end)
                switch kind {
                case .prompt:
                    prompts += 1
                    mark.ordinal = prompts
                    mark.preview = firstWords(block.typedText)
                    mark.size = block.typedText.utf8.count
                case .reply:
                    mark.preview = firstWords(block.text)
                    mark.size = block.text.utf8.count
                case .tools:
                    if let tool { (mark.preview, mark.size, mark.calls) = (tool, 1, [index]) }
                case .error:
                    mark.preview = firstWords(block.text)
                case .other:
                    break
                }
                marks.append(mark)
                position = end
            }
        }
        guard position > 0 else { return [] }
        for index in marks.indices {
            marks[index].start /= position
            marks[index].end /= position
        }
        return marks
    }

    /// The same marks laid out for the bar: every turn (a prompt and what follows it) gets its own
    /// slot, wider for a longer turn but only by its logarithm, and the prompt opens the slot. A
    /// prompt after 300 tool calls is then as easy to hit as one after a short reply.
    static func byTurn(_ marks: [Mark]) -> [Mark] {
        var turns: [Range<Int>] = []
        var first = 0
        for index in marks.indices where marks[index].kind == .prompt && index > first {
            turns.append(first..<index)
            first = index
        }
        if first < marks.count { turns.append(first..<marks.count) }
        func room(_ mark: Mark) -> Double { mark.end - mark.start }
        let weights = turns.map { turn -> Double in
            let content = marks[turn].reduce(0) { $0 + room($1) }
            // Nothing to draw (the context before the first prompt): next to no room.
            guard marks[turn].contains(where: { $0.kind != .other }) else { return content > 0 ? 0.02 : 0 }
            // An average turn weighs 2, one eight times as long about 4.
            return 1 + log2(1 + content * Double(turns.count))
        }
        let total = weights.reduce(0, +)
        var result = marks
        var position = 0.0
        for (turn, weight) in zip(turns, weights) {
            var inner = marks[turn].map { room($0).squareRoot() }
            if marks[turn.lowerBound].kind == .prompt {
                // A tenth to a fifth of what follows it, by its length; the whole slot when nothing follows.
                let rest = inner.dropFirst().reduce(0, +)
                inner[0] = rest > 0 ? rest * (0.1 + 0.1 * min(1, Double(marks[turn.lowerBound].size) / 2000)) : 1
            }
            let scale = weight / total / max(inner.reduce(0, +), 1e-12)
            for (offset, index) in turn.enumerated() {
                result[index].start = position
                position += inner[offset] * scale
                result[index].end = position
            }
        }
        return result
    }

    /// Places what happened to the session on its blocks: each thing sits before the first block
    /// written after it.
    static func events(_ lineage: Lineage, blocks: [Block]) -> [Event] {
        guard !blocks.isEmpty else { return [] }
        func event(_ kind: Event.Kind, at date: Date, title: String = "") -> Event {
            if let block = blocks.firstIndex(where: { ($0.timestamp ?? .distantPast) > date }) {
                return Event(kind: kind, block: block, title: title)
            }
            return Event(kind: kind, block: blocks.count - 1, after: true, title: title)
        }
        var events = lineage.compactions.map { event(.compaction, at: $0) }
        events += lineage.forks.map { event(.fork, at: $0.at, title: $0.title) }
        if let parent = lineage.forkedFrom { events.append(Event(kind: .forkedFrom, block: 0, title: parent)) }
        return events.sorted { ($0.block, $0.after ? 1 : 0) < ($1.block, $1.after ? 1 : 0) }
    }

    /// The mark holding a block, by binary search (marks are ascending and cover every block).
    static func mark(holding block: Int, in marks: [Mark]) -> Mark? {
        var low = 0, high = marks.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if marks[middle].blocks.upperBound < block { low = middle + 1 }
            else if marks[middle].blocks.lowerBound > block { high = middle - 1 }
            else { return marks[middle] }
        }
        return nil
    }

    /// Where a range of blocks sits, as fractions.
    static func span(of blocks: ClosedRange<Int>, in marks: [Mark]) -> ClosedRange<Double>? {
        guard let first = mark(holding: blocks.lowerBound, in: marks),
              let last = mark(holding: blocks.upperBound, in: marks) else { return nil }
        return first.start...max(first.start, last.end)
    }

    /// Where an event sits, as a fraction.
    static func place(of event: Event, in marks: [Mark]) -> Double? {
        mark(holding: event.block, in: marks).map { event.after ? $0.end : $0.start }
    }

    /// The prompt drawn at a place on a view of the given length: its own room, or promptSize
    /// points from its start when it is drawn larger than its room. Nothing beside what is drawn.
    static func prompt(at fraction: Double, length: CGFloat, promptSize: CGFloat, in marks: [Mark]) -> Mark? {
        let least = Double(promptSize / max(length, 1))
        return marks.last { $0.kind == .prompt && $0.start <= fraction && fraction < max($0.end, $0.start + least) }
    }

    /// The mark at a place.
    static func mark(at fraction: Double, in marks: [Mark]) -> Mark? {
        marks.last(where: { $0.start <= fraction && $0.end > $0.start }) ?? marks.first
    }

    /// Whether each call of a tool run gets a line of its own on a view of the given length:
    /// they do when there are at least 2 points for each.
    static func showsCalls(_ mark: Mark, length: CGFloat) -> Bool {
        mark.kind == .tools && !mark.calls.isEmpty && CGFloat(mark.end - mark.start) * length >= 2 * CGFloat(mark.calls.count)
    }

    /// Where a call of a tool run sits: the calls share the run's room evenly.
    static func place(ofCall index: Int, in mark: Mark) -> Double {
        mark.start + (Double(index) + 0.5) / Double(max(mark.calls.count, 1)) * (mark.end - mark.start)
    }

    /// The call of a tool run at a place.
    static func call(at fraction: Double, in mark: Mark) -> Int {
        let within = (fraction - mark.start) / max(mark.end - mark.start, 1e-12)
        return min(max(Int(within * Double(mark.calls.count)), 0), mark.calls.count - 1)
    }

    /// The block a click goes to: the prompt drawn there, else the block (in a tool run, the call) at that place.
    static func block(at fraction: Double, length: CGFloat, promptSize: CGFloat, in marks: [Mark]) -> Int? {
        if let prompt = prompt(at: fraction, length: length, promptSize: promptSize, in: marks) { return prompt.blocks.lowerBound }
        guard let mark = mark(at: fraction, in: marks) else { return nil }
        if !mark.calls.isEmpty { return mark.calls[call(at: fraction, in: mark)] }
        let within = (fraction - mark.start) / (mark.end - mark.start)
        let offset = Int(Double(mark.blocks.count) * min(max(within, 0), 1))
        return min(mark.blocks.lowerBound + offset, mark.blocks.upperBound)
    }

    static func color(of kind: Event.Kind) -> Color {
        // Not purple: that is the color of tool calls.
        kind == .compaction ? Color(nsColor: .systemOrange) : Color(nsColor: .systemTeal)
    }

    /// Tool calls have the color of the Tools chip and of their rows in the transcript.
    static var toolColor: Color { TranscriptColorSystem.semanticAccent(.toolCall) }

    /// What a place on the rail or the bar stands for.
    enum Target: Equatable {
        case mark(Mark)
        case event(Event)
        /// One call of a tool run, by its position in `calls`.
        case call(Mark, Int)

        var block: Int {
            switch self {
            case .mark(let mark): return mark.blocks.lowerBound
            case .event(let event): return event.block
            case .call(let mark, let index): return mark.calls[index]
            }
        }
    }

    /// A compaction or fork within 5 points, else the prompt drawn there, else the mark there:
    /// one call of a tool run when the run shows its calls, nothing where there is nothing to name.
    static func target(at fraction: Double, length: CGFloat, promptSize: CGFloat, marks: [Mark], events: [Event]) -> Target? {
        let reach = Double(5 / max(length, 1))
        let near = events
            .compactMap { event in place(of: event, in: marks).map { (event, abs($0 - fraction)) } }
            .filter { $0.1 <= reach }
            .min { $0.1 < $1.1 }
        if let near { return .event(near.0) }
        if let prompt = prompt(at: fraction, length: length, promptSize: promptSize, in: marks) { return .mark(prompt) }
        guard let mark = mark(at: fraction, in: marks), mark.kind != .other else { return nil }
        return showsCalls(mark, length: length) ? .call(mark, call(at: fraction, in: mark)) : .mark(mark)
    }
}

/// What the table tells the history views. Only they read it, so a scroll redraws them alone.
@Observable
final class TranscriptRailModel {
    /// Laid out for the rail and for the bar.
    var marks: [TranscriptRail.Mark] = []
    var barMarks: [TranscriptRail.Mark] = []
    /// Blocks on screen.
    var visible: ClosedRange<Int>?
    /// Blocks with a Find or search match, ascending.
    var matches: [Int] = []
    /// Compactions and forks, ascending.
    var events: [TranscriptRail.Event] = []
    /// Where the pointer is over the bar, in the bar's coordinates.
    var barPointerX: CGFloat?
    /// Scrolls the table to a block; the flash is for a click, not for a drag.
    @ObservationIgnored var jump: (_ block: Int, _ flash: Bool) -> Void = { _, _ in }
    /// What a tool call does, as its row in the transcript says it ("Ran ls").
    @ObservationIgnored var describe: (_ block: Int) -> String = { _ in "" }
}

// MARK: - Rail

/// The card both history views show for what the pointer is on: what it is, then its first words.
struct TranscriptRailCard: View {
    static let outerWidth: CGFloat = 316
    /// Room to keep free under the card's top edge so it stays inside the pane.
    static let maxHeight: CGFloat = 96

    let title: Text
    let text: String

    init(_ target: TranscriptRail.Target, in marks: [TranscriptRail.Mark], describe: (Int) -> String) {
        switch target {
        case .mark(let mark): (title, text) = (TranscriptRailText.title(for: mark, in: marks), mark.preview)
        case .event(let event): (title, text) = (TranscriptRailText.title(for: event), "")
        case .call(let mark, let index):
            title = Text("Tool call \(index + 1) of \(mark.calls.count)",
                         comment: "History views of the transcript: which call of a run of tool calls the pointer is on, for example Tool call 3 of 12. %1$lld is its position; %2$lld is the number of calls in the run.")
            let said = describe(mark.calls[index])
            text = said.isEmpty ? mark.preview : said
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title.font(.caption.weight(.semibold))
            if !text.isEmpty { Text(verbatim: text).font(.caption).lineLimit(4) }
        }
        .frame(width: Self.outerWidth - 16, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Surface.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .allowsHitTesting(false)
    }
}

struct TranscriptRailView: View {
    /// A gutter for the tool-call counts, then the marks.
    static let width: CGFloat = 38
    private static let inset: CGFloat = 4

    let model: TranscriptRailModel
    @State private var pointerY: CGFloat?
    @State private var isDragging = false

    /// `pointerY` shows the card without a pointer, for previews and tests.
    init(model: TranscriptRailModel, pointerY: CGFloat? = nil) {
        self.model = model
        _pointerY = State(initialValue: pointerY)
    }

    var body: some View {
        GeometryReader { geometry in
            let height = max(geometry.size.height - 2 * Self.inset, 1)
            ZStack(alignment: .topLeading) {
                TranscriptRailMarks(marks: model.marks, matches: model.matches, events: model.events)
                viewport(height: height)
                TranscriptRailHighlight(target: target(height: height), marks: model.marks)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let fraction = Double((value.location.y - Self.inset) / height)
                    if let block = TranscriptRail.block(at: min(max(fraction, 0), 1), length: height,
                                                        promptSize: TranscriptRail.railPromptSize(length: height, in: model.marks), in: model.marks) {
                        model.jump(block, !isDragging)
                    }
                    isDragging = true
                }
                .onEnded { _ in isDragging = false })
            .onContinuousHover { phase in
                if case .active(let point) = phase { pointerY = point.y } else { pointerY = nil }
            }
            .overlay(alignment: .topLeading) { card(height: height) }
        }
        .frame(width: Self.width)
        .background(Color.primary.opacity(0.03))
        .accessibilityElement()
        .accessibilityLabel(Text("Session history", comment: "Accessibility label of the strip beside the transcript that shows the whole session and jumps to a prompt."))
        .accessibilityValue(currentPrompt.map { TranscriptRailText.promptTitle($0, in: model.marks) } ?? Text(verbatim: ""))
        .accessibilityAdjustableAction { direction in
            let prompts = model.marks.filter { $0.kind == .prompt }
            let current = currentPrompt?.ordinal ?? 0
            let next = direction == .increment ? current + 1 : current - 1
            if let target = prompts.first(where: { $0.ordinal == next }) { model.jump(target.blocks.lowerBound, true) }
        }
    }

    /// The last prompt at or above the top of the screen.
    private var currentPrompt: TranscriptRail.Mark? {
        guard let top = model.visible?.lowerBound else { return nil }
        return model.marks.last { $0.kind == .prompt && $0.blocks.lowerBound <= top }
    }

    @ViewBuilder
    private func viewport(height: CGFloat) -> some View {
        if let visible = model.visible, let span = TranscriptRail.span(of: visible, in: model.marks) {
            let length = max(CGFloat(span.upperBound - span.lowerBound) * height, 12)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Color.secondary.opacity(0.6), lineWidth: 1))
                .frame(width: Self.width - 4, height: length)
                .offset(x: 2, y: min(Self.inset + CGFloat(span.lowerBound) * height, Self.inset + height - length))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func card(height: CGFloat) -> some View {
        if let pointerY, let target = target(height: height) {
            TranscriptRailCard(target, in: model.marks, describe: model.describe)
                // Wholly left of the rail, over the transcript, level with the pointer and inside the pane.
                .offset(x: -(TranscriptRailCard.outerWidth + 6),
                        y: min(max(0, pointerY - 14), max(0, height - TranscriptRailCard.maxHeight)))
        }
    }

    private func target(height: CGFloat) -> TranscriptRail.Target? {
        pointerY.flatMap {
            TranscriptRail.target(at: Double(($0 - Self.inset) / height), length: height,
                                  promptSize: TranscriptRail.railPromptSize(length: height, in: model.marks),
                                  marks: model.marks, events: model.events)
        }
    }

    fileprivate static func y(_ fraction: Double, in size: CGSize) -> CGFloat {
        inset + CGFloat(fraction) * max(size.height - 2 * inset, 1)
    }

    /// Where a mark is drawn: its room along the rail less a gap, never shorter than minHeight.
    fileprivate static func rect(_ mark: TranscriptRail.Mark, in size: CGSize, x: CGFloat, width: CGFloat, minHeight: CGFloat, gap: CGFloat) -> CGRect {
        let top = y(mark.start, in: size)
        let bottom = y(mark.end, in: size)
        return CGRect(x: x, y: top, width: width, height: max(bottom - top - gap, minHeight))
    }
}

/// What the pointer is on in the rail, drawn a little wider and in full color, so the rail shows
/// what a click would go to. Its own view, so the pointer moving redraws only this.
private struct TranscriptRailHighlight: View {
    let target: TranscriptRail.Target?
    let marks: [TranscriptRail.Mark]

    var body: some View {
        Canvas { context, size in
            switch target {
            case .call(let mark, let index)?:
                let y = TranscriptRailView.y(TranscriptRail.place(ofCall: index, in: mark), in: size)
                context.fill(Path(roundedRect: CGRect(x: 17, y: y - 1.5, width: 17, height: 3), cornerRadius: 1), with: .color(TranscriptRail.toolColor))
            case .mark(let mark)?:
                func wider(minHeight: CGFloat) -> Path {
                    Path(roundedRect: TranscriptRailView.rect(mark, in: size, x: 18, width: 15, minHeight: minHeight, gap: 1), cornerRadius: 1.5)
                }
                switch mark.kind {
                case .prompt:
                    let barHeight = TranscriptRail.railPromptSize(length: size.height - 8, in: marks)
                    let promptColor: Color = TranscriptColorSystem.semanticAccent(.user)
                    let room = TranscriptRailView.rect(mark, in: size, x: 11, width: 27, minHeight: barHeight, gap: 1)
                    context.fill(Path(roundedRect: room, cornerRadius: 1.5), with: .color(promptColor.opacity(0.3)))
                    context.fill(Path(roundedRect: CGRect(x: room.minX, y: room.minY - 1.5, width: room.width, height: barHeight + 3), cornerRadius: 2),
                                 with: .color(promptColor))
                case .reply:
                    context.fill(wider(minHeight: 2), with: .color(TranscriptColorSystem.semanticAccent(.assistant)))
                case .tools:
                    context.fill(wider(minHeight: 2), with: .color(Color.secondary.opacity(0.85)))
                case .error:
                    context.fill(wider(minHeight: 3), with: .color(TranscriptColorSystem.semanticAccent(.error)))
                case .other:
                    break
                }
            case .event(let event)?:
                guard let place = TranscriptRail.place(of: event, in: marks) else { break }
                let y = TranscriptRailView.y(place, in: size)
                context.fill(Path(CGRect(x: 0, y: y - 2, width: size.width, height: 3.5)), with: .color(TranscriptRail.color(of: event.kind)))
            case nil:
                break
            }
        }
        .allowsHitTesting(false)
    }
}

/// The marks alone, so scrolling (which moves only the viewport box) does not redraw them.
private struct TranscriptRailMarks: View {
    let marks: [TranscriptRail.Mark]
    let matches: [Int]
    let events: [TranscriptRail.Event]

    var body: some View {
        Canvas { context, size in
            let prompts = marks.filter { $0.kind == .prompt }
            func rect(_ mark: TranscriptRail.Mark, x: CGFloat, width: CGFloat, minHeight: CGFloat, gap: CGFloat) -> CGRect {
                TranscriptRailView.rect(mark, in: size, x: x, width: width, minHeight: minHeight, gap: gap)
            }
            for mark in marks {
                switch mark.kind {
                case .reply:
                    context.fill(Path(rect(mark, x: 21, width: 9, minHeight: 1, gap: 1)),
                                 with: .color(TranscriptColorSystem.semanticAccent(.assistant).opacity(0.4)))
                case .tools:
                    // A gray band for the run; on it one line per call when they fit; beside it
                    // the number of calls when there is room for a digit.
                    let band = rect(mark, x: 21, width: 9, minHeight: 1, gap: 1)
                    context.fill(Path(roundedRect: band, cornerRadius: 1.5), with: .color(Color.secondary.opacity(0.3)))
                    if TranscriptRail.showsCalls(mark, length: size.height - 8) {
                        for index in mark.calls.indices {
                            let y = TranscriptRailView.y(TranscriptRail.place(ofCall: index, in: mark), in: size)
                            context.fill(Path(CGRect(x: band.minX, y: y - 0.5, width: band.width, height: 1)), with: .color(TranscriptRail.toolColor))
                        }
                    }
                    if band.height >= 10, mark.size > 0 {
                        context.draw(Text(verbatim: "\(mark.size)").font(.system(size: mark.size > 99 ? 7 : 8, weight: .medium)),
                                     at: CGPoint(x: 12, y: band.midY), anchor: .trailing)
                    }
                case .error:
                    context.fill(Path(rect(mark, x: 21, width: 9, minHeight: 2, gap: 0)),
                                 with: .color(TranscriptColorSystem.semanticAccent(.error)))
                case .prompt, .other:
                    break
                }
            }
            // Prompts on top: a tint over the room the prompt takes, and at its start a bar that
            // is never thinner than the pointer can hit, until there are so many that the bars
            // would merge.
            let barHeight = TranscriptRail.railPromptSize(length: size.height - 8, in: marks)
            let promptColor: Color = TranscriptColorSystem.semanticAccent(.user)
            for mark in prompts {
                let room = rect(mark, x: 14, width: 23, minHeight: barHeight, gap: 1)
                context.fill(Path(roundedRect: room, cornerRadius: 1.5), with: .color(promptColor.opacity(0.25)))
                context.fill(Path(roundedRect: CGRect(x: room.minX, y: room.minY, width: room.width, height: barHeight), cornerRadius: 1.5),
                             with: .color(promptColor))
            }
            for event in events {
                guard let place = TranscriptRail.place(of: event, in: marks) else { continue }
                let y = TranscriptRailView.y(place, in: size)
                context.fill(Path(CGRect(x: 1, y: y - 1, width: size.width - 2, height: 1.5)),
                             with: .color(TranscriptRail.color(of: event.kind)))
            }
            var lastDot: CGFloat = -10
            for block in matches {
                guard let mark = TranscriptRail.mark(holding: block, in: marks) else { continue }
                let y = TranscriptRailView.y((mark.start + mark.end) / 2, in: size)
                guard y - lastDot >= 3 else { continue }
                lastDot = y
                context.fill(Path(ellipseIn: CGRect(x: size.width - 6, y: y - 2, width: 4, height: 4)), with: .color(.yellow))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Bar

/// The history bar across the top of the transcript: one slot per turn, tool runs in the same row
/// as the messages, compactions and forks as flags. `TranscriptHistoryBarCard` says what the pointer is on.
struct TranscriptHistoryBar: View {
    static let height: CGFloat = 50
    fileprivate static let inset: CGFloat = 12
    private static let stripHeight: CGFloat = 42

    let model: TranscriptRailModel
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - 2 * Self.inset, 1)
            ZStack(alignment: .topLeading) {
                TranscriptHistoryBarMarks(marks: model.barMarks, matches: model.matches, events: model.events)
                viewport(width: width)
                TranscriptHistoryBarHighlight(model: model, width: width)
            }
            .frame(height: Self.stripHeight)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let fraction = min(max(Double((value.location.x - Self.inset) / width), 0), 1)
                    // A click goes to what the card names; a drag follows the pointer.
                    let named = isDragging ? nil : TranscriptRail.target(at: fraction, length: width, promptSize: TranscriptRail.barPromptSize,
                                                                         marks: model.barMarks, events: model.events)?.block
                    let block = named ?? TranscriptRail.block(at: fraction, length: width, promptSize: TranscriptRail.barPromptSize, in: model.barMarks)
                    if let block { model.jump(block, !isDragging) }
                    isDragging = true
                }
                .onEnded { _ in isDragging = false })
            .onContinuousHover { phase in
                if case .active(let point) = phase { model.barPointerX = point.x } else { model.barPointerX = nil }
            }
            .padding(.top, 4)
        }
        .frame(height: Self.height)
        .background(Surface.chrome)
        .accessibilityHidden(true)
        .onDisappear { model.barPointerX = nil }
    }

    @ViewBuilder
    private func viewport(width: CGFloat) -> some View {
        if let visible = model.visible, let span = TranscriptRail.span(of: visible, in: model.barMarks) {
            let length = max(CGFloat(span.upperBound - span.lowerBound) * width, 8)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Color.secondary.opacity(0.6), lineWidth: 1))
                .frame(width: length, height: Self.stripHeight - 9)
                .offset(x: min(Self.inset + CGFloat(span.lowerBound) * width, Self.inset + width - length), y: 9)
                .allowsHitTesting(false)
        }
    }

    fileprivate static func x(_ fraction: Double, in size: CGSize) -> CGFloat {
        inset + CGFloat(fraction) * max(size.width - 2 * inset, 1)
    }

    /// Where a mark is drawn: its room along the bar less a gap, never narrower than minWidth.
    fileprivate static func rect(_ mark: TranscriptRail.Mark, in size: CGSize, y: CGFloat, height: CGFloat, minWidth: CGFloat) -> CGRect {
        let left = x(mark.start, in: size)
        let right = x(mark.end, in: size)
        return CGRect(x: left, y: y, width: max(right - left - 1, minWidth), height: height)
    }

    /// Whether a tool run that does not show its calls has room for their number.
    fileprivate static func showsCount(_ mark: TranscriptRail.Mark, on band: CGRect) -> Bool {
        mark.size > 0 && band.width >= CGFloat(String(mark.size).count) * 5.5 + 4
    }
}

/// What the pointer is on in the bar, drawn a little taller and in full color, so the bar shows
/// what a click would go to. Its own view, so the pointer moving redraws only this.
private struct TranscriptHistoryBarHighlight: View {
    let model: TranscriptRailModel
    let width: CGFloat

    var body: some View {
        let marks = model.barMarks
        let events = model.events
        let target = model.barPointerX.flatMap {
            TranscriptRail.target(at: Double(($0 - TranscriptHistoryBar.inset) / width), length: width,
                                  promptSize: TranscriptRail.barPromptSize, marks: marks, events: events)
        }
        Canvas { context, size in
            switch target {
            case .call(let mark, let index)?:
                let x = TranscriptHistoryBar.x(TranscriptRail.place(ofCall: index, in: mark), in: size)
                context.fill(Path(roundedRect: CGRect(x: x - 1.5, y: 14, width: 3, height: 20), cornerRadius: 1), with: .color(TranscriptRail.toolColor))
            case .mark(let mark)?:
                // Messages and tool runs: 3 points taller above and below.
                let taller = TranscriptHistoryBar.rect(mark, in: size, y: 14, height: 20, minWidth: 2)
                switch mark.kind {
                case .prompt:
                    let promptColor: Color = TranscriptColorSystem.semanticAccent(.user)
                    let room = TranscriptHistoryBar.rect(mark, in: size, y: 7, height: 34, minWidth: TranscriptRail.barPromptSize)
                    if room.width > 30 { context.fill(Path(roundedRect: room, cornerRadius: 3), with: .color(promptColor.opacity(0.3))) }
                    context.fill(Path(roundedRect: CGRect(x: room.minX - 1, y: room.minY, width: min(room.width, 30) + 2, height: room.height), cornerRadius: 3),
                                 with: .color(promptColor))
                case .reply:
                    context.fill(Path(roundedRect: taller, cornerRadius: 2), with: .color(TranscriptColorSystem.semanticAccent(.assistant)))
                case .tools:
                    context.fill(Path(roundedRect: taller, cornerRadius: 2), with: .color(Color.secondary.opacity(0.85)))
                    if TranscriptHistoryBar.showsCount(mark, on: taller) {
                        context.draw(Text(verbatim: "\(mark.size)").font(.system(size: 10, weight: .semibold)).foregroundColor(Color(nsColor: .textBackgroundColor)),
                                     at: CGPoint(x: taller.midX, y: taller.midY), anchor: .center)
                    }
                case .error:
                    context.fill(Path(roundedRect: taller, cornerRadius: 1), with: .color(TranscriptColorSystem.semanticAccent(.error)))
                case .other:
                    break
                }
            case .event(let event)?:
                // The flag half as large again, on a thicker pole.
                guard let place = TranscriptRail.place(of: event, in: marks) else { break }
                let x = TranscriptHistoryBar.x(place, in: size)
                let color = TranscriptRail.color(of: event.kind)
                context.fill(Path(CGRect(x: x - 1.5, y: 6, width: 3, height: size.height - 6)), with: .color(color))
                var flag = Path()
                if event.kind == .compaction {
                    flag.addLines([CGPoint(x: x, y: 0), CGPoint(x: x + 6, y: 6), CGPoint(x: x, y: 12), CGPoint(x: x - 6, y: 6)])
                } else {
                    flag.addLines([CGPoint(x: x, y: 0), CGPoint(x: x + 12, y: 5.25), CGPoint(x: x, y: 10.5)])
                }
                flag.closeSubpath()
                context.fill(flag, with: .color(color))
            case nil:
                break
            }
        }
        .allowsHitTesting(false)
    }
}

/// The card for what the pointer is on in the bar. It hangs under the bar, over the transcript,
/// so the transcript's overlay hosts it; it is as wide as the bar.
struct TranscriptHistoryBarCard: View {
    let model: TranscriptRailModel

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - 2 * TranscriptHistoryBar.inset, 1)
            if let x = model.barPointerX,
               let target = TranscriptRail.target(at: Double((x - TranscriptHistoryBar.inset) / width), length: width,
                                                  promptSize: TranscriptRail.barPromptSize, marks: model.barMarks, events: model.events) {
                TranscriptRailCard(target, in: model.barMarks, describe: model.describe)
                    // Under the pointer, inside the pane.
                    .offset(x: min(max(8, x - TranscriptRailCard.outerWidth / 2), max(8, geometry.size.width - TranscriptRailCard.outerWidth - 8)),
                            y: 6)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct TranscriptHistoryBarMarks: View {
    let marks: [TranscriptRail.Mark]
    let matches: [Int]
    let events: [TranscriptRail.Event]

    var body: some View {
        Canvas { context, size in
            func rect(_ mark: TranscriptRail.Mark, y: CGFloat, height: CGFloat, minWidth: CGFloat) -> CGRect {
                TranscriptHistoryBar.rect(mark, in: size, y: y, height: height, minWidth: minWidth)
            }
            // Flags and match dots along the top; under them one row of prompts, replies and tool runs.
            context.fill(Path(roundedRect: CGRect(x: 8, y: 13, width: size.width - 16, height: 22), cornerRadius: 4),
                         with: .color(Color.primary.opacity(0.05)))
            let promptColor: Color = TranscriptColorSystem.semanticAccent(.user)
            for mark in marks {
                switch mark.kind {
                case .reply:
                    context.fill(Path(roundedRect: rect(mark, y: 17, height: 14, minWidth: 1), cornerRadius: 1),
                                 with: .color(TranscriptColorSystem.semanticAccent(.assistant).opacity(0.55)))
                case .error:
                    context.fill(Path(rect(mark, y: 17, height: 14, minWidth: 2)), with: .color(TranscriptColorSystem.semanticAccent(.error)))
                case .tools:
                    // A gray band for the run, with one line per call when they fit, else the
                    // number of calls when the band has room for it.
                    let band = rect(mark, y: 17, height: 14, minWidth: 1)
                    context.fill(Path(roundedRect: band, cornerRadius: 2), with: .color(Color.secondary.opacity(0.3)))
                    if TranscriptRail.showsCalls(mark, length: size.width - 2 * TranscriptHistoryBar.inset) {
                        for index in mark.calls.indices {
                            let x = TranscriptHistoryBar.x(TranscriptRail.place(ofCall: index, in: mark), in: size)
                            context.fill(Path(CGRect(x: x - 0.5, y: band.minY, width: 1, height: band.height)), with: .color(TranscriptRail.toolColor))
                        }
                    } else if TranscriptHistoryBar.showsCount(mark, on: band) {
                        context.draw(Text(verbatim: "\(mark.size)").font(.system(size: 9, weight: .medium)),
                                     at: CGPoint(x: band.midX, y: band.midY), anchor: .center)
                    }
                case .prompt, .other:
                    break
                }
            }
            // Prompts on top: a block 7 to 30 pt wide however short the prompt; a wider slot shows
            // as a tint behind it.
            for mark in marks where mark.kind == .prompt {
                let room = rect(mark, y: 10, height: 28, minWidth: TranscriptRail.barPromptSize)
                if room.width > 30 { context.fill(Path(roundedRect: room, cornerRadius: 2), with: .color(promptColor.opacity(0.25))) }
                context.fill(Path(roundedRect: CGRect(x: room.minX, y: room.minY, width: min(room.width, 30), height: room.height), cornerRadius: 2),
                             with: .color(promptColor))
            }
            for event in events {
                guard let place = TranscriptRail.place(of: event, in: marks) else { continue }
                let x = TranscriptHistoryBar.x(place, in: size)
                let color = TranscriptRail.color(of: event.kind)
                context.fill(Path(CGRect(x: x - 0.75, y: 6, width: 1.5, height: size.height - 6)), with: .color(color))
                var flag = Path()
                if event.kind == .compaction {
                    // A diamond.
                    flag.addLines([CGPoint(x: x, y: 0), CGPoint(x: x + 4, y: 4), CGPoint(x: x, y: 8), CGPoint(x: x - 4, y: 4)])
                } else {
                    // A pennant.
                    flag.addLines([CGPoint(x: x, y: 0), CGPoint(x: x + 8, y: 3.5), CGPoint(x: x, y: 7)])
                }
                flag.closeSubpath()
                context.fill(flag, with: .color(color))
            }
            var lastDot: CGFloat = -10
            for block in matches {
                guard let mark = TranscriptRail.mark(holding: block, in: marks) else { continue }
                let x = TranscriptHistoryBar.x((mark.start + mark.end) / 2, in: size)
                guard x - lastDot >= 4 else { continue }
                lastDot = x
                context.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: 2, width: 5, height: 5)), with: .color(.yellow))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Words

/// The words the history views say about a mark or an event.
enum TranscriptRailText {
    static func promptTitle(_ mark: TranscriptRail.Mark, in marks: [TranscriptRail.Mark]) -> Text {
        let count = marks.last(where: { $0.kind == .prompt })?.ordinal ?? 0
        return Text("Prompt \(mark.ordinal) of \(count)",
                    comment: "History strip beside the transcript: which prompt the pointer is on, for example Prompt 31 of 42. %1$lld is its position; %2$lld is the number of prompts in the session.")
    }

    /// What a mark is and how large.
    static func title(for mark: TranscriptRail.Mark, in marks: [TranscriptRail.Mark]) -> Text {
        let characters = Text("\(mark.size) characters", comment: "History bar above the transcript: the length of the prompt or reply the pointer is on.")
        switch mark.kind {
        case .prompt:
            return promptTitle(mark, in: marks) + Text(verbatim: " · ") + characters
        case .reply:
            return Text("Reply", comment: "History bar above the transcript: the pointer is on a reply from the agent.")
                + Text(verbatim: " · ") + characters
        case .tools:
            return Text("\(mark.size) tool calls")
        case .error:
            return Text("Error")
        case .other:
            return Text(verbatim: " ")
        }
    }

    static func title(for event: TranscriptRail.Event) -> Text {
        switch event.kind {
        case .compaction:
            return Text("Compaction", comment: "History bar above the transcript: the pointer is on a point where the agent replaced earlier history with a summary.")
        case .forkedFrom:
            return Text("Forked from \(event.title)", comment: "History bar above the transcript: this chat was forked from another chat. %@ is that chat's title.")
        case .fork:
            return Text("Fork: \(event.title)", comment: "History bar above the transcript: another chat was forked from this one at this point. %@ is that chat's title.")
        }
    }
}

