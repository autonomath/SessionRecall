import Foundation
import Combine
import AppKit

// Actor for thread-safe promotion state
private actor PromotionState {
    private var promotedID: String?

    func setPromoted(id: String) {
        promotedID = id
    }

    func consumePromoted() -> String? {
        let id = promotedID
        promotedID = nil
        return id
    }
}

/// Coalesces provider membership/classification bursts into one active-query restart.
/// The view owns one instance and routes every dataset-driven restart through it, so
/// a provider refresh that publishes several intermediate snapshots does not launch
/// and cancel several identical searches.
@MainActor
final class SearchDatasetRestartCoalescer: ObservableObject {
    private var pendingTask: Task<Void, Never>?

    func schedule(after delay: TimeInterval = 0.08, action: @escaping () -> Void) {
        pendingTask?.cancel()
        let delayNanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        pendingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.pendingTask = nil
            action()
        }
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
    }
}

final class SearchCoordinator: ObservableObject, @unchecked Sendable {
    struct SessionKey: Hashable, Sendable {
        let source: SessionSource
        let id: String

        init(source: SessionSource, id: String) {
            self.source = source
            self.id = id
        }

        init(_ session: Session) {
            source = session.source
            id = session.id
        }
    }

    struct Progress: Equatable {
        enum Phase {
            case idle
            case indexed
            case legacySmall
            case legacyLarge
            case unindexedSmall
            case unindexedLarge
            case toolOutputsSmall
            case toolOutputsLarge
        }
        var phase: Phase = .idle
        var scannedSmall: Int = 0
        var totalSmall: Int = 0
        var scannedLarge: Int = 0
        var totalLarge: Int = 0
    }

    @Published private(set) var queryError: String?
    @Published private(set) var eligibleCount = 0
    @Published private(set) var completeCount = 0
    @Published private(set) var incompleteCount = 0
    @Published private(set) var unresolvedCount = 0
    @Published private(set) var verifiedKeys: Set<SessionKey> = []
    @Published private(set) var snippets: [SessionKey: String] = [:]

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var wasCanceled: Bool = false
    @Published private(set) var results: [Session] = []
    @Published private(set) var progress: Progress = .init()
    @Published private(set) var deepScanEnabled: Bool = false
    /// The single field to search, or nil for every field ranked together.
    @Published var field: TranscriptField? = nil
    /// Why each ranked result matched: its best field and the passage.
    @Published private(set) var hits: [SessionKey: SearchHit] = [:]
    /// True when results are ordered best match first and the list should keep that order.
    @Published private(set) var isRanked: Bool = false
    /// Matching chats in each field, for the scope bar, and in all fields together.
    @Published private(set) var fieldCounts: [TranscriptField: Int] = [:]
    @Published private(set) var matchCount: Int = 0
    /// Sessions in scope that the field index has not read yet, so a miss is never silent.
    @Published private(set) var unindexedCount: Int = 0
    /// Sessions written to since their last ingest, whose newest text is read live.
    @Published private(set) var updatingCount: Int = 0
    /// Sessions in scope with events too large for the parser to read.
    @Published private(set) var skippedCount: Int = 0

    private static let excerptLimit = 200
    /// How much a chat's best passage adds to its score. 2 ranked most real searches first.
    static let passageFactor = 2.0
    private static let toolExcerptLimit = 30

    private var currentTask: Task<Void, Never>? = nil
    private var deepScanTask: Task<Void, Never>? = nil
    private let store: SearchSessionStoring
    private let db: IndexDB?
    private let ftsResultLimitForTesting: Int?
    // Promotion support for large-queue preemption
    private let promotionState = PromotionState()
    // Generation token to ignore stale appends after cancel/restart
    private var runID = UUID()
    private var cancelledVerificationRunID: UUID?
    private var metricOperation: SearchResponsivenessOperationID?
    // When a dataset-triggered refresh preserves old results, this holds the
    // run that owns the single replacing publication. Cleared when that run's
    // first publication replaces (or when a newer run starts).
    private var preservedReplacementRunID: UUID? = nil
    /// Consumes the single replacing publication for `runID`. Returns true
    /// exactly once per preserving run: the caller's publication is the first
    /// and must replace. Later publications append. Stale runs never consume.
    @MainActor
    private func consumePreservedReplacement(for runID: UUID) -> Bool {
        guard preservedReplacementRunID == runID else { return false }
        preservedReplacementRunID = nil
        return true
    }
    private var prewarmInFlight: Set<String> = []
    private var prewarmTasksByID: [String: Task<Void, Never>] = [:]
    private var appIsActive: Bool = true
    // Throttle guards for progress updates
    private var progressThrottleLastFlush = DispatchTime.now()

    init(store: SearchSessionStoring) {
        self.store = store
        // A failed open silently disables DB-backed search (the legacy scan path still
        // runs), and schema migration failure is the way that happens. Surface it instead
        // of swallowing it: loud in DEBUG, logged in release.
        do {
            self.db = try IndexDB()
        } catch {
            self.db = nil
            LaunchProfiler.log("SearchCoordinator: IndexDB unavailable, falling back to legacy search — \(error)")
            assertionFailure("SearchCoordinator could not open IndexDB: \(error)")
        }
        self.ftsResultLimitForTesting = nil
    }

    /// Test seam for exercising the actual FTS/fallback coordinator against an
    /// isolated database rather than the user's application index.
    init(store: SearchSessionStoring, db: IndexDB?, ftsResultLimitForTesting: Int? = nil) {
        self.store = store
        self.db = db
        self.ftsResultLimitForTesting = ftsResultLimitForTesting
    }

    deinit {
        currentTask?.cancel()
        deepScanTask?.cancel()
        prewarmTasksByID.values.forEach { $0.cancel() }
    }

    @MainActor
    func setAppActive(_ active: Bool) {
        appIsActive = active
        if !active {
            if isRunning { cancel(clearResults: false) }
            prewarmTasksByID.values.forEach { $0.cancel() }
            prewarmTasksByID.removeAll()
            prewarmInFlight.removeAll()
        }
    }

    // Get appropriate transcript cache based on session source
    private func transcriptCache(for source: SessionSource) -> TranscriptCache? {
        store.transcriptCache(for: source)
    }

    private func deepToolOutputsEnabled() -> Bool {
        // Default OFF unless the user explicitly opts in.
        if UserDefaults.standard.object(forKey: PreferencesKey.Advanced.enableDeepToolOutputSearch) == nil { return false }
        return UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.enableDeepToolOutputSearch)
    }

    private func toolIOIndexEnabled() -> Bool {
        // Default OFF unless the user explicitly opts in.
        if UserDefaults.standard.object(forKey: PreferencesKey.Advanced.enableRecentToolIOIndex) == nil {
            return false
        }
        return UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.enableRecentToolIOIndex)
    }

    @MainActor
    func cancel() { cancel(clearResults: false) }
    @MainActor
    func clear() { cancel(clearResults: true) }

    @MainActor
    private func cancel(clearResults: Bool) {
        let shouldReportCancellation = !clearResults
            && (isRunning || currentTask != nil || deepScanTask != nil)
        SearchResponsivenessMetrics.shared.record(.searchCancelRequested, operationID: metricOperation, status: .cancelled)
        currentTask?.cancel()
        currentTask = nil
        deepScanTask?.cancel()
        deepScanTask = nil
        cancelledVerificationRunID = shouldReportCancellation ? runID : nil
        runID = UUID()
        isRunning = false
        wasCanceled = shouldReportCancellation
        deepScanEnabled = false
        progress = .init()
        if clearResults {
            results = []
            verifiedKeys = []
            snippets = [:]
            queryError = nil
            eligibleCount = 0
            completeCount = 0
            incompleteCount = 0
            unresolvedCount = 0
            clearRankedState()
        }
    }

    /// Results that are not ranked carry no field, passage or index counts.
    @MainActor
    private func clearRankedState() {
        isRanked = false
        hits = [:]
        fieldCounts = [:]
        matchCount = 0
        unindexedCount = 0
        updatingCount = 0
        skippedCount = 0
    }

    // Promote a large session to be processed next in the large queue if present.
    func promote(id: String) {
        Task {
            await promotionState.setPromoted(id: id)
        }
    }

    func prewarmTranscriptIfNeeded(for session: Session, allowParsingLightweight: Bool = true) {
        if !allowParsingLightweight, session.events.isEmpty { return }
        if !appIsActive { return }
        if !NSApp.isActive { return }
        guard let cache = transcriptCache(for: session.source) else { return }
        if cache.getCached(session.id) != nil { return }
        if prewarmInFlight.contains(session.id) { return }
        if prewarmTasksByID[session.id] != nil { return }
        prewarmInFlight.insert(session.id)

        let sessionSnapshot = session
        let task = Task.detached(priority: .utility) { [weak self] in
            defer {
                DispatchQueue.main.async { [weak self] in
                    self?.prewarmInFlight.remove(sessionSnapshot.id)
                    self?.prewarmTasksByID[sessionSnapshot.id] = nil
                }
            }

            if FeatureFlags.gatePrewarmWhileTyping, TypingActivity.shared.isUserLikelyTyping {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard !Task.isCancelled else { return }

            var target = sessionSnapshot
            if target.events.isEmpty, let parsed = await self?.store.parseFull(session: target) {
                target = parsed
                if !FeatureFlags.disableSessionUpdatesDuringSearch {
                    self?.store.updateSession(parsed)
                }
            }

            await cache.generateAndCache(sessions: [target])
        }
        prewarmTasksByID[session.id] = task
    }

    /// Runs a search over `all`, restricted to the sessions whose source is in `allowed`.
    ///
    /// `allowed` used to arrive as twelve hand-maintained `include<Provider>` Bools that this
    /// method funnelled back into exactly this set. Callers now pass the set itself — in the
    /// app, `UnifiedSessionIndexer.allowedSearchSources()` (SPEC §3.5/§8.5), which applies one
    /// enabled-and-included policy to every source instead of per-call-site subsets.
    func start(query: String,
               filters: Filters,
               allowed: Set<SessionSource>,
               enableDeepScan: Bool,
               all: [Session],
               effectiveDisplayTitles: [SessionKey: String] = [:],
               preserveResultsUntilRefreshPublishes: Bool = false) {
        currentTask?.cancel()
        deepScanTask?.cancel()
        let currentRun = UUID()
        runID = currentRun
        cancelledVerificationRunID = nil
        let metrics = SearchResponsivenessMetrics.shared
        let operation = metrics.newOperationID()
        metricOperation = operation
        metrics.record(.searchRequestAccepted, operationID: operation, status: .accepted)
        wasCanceled = false
        queryError = nil
        completeCount = 0
        incompleteCount = 0
        unresolvedCount = 0
        eligibleCount = 0
        verifiedKeys = []
        snippets = [:]
        deepScanEnabled = enableDeepScan
        isRunning = true
        if !preserveResultsUntilRefreshPublishes { results = [] }
        let store = self.store
        let field = self.field
        currentTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let terminal = metrics.beginSpan(.searchTerminal, operationID: operation)
            defer { if let terminal { Task.isCancelled ? metrics.cancel(terminal) : metrics.end(terminal) } }
            do {
                // The field indexes hold every field of every ingested session in full, so
                // ranked search answers from them. Cursor sessions are not in the index and are
                // read live, like any session the index has not reached.
                let rankedSources = allowed.filter { $0 != .cursor }.map(\.rawValue)
                var rankedDB: IndexDB?
                if FeatureFlags.enableFTSSearch, let db = self.db,
                   (try? await db.hasFieldData(sources: rankedSources)) == true { rankedDB = db }
                let metadata: SearchQuery.Metadata
                do {
                    metadata = try SearchQuery.metadataTokens(SearchQuery.lex(filters.query)).0
                } catch {
                    // Ranked search takes the words as typed, an open quote included.
                    guard rankedDB != nil else { throw error }
                    let typed = FilterEngine.parseOperators(filters.query)
                    metadata = .init(freeText: typed.freeText, repo: typed.repo, path: typed.path,
                                     sideChatsOnly: typed.sideChatsOnly)
                }
                let candidates = Self.metadataFilteredCandidates(
                    Self.candidates(from: all, allowed: allowed, filters: filters), filters: filters,
                    effectiveRepo: filters.repoName ?? metadata.repo,
                    effectivePath: filters.pathContains ?? metadata.path,
                    effectiveSideChatsOnly: filters.sideChatsOnly || metadata.sideChatsOnly,
                    effectiveProjectIdentity: filters.selectedProjectIdentity)
                let eligible = candidates.map { Self.searchRow($0, title: effectiveDisplayTitles[SessionKey($0)]) }
                metrics.record(.searchEligibleCount, operationID: operation, counters: [.eligibleSessions: Int64(eligible.count)])
                let exact = Self.exactIdentityMatches(metadata.freeText, sessions: eligible)
                if metadata.freeText.isEmpty || !exact.isEmpty {
                    let rows = metadata.freeText.isEmpty ? eligible : exact
                    await MainActor.run {
                        guard self.runID == currentRun else { return }
                        self.clearRankedState()
                        self.results = rows
                        self.verifiedKeys = Set(rows.map(SessionKey.init))
                        self.eligibleCount = rows.count
                        self.completeCount = rows.count
                        self.isRunning = false
                        self.progress = .init()
                    }
                    return
                }

                if let db = rankedDB {
                    await self.runRankedSearch(runID: currentRun,
                                               db: db,
                                               freeText: metadata.freeText,
                                               field: field,
                                               sources: rankedSources,
                                               candidates: candidates,
                                               titleOverrides: effectiveDisplayTitles,
                                               enableDeepScan: enableDeepScan,
                                               operation: operation)
                    return
                }

                let tokenizer = try SearchTokenizer()
                let compiled = try SearchQuery(filters.query, tokenizer: tokenizer)
                var hits: [SessionKey: Session] = [:]
                for session in eligible {
                    try Task.checkCancellation()
                    let predicate = SearchPredicateAccumulator(query: compiled, tokenizer: tokenizer)
                    for field in [session.listTitle, session.lightweightCwd ?? "", session.lightweightRepoName ?? ""] {
                        try predicate.consume(field: field)
                    }
                    if predicate.truth(complete: false) == .yes { hits[SessionKey(session)] = session }
                }
                if FeatureFlags.enableFTSSearch, let db = self.db, let fts = compiled.ftsCandidate {
                    // Scope each source and every metadata predicate before capacity. Source-qualified
                    // keys also avoid dictionary traps when two providers use the same raw ID.
                    for source in allowed {
                        try Task.checkCancellation()
                        let scoped = eligible.filter { $0.source == source }
                        let originals = candidates.filter { $0.source == source }
                        let ids = await Self.indexedCandidates(originals, db: db, toolIO: false)
                        guard !ids.isEmpty else { continue }
                        let limit = self.ftsResultLimitForTesting ?? FeatureFlags.ftsSearchLimit
                        let ordinary = (try? await db.searchSessionIDsFTS(
                            sources: [source.rawValue], model: nil, repoSubstr: nil, pathSubstr: nil,
                            dateFrom: nil, dateTo: nil, query: fts,
                            includeSystemProbes: UserDefaults.standard.bool(forKey: "ShowSystemProbeSessions"),
                            limit: limit, eligibleSessionIDs: ids)) ?? []
                        var found = Set(ordinary)
                        if self.toolIOIndexEnabled() {
                            let tool = (try? await db.searchSessionIDsToolIOFTS(
                                sources: [source.rawValue], model: nil, repoSubstr: nil, pathSubstr: nil,
                                dateFrom: nil, dateTo: nil, query: fts,
                                includeSystemProbes: UserDefaults.standard.bool(forKey: "ShowSystemProbeSessions"),
                                limit: max(0, limit - found.count), eligibleSessionIDs: await Self.indexedCandidates(originals, db: db, toolIO: true),
                                excludingSessionIDs: found)) ?? []
                            found.formUnion(tool)
                        }
                        for session in scoped where found.contains(session.id) { hits[SessionKey(session)] = session }
                    }
                }
                try Task.checkCancellation()
                let instantRows = eligible.filter { hits[SessionKey($0)] != nil }
                await MainActor.run {
                    guard self.runID == currentRun else { return }
                    metrics.record(.searchInstantFirstPublication, operationID: operation, status: .published, counters: [.resultCount: Int64(instantRows.count)])
                    self.clearRankedState()
                    self.results = instantRows
                    self.eligibleCount = eligible.count
                    self.unresolvedCount = eligible.count
                    self.progress = .init(phase: enableDeepScan ? .legacySmall : .indexed,
                                          scannedSmall: 0, totalSmall: eligible.count)
                    self.isRunning = enableDeepScan
                }
                guard enableDeepScan else { return }
                var complete = 0, incomplete = 0, unresolved = 0
                var verified: Set<SessionKey> = []
                var snippets: [SessionKey: String] = [:]
                var lastPublication = ContinuousClock.now
                var visited = 0
                for (index, session) in eligible.enumerated() {
                    if Task.isCancelled { break }
                    let result = await SearchMetricScope.$requestID.withValue(operation) {
                        await store.scan(session: session, query: compiled)
                    }
                    if Task.isCancelled { break }
                    visited = index + 1
                    if result.summary.complete { complete += 1 } else { incomplete += 1 }
                    switch result.truth {
                    case .yes:
                        verified.insert(result.key)
                        hits[result.key] = session
                        snippets[result.key] = result.snippet
                    case .no: hits[result.key] = nil
                    case .unknown: unresolved += 1
                    }
                    if ContinuousClock.now - lastPublication >= .milliseconds(100) || index == eligible.count - 1 {
                        let rows = eligible.filter { hits[SessionKey($0)] != nil }
                        let counts = (complete, incomplete, unresolved + eligible.count - index - 1)
                        let verifiedSnapshot = verified, snippetSnapshot = snippets
                        await MainActor.run {
                            guard self.runID == currentRun else { return }
                            self.results = rows
                            metrics.record(.searchCoverageCounters, operationID: operation, status: .published, counters: [.completeSessions: Int64(counts.0), .incompleteSessions: Int64(counts.1), .verifiedResults: Int64(verifiedSnapshot.count)])
                            self.verifiedKeys = verifiedSnapshot
                            self.snippets = snippetSnapshot
                            self.completeCount = counts.0
                            self.incompleteCount = counts.1
                            self.unresolvedCount = counts.2
                            self.progress.scannedSmall = index + 1
                        }
                        lastPublication = .now
                    }
                }
                let finalRows = eligible.filter { hits[SessionKey($0)] != nil }
                let finalVerified = verified, finalSnippets = snippets
                let finalCounts = (complete, incomplete, unresolved + eligible.count - visited)
                await MainActor.run {
                    guard self.runID == currentRun || self.cancelledVerificationRunID == currentRun else { return }
                    self.results = finalRows
                    self.verifiedKeys = finalVerified
                    self.snippets = finalSnippets
                    self.completeCount = finalCounts.0
                    self.incompleteCount = finalCounts.1
                    self.unresolvedCount = finalCounts.2
                    self.isRunning = false
                    self.progress.phase = .idle
                    self.cancelledVerificationRunID = nil
                }
            } catch is CancellationError {
                await self.finishCanceled(runID: currentRun)
            } catch {
                await MainActor.run {
                    guard self.runID == currentRun else { return }
                    self.queryError = error.localizedDescription
                    self.results = []
                    self.isRunning = false
                }
            }
        }
    }

    /// Ranked search over the per-field indexes plus titles. Publishes results best match
    /// first, each with the field and passage that explain it, then reads live the chats the
    /// index cannot answer for: those written to since their last ingest and those not in it yet.
    private func runRankedSearch(runID: UUID,
                                 db: IndexDB,
                                 freeText: String,
                                 field: TranscriptField?,
                                 sources: [String],
                                 candidates: [Session],
                                 titleOverrides: [SessionKey: String],
                                 enableDeepScan: Bool,
                                 operation: SearchResponsivenessOperationID?) async {
        let metrics = SearchResponsivenessMetrics.shared
        let enabled = SearchPreferences.fields
        // A field switched off in Settings falls back to every field.
        let chosen = field.flatMap { enabled.contains($0) ? $0 : nil }
        // Every enabled field is searched even with one chosen, so the scope bar can count each.
        // A sub-agent's prompt is the brief its parent wrote, so it ranks, filters and is
        // labelled as a tool call. Its text sits in the prompt index, hence the extra table.
        let tables = enabled.contains(.toolCall) && !enabled.contains(.user) ? enabled + [.user] : enabled
        let prefix = SearchPreferences.prefixWhileTyping
        var indexQuery = SearchTextMatcher.rankedQuery(freeText, forIndex: true, prefix: prefix)
        var parts = SearchTextMatcher.rankedQueryParts(freeText, prefix: prefix)
        // The last word is also looked up as a prefix while it is being typed. Counted in full it
        // weighed twice as much as any other word, so the prefix form is scored apart: it adds only
        // what it finds beyond the whole word, at half weight.
        let prefixPart = parts.count > 1 ? parts.last.flatMap { $0.hasSuffix("\"*") ? $0 : nil } : nil
        let wholePart = prefixPart.map { String($0.dropLast()) }
        let scoredParts = prefixPart == nil ? parts : Array(parts.dropLast())
        /// What the prefix form adds to one score of the whole last word.
        func prefixExtra(_ prefixScore: Double, whole: Double?) -> Double { max(0, prefixScore - (whole ?? 0)) / 2 }
        // In a passage the prefix form stands for the whole last word (a filler last word has neither).
        var passageQuery = (prefixPart.flatMap { prefix in
            wholePart.map { whole in scoredParts.contains(whole) ? scoredParts.filter { $0 != whole } + [prefix] : scoredParts }
        } ?? parts).joined(separator: " OR ")
        var matches: [IndexDB.FieldMatch]
        do {
            matches = try await db.searchFields(query: scoredParts.joined(separator: " OR "), fields: tables, sources: sources)
            if let prefixPart, let wholePart {
                struct Place: Hashable { let id: String; let source: String; let field: TranscriptField }
                var whole: [Place: Double] = [:]
                for m in try await db.searchFields(query: wholePart, fields: tables, sources: sources) {
                    whole[Place(id: m.sessionID, source: m.source, field: m.field)] = m.score
                }
                for m in try await db.searchFields(query: prefixPart, fields: tables, sources: sources) {
                    let extra = prefixExtra(m.score, whole: whole[Place(id: m.sessionID, source: m.source, field: m.field)])
                    if extra > 0 {
                        matches.append(IndexDB.FieldMatch(sessionID: m.sessionID, source: m.source, field: m.field, score: extra))
                    }
                }
            }
        } catch {
            // FTS5 rejected hand-written syntax such as a stray colon: search for the words as typed.
            parts = freeText.split(whereSeparator: \.isWhitespace)
                .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
            indexQuery = parts.joined(separator: " OR ")
            passageQuery = indexQuery
            matches = (try? await db.searchFields(query: indexQuery, fields: tables, sources: sources)) ?? []
        }
        if Task.isCancelled { await finishCanceled(runID: runID); return }

        var byKey: [SessionKey: Session] = [:]
        byKey.reserveCapacity(candidates.count)
        for session in candidates { byKey[SessionKey(session)] = session }
        let subagents = SearchPreferences.subagents
        let parentOf = subagents == .fold ? SubagentHierarchyBuilder.parentIDs(of: candidates) : [:]
        /// The row a session's matches count toward: itself, its parent when folded, or none when left out.
        func owner(_ session: Session) -> SessionKey? {
            let key = SessionKey(session)
            guard session.isSubagent else { return key }
            switch subagents {
            case .hide: return nil
            case .separate: return key
            case .fold:
                guard let parent = parentOf[session.id] else { return key }
                let parentKey = SessionKey(source: session.source, id: parent)
                return byKey[parentKey] == nil ? key : parentKey
            }
        }
        // A folded sub-agent adds only its best score, so a chat with many sub-agents does not outrank everything.
        struct FieldScore { var total = 0.0; var subagent = 0.0; var top = 0.0; var table = TranscriptField.title; var from: SessionKey }
        var scores: [SessionKey: [TranscriptField: FieldScore]] = [:]
        func add(_ key: SessionKey, _ field: TranscriptField, _ table: TranscriptField, _ score: Double, from: SessionKey) {
            var s = scores[key]?[field] ?? FieldScore(from: from)
            if from == key { s.total += score } else { s.subagent = max(s.subagent, score / 2) }
            if score > s.top { s.top = score; s.table = table; s.from = from }
            scores[key, default: [:]][field] = s
        }
        for match in matches {
            guard let source = SessionSource(rawValue: match.source) else { continue }
            let from = SessionKey(source: source, id: match.sessionID)
            guard let session = byKey[from], let key = owner(session) else { continue }
            let isBrief = match.field == .user && session.isSubagent
            // Folded into its parent, the brief already counts as the parent's own tool call.
            if isBrief, key != from { continue }
            let field: TranscriptField = isBrief ? .toolCall : match.field
            guard enabled.contains(field) else { continue }
            add(key, field, match.field, isBrief ? match.score / match.field.weight * field.weight : match.score, from: from)
        }
        // The best single passage of prompt or reply text. A whole chat is one document per
        // field, so a long chat that mentions each typed word somewhere outranks the chat where
        // they sit together; the best passage's score makes up for that. A sub-agent's passage
        // counts half for its parent, and its prompt, the parent's brief, as a tool call.
        var bestPassage: [SessionKey: Double] = [:]
        var passageOrd: [SessionKey: [TranscriptField: Int]] = [:]  // per matching session and field, for excerpts
        for match in (try? await db.searchPassages(query: passageQuery, sources: sources)) ?? [] {
            guard let source = SessionSource(rawValue: match.source) else { continue }
            let from = SessionKey(source: source, id: match.sessionID)
            guard let session = byKey[from], let key = owner(session) else { continue }
            passageOrd[from, default: [:]][match.field] = match.ord
            let isBrief = match.field == .user && session.isSubagent
            let field: TranscriptField = isBrief ? .toolCall : match.field
            guard enabled.contains(field), chosen == nil || chosen == field else { continue }
            let score = (isBrief ? match.score / match.field.weight * field.weight : match.score) / (key == from ? 1 : 2)
            bestPassage[key] = max(bestPassage[key] ?? 0, score)
        }
        if enabled.contains(.title) {
            // Only a real name counts as a title. An unnamed chat shows its first prompt
            // there, and that text is already ranked as a prompt.
            let titles = candidates.map {
                (key: SessionKey($0), title: titleOverrides[SessionKey($0)] ?? $0.customTitle ?? "")
            }
            var titleScores = RankedSearch.titleScores(titles: titles, parts: prefixPart == nil ? parts : scoredParts)
            if let prefixPart, let wholePart {
                let whole = RankedSearch.titleScores(titles: titles, parts: [wholePart])
                for (key, score) in RankedSearch.titleScores(titles: titles, parts: [prefixPart]) {
                    let extra = prefixExtra(score, whole: whole[key])
                    if extra > 0 { titleScores[key, default: 0] += extra }
                }
            }
            for (from, score) in titleScores {
                guard let session = byKey[from], let key = owner(session) else { continue }
                add(key, .title, .title, score, from: from)
            }
        }
        // A long Codex chat can be stored as several files, one per page. List it once, as
        // the page that matches best, scored by that page alone.
        var pagesByChat: [String: [SessionKey]] = [:]
        if SearchPreferences.oneRowPerChat {
            for session in candidates where session.source == .codex && !session.isSubagent && !session.isSideChat {
                if let chat = session.codexInternalSessionIDHint { pagesByChat[chat, default: []].append(SessionKey(session)) }
            }
        }
        var chatOf: [SessionKey: String] = [:]
        for (chat, pages) in pagesByChat where pages.count > 1 { for key in pages { chatOf[key] = chat } }
        func score(_ key: SessionKey) -> Double {
            guard let fields = scores[key] else { return 0 }
            let passage = Self.passageFactor * (bestPassage[key] ?? 0)
            if let chosen { return fields[chosen].map { $0.total + $0.subagent + passage } ?? 0 }
            return fields.values.reduce(0) { $0 + $1.total } + (fields.values.map(\.subagent).max() ?? 0) + passage
        }
        var listedChats = Set<String>()
        let scored: [(key: SessionKey, score: Double)] = scores.keys.map { ($0, score($0)) }.filter { $0.score > 0 }
        let sorted = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.key.id < $1.key.id }
        var listed: [SessionKey] = []
        for item in sorted where chatOf[item.key].map({ listedChats.insert($0).inserted }) ?? true {
            listed.append(item.key)
        }
        let ranked = Array(listed.prefix(ftsResultLimitForTesting ?? FeatureFlags.ftsSearchLimit))
        // Matching chats per field, one per chat however many of its files match.
        func row(_ key: SessionKey) -> String { chatOf[key] ?? "\(key.source.rawValue)/\(key.id)" }
        var counts: [TranscriptField: Int] = [:]
        for field in enabled { counts[field] = Set(scores.filter { $0.value[field] != nil }.keys.map(row)).count }
        let matchedRows = Set(scores.keys.map(row)).count

        var hits: [SessionKey: SearchHit] = [:]
        var origin: [SessionKey: (table: TranscriptField, from: SessionKey)] = [:]
        for key in ranked {
            guard let fields = scores[key],
                  let shown = chosen ?? TranscriptField.allCases.filter({ fields[$0] != nil })
                      .max(by: { fields[$0]!.top < fields[$1]!.top }),
                  let best = fields[shown] else { continue }
            origin[key] = (best.table, best.from)
            hits[key] = SearchHit(field: shown, excerpt: nil,
                                  also: TranscriptField.allCases.filter { $0 != shown && fields[$0] != nil },
                                  inSubagent: best.from != key)
            if let chat = chatOf[key], let pages = pagesByChat[chat] {
                let ordered = pages.sorted { (byKey[$0]?.filePath as NSString?)?.lastPathComponent ?? "" < (byKey[$1]?.filePath as NSString?)?.lastPathComponent ?? "" }
                hits[key]?.part = (ordered.firstIndex(of: key) ?? 0) + 1
                hits[key]?.partCount = ordered.count
            }
        }
        // Prompt and reply excerpts come straight from the index, from the session that matched:
        // its best passage, or the best part of the whole field while it has no passages.
        let highlight = SearchTextMatcher.rankedQuery(freeText)
        for field in tables where field.storesText {
            let keys = ranked.prefix(Self.excerptLimit).filter { origin[$0]?.table == field }
            var whole: [SessionKey] = []
            var cut: [(key: SessionKey, sessionID: String, ord: Int)] = []
            for key in keys {
                guard let from = origin[key]?.from else { continue }
                if let ord = passageOrd[from]?[field] { cut.append((key, from.id, ord)) } else { whole.append(key) }
            }
            let texts = (try? await db.passageTexts(field: field, passages: cut.map { ($0.sessionID, $0.ord) })) ?? []
            for (i, passage) in cut.enumerated() {
                if i < texts.count, let text = texts[i], let found = SearchHit.excerptAndAnchor(in: text, query: highlight) {
                    hits[passage.key]?.excerpt = found.excerpt
                    hits[passage.key]?.anchor = found.anchor
                } else {
                    whole.append(passage.key)
                }
            }
            let ids = whole.compactMap { origin[$0]?.from.id }
            let excerpts = (try? await db.fieldExcerpts(query: indexQuery, field: field, sessionIDs: ids)) ?? [:]
            for key in whole { if let from = origin[key]?.from { hits[key]?.excerpt = excerpts[from.id] } }
        }

        let indexed = (try? await db.fieldIndexedSessionIDs(sources: sources)) ?? []
        let pending = candidates.filter { !indexed.contains($0.id) }
        let unindexed = pending.count
        let withSkipped = (try? await db.sessionIDsWithSkippedEvents(sources: sources)) ?? []
        let skippedKeys = Set(candidates.filter { withSkipped.contains($0.id) }.map(SessionKey.init))
        // A chat written to since its last ingest (re-ingest waits for it to go quiet) has a
        // last event later than its file's modification time at that ingest.
        var ingestedMtime: [String: Int64] = [:]
        for source in sources {
            for row in (try? await db.fetchIndexedFiles(for: source)) ?? [] { ingestedMtime[row.path] = row.mtime }
        }
        // A file holding one chat decides by its own date: the list refreshes a chat it is not
        // showing only now and then, and its time can run ahead of a file nothing was written to.
        // A store shared by many chats (OpenCode, Hermes) says nothing about one of them, so
        // there the chat's own last event decides.
        var chatsPerFile: [String: Int] = [:]
        for session in candidates { chatsPerFile[session.filePath, default: 0] += 1 }
        let changed = Set(candidates.filter { session in
            guard indexed.contains(session.id), let mtime = ingestedMtime[session.filePath] else { return false }
            var info = stat()
            if chatsPerFile[session.filePath] == 1,
               stat(session.filePath, &info) == 0 || stat(session.filePath + ".zst", &info) == 0 {
                return Int64(info.st_mtimespec.tv_sec) > mtime
            }
            return Int64(session.modifiedAt.timeIntervalSince1970) > mtime
        }.map(SessionKey.init))
        // Sessions the field indexer has not reached yet stay findable through the older
        // sampled index, listed after the ranked results. It cannot tell fields apart, so
        // a single-field search leaves them out and the footer says how many.
        var pendingMatches: [Session] = []
        if !pending.isEmpty {
            let ids = (try? await db.searchSessionIDsFTS(sources: sources, model: nil, repoSubstr: nil,
                                                         pathSubstr: nil, dateFrom: nil, dateTo: nil,
                                                         query: indexQuery, includeSystemProbes: true,
                                                         limit: FeatureFlags.ftsSearchLimit,
                                                         eligibleSessionIDs: Set(pending.map(\.id)))) ?? []
            let rankedKeys = Set(ranked)
            let pendingByID = Dictionary(pending.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            pendingMatches = ids.compactMap { pendingByID[$0] }.filter {
                !rankedKeys.contains(SessionKey($0)) && (chatOf[SessionKey($0)].map { listedChats.insert($0).inserted } ?? true)
            }
        }
        if Task.isCancelled { await finishCanceled(runID: runID); return }

        let out = ranked.compactMap { byKey[$0] } + (chosen == nil ? pendingMatches : [])
        // Read live once the list is on screen: changed chats at any size, and chats with no
        // index row yet while small (any size when asked to check the remaining sessions). The
        // scan cannot tell fields apart, so a single-field search leaves them out.
        // Every page of a listed chat counts as shown, so no page of it is listed twice.
        let shown = Set(out.map(SessionKey.init)).union(listedChats.flatMap { pagesByChat[$0] ?? [] })
        let sampled = Set((try? await db.indexedSessionIDs(sources: sources)) ?? [])
        let indexedKeys = Set(candidates.filter { indexed.contains($0.id) || sampled.contains($0.id) }.map(SessionKey.init))
            .subtracting(changed)
        let live = chosen != nil ? [] : candidates.filter {
            Self.shouldIncludeUnindexedCandidate($0, indexedIDs: indexedKeys, seenIDs: shown, enableDeepScan: enableDeepScan,
                                                 smallSearchThreshold: FeatureFlags.searchSmallSizeBytes, staleIDs: changed)
        }
        // Coverage in the terms the list header reports. The index answers in full for a chat it
        // read whole and that has not changed since; one with parts too large to read is partly
        // checked; a changed chat or one not in the index is unresolved until it is read live.
        let pendingKeys = Set(pending.map(SessionKey.init))
        let answered = Set(candidates.map(SessionKey.init)).subtracting(pendingKeys).subtracting(changed)
        // A chat already listed gets no live read, so it counts as partly checked: its row is
        // there, on what the index or the sampled text held.
        let listedUnread = chosen == nil ? pendingKeys.union(changed).intersection(shown) : []
        let startComplete = answered.subtracting(skippedKeys).count
        let startIncomplete = answered.intersection(skippedKeys).count + listedUnread.count
        // A single-field search cannot read the others live, so it reports on what the index
        // answers for; the scope bar and the footer count the rest.
        let eligible = chosen == nil ? candidates.count : answered.count
        let startVerified = Set(ranked).subtracting(changed)
        let published = hits
        let publishedCounts = counts
        let publishedMatchCount = matchedRows + pendingMatches.count
        await MainActor.run {
            guard self.runID == runID else { return }
            metrics.record(.searchInstantFirstPublication, operationID: operation, status: .published,
                           counters: [.resultCount: Int64(out.count)])
            self.hits = published
            self.fieldCounts = publishedCounts
            self.matchCount = publishedMatchCount
            self.unindexedCount = unindexed
            self.updatingCount = changed.count
            self.skippedCount = skippedKeys.count
            self.isRanked = true
            self.results = out
            self.verifiedKeys = startVerified
            self.eligibleCount = eligible
            self.completeCount = startComplete
            self.incompleteCount = startIncomplete
            self.unresolvedCount = max(0, eligible - startComplete - startIncomplete)
            self.progress = .init(phase: live.isEmpty ? .idle : .unindexedSmall, scannedSmall: 0, totalSmall: live.count)
            if live.isEmpty { self.isRunning = false }
        }

        if !live.isEmpty {
            // Any word, like the index. The scanner reads each file as it is on disk now.
            let store = self.store
            let liveQuery: SearchQuery? = {
                guard let tokenizer = try? SearchTokenizer() else { return nil }
                let usable = parts.filter { ((try? tokenizer.tokens($0)) ?? []).isEmpty == false }
                return try? SearchQuery(usable.joined(separator: " OR "), tokenizer: tokenizer)
            }()
            deepScanTask?.cancel()
            deepScanTask = Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                var complete = startComplete, incomplete = startIncomplete, verified = startVerified
                var found: [Session] = []
                var lastPublication = ContinuousClock.now
                for (index, session) in live.enumerated() {
                    if Task.isCancelled { break }
                    guard let liveQuery else { break }
                    let key = SessionKey(session)
                    let result = await SearchMetricScope.$requestID.withValue(operation) {
                        await store.scan(session: session, query: liveQuery)
                    }
                    if Task.isCancelled { break }
                    if result.summary.complete { complete += 1 } else { incomplete += 1 }
                    // A hit is listed as the candidate the list already shows.
                    if result.truth == .yes, !shown.contains(key) {
                        verified.insert(key)
                        found.append(session)
                    }
                    if ContinuousClock.now - lastPublication >= .milliseconds(100) || index == live.count - 1 {
                        let batch = found
                        found.removeAll()
                        let counts = (complete, incomplete, verified)
                        await MainActor.run {
                            guard self.runID == runID else { return }
                            if !batch.isEmpty {
                                self.results.append(contentsOf: batch)
                                self.matchCount += batch.count
                            }
                            self.verifiedKeys = counts.2
                            self.completeCount = counts.0
                            self.incompleteCount = counts.1
                            self.unresolvedCount = max(0, eligible - counts.0 - counts.1)
                            self.progress.scannedSmall = index + 1
                        }
                        lastPublication = .now
                    }
                }
                if Task.isCancelled { await self.finishCanceled(runID: runID); return }
                await MainActor.run {
                    guard self.runID == runID else { return }
                    self.isRunning = false
                    self.progress.phase = .idle
                }
            }
        }

        // Tool text is indexed without being stored, so read those passages from the
        // transcripts of the top results after the list is already on screen.
        for key in ranked.prefix(Self.toolExcerptLimit) {
            guard let found = origin[key], !found.table.storesText, found.table != .title else { continue }
            let field = found.table
            if Task.isCancelled { return }
            guard let session = byKey[found.from],
                  let full = await store.parseFull(session: session),
                  let excerpt = SessionSearchTextBuilder.excerpt(session: full, field: field, query: highlight) else { continue }
            await MainActor.run {
                guard self.runID == runID else { return }
                self.hits[key]?.excerpt = excerpt
            }
        }
    }

    static func exactIdentityMatches(_ freeText: String, sessions: [Session]) -> [Session] {
        guard let tokens = try? SearchQuery.lex(freeText), tokens.count == 1 else { return [] }
        let raw = tokens[0].value
        guard !raw.contains("*") else { return [] }
        func normalized(_ value: String) -> String { UUID(uuidString: value)?.uuidString.lowercased() ?? value }
        let wanted = normalized(raw)
        return sessions.filter { session in
            var aliases = [session.id]
            if session.source == .codex || session.source == .claude {
                if let hint = session.codexInternalSessionIDHint { aliases.append(hint) }
                let basename = URL(fileURLWithPath: session.filePath).deletingPathExtension().lastPathComponent
                let candidate = session.source == .codex ? String(basename.suffix(36)) : basename
                if let id = UUID(uuidString: candidate) { aliases.append(id.uuidString) }
            }
            return aliases.contains { normalized($0) == wanted }
        }
    }

    private static func indexedCandidates(_ sessions: [Session], db: IndexDB, toolIO: Bool) async -> Set<String> {
        guard let source = sessions.first?.source else { return [] }
        let present = Set(toolIO
            ? ((try? await db.toolIOSessionIDs(sources: [source.rawValue])) ?? [])
            : ((try? await db.indexedSessionIDs(sources: [source.rawValue])) ?? []))
        var current = Set(toolIO
            ? ((try? await db.indexedToolIOSessionIDsCurrent(sources: [source.rawValue])) ?? [])
            : ((try? await db.indexedSessionIDsCurrent(sources: [source.rawValue])) ?? []))
        let identities = sessions.filter {
            $0.source.descriptor.searchUsesIdentityAtURL?(URL(fileURLWithPath: $0.filePath)) == true
        }
        if !identities.isEmpty {
            let states = toolIO
                ? ((try? await db.sessionToolIOIdentityStatesByID(for: source.rawValue)) ?? [:])
                : ((try? await db.sessionSearchIdentityStatesByID(for: source.rawValue)) ?? [:])
            for session in identities {
                current.remove(session.id)
                if let state = states[session.id], state.storagePath == session.filePath,
                   SearchIngestService.contentRevision(state.revision, matches: session) { current.insert(session.id) }
            }
        }
        return Set(sessions.map(\.id)).subtracting(present.subtracting(current))
    }

    static func searchRow(_ session: Session, title: String? = nil, path: String? = nil, parsedMetadata: Bool = false, id: String? = nil) -> Session {
        var row = Session(id: id ?? session.id, source: session.source, startTime: session.startTime,
            endTime: session.endTime, model: session.model, filePath: path ?? session.filePath,
            fileSizeBytes: session.fileSizeBytes, eventCount: session.eventCount, events: [],
            cwd: parsedMetadata ? session.cwd : session.lightweightCwd, repoName: parsedMetadata ? session.repoName : session.lightweightRepoName,
            lightweightTitle: title ?? session.listTitle, lightweightCommands: parsedMetadata ? session.events.filter { $0.kind == .tool_call }.count : session.lightweightCommands,
            isHousekeeping: session.isHousekeeping, codexInternalSessionIDHint: parsedMetadata ? session.codexInternalSessionID : session.codexInternalSessionIDHint,
            parentSessionID: session.parentSessionID, subagentType: session.subagentType,
            relationshipKind: session.relationshipKind, customTitle: title ?? session.customTitle,
            codexOriginator: session.codexOriginator, codexSource: session.codexSource,
            codexSurface: session.codexSurface, originator: session.originator,
            originSource: session.originSource, surface: session.surface,
            reasoningEffort: session.reasoningEffort, deletedAt: session.deletedAt)
        row.isFavorite = session.isFavorite
        row.sourceStorageIdentity = session.sourceStorageIdentity
        row.sourceStorageRevision = session.sourceStorageRevision
        row.sourcePreviewDigest = session.sourcePreviewDigest
        return row
    }

    static func shouldDeepScan(session: Session) -> Bool {
        let estimatedCommands: Int = {
            if let c = session.lightweightCommands { return c }
            if session.events.isEmpty { return 0 }
            return session.events.filter { $0.kind == .tool_call }.count
        }()
        return estimatedCommands > 0
    }

    static func shouldIncludeUnindexedCandidate(_ session: Session,
                                                indexedIDs: Set<SessionKey>,
                                                seenIDs: Set<SessionKey>,
                                                enableDeepScan: Bool,
                                                smallSearchThreshold: Int,
                                                staleIDs: Set<SessionKey> = []) -> Bool {
        let key = SessionKey(session)
        guard !indexedIDs.contains(key), !seenIDs.contains(key) else { return false }
        if enableDeepScan { return true }
        if session.source == .cursor { return true }
        // A session whose `session_search` row exists but is out of date (changed-but-not-yet-reingested,
        // held back by SearchIngestService's quiet/cooldown gates) has NO fresh FTS coverage, so it must
        // be scanned even if it is over the small-size threshold — otherwise a large hot transcript stays
        // unfindable for the whole re-ingest delay. `indexedIDs` (currency-aware) already excludes it; this
        // additionally bypasses the size gate that would otherwise drop a large stale file.
        if staleIDs.contains(key) { return true }
        return sizeBytes(for: session) < smallSearchThreshold
    }

    /// Builds an FTS5 query for Instant search.
    ///
    /// We avoid trigram/substr indexing, but we can still improve recall (especially for identifiers)
    /// by using FTS prefix queries when the user's input is a simple space-delimited term list.
    private static func candidates(from all: [Session], allowed: Set<SessionSource>, filters: Filters) -> [Session] {
        let sideChatsOnly = filters.sideChatsOnly || FilterEngine.parseOperators(filters.query).sideChatsOnly
        return all.filter { session in
            guard allowed.contains(session.source) else { return false }
            // Archive filter scopes only Codex; explicit side-chat searches should include
            // recovered log rows even though those rows are not archived JSONL sessions.
            if !sideChatsOnly, filters.archivedCodexDesktopOnly, session.source == .codex, !session.isArchivedCodexDesktopSession {
                return false
            }
            return true
        }
    }

    private static func metadataFilteredCandidates(_ candidates: [Session],
                                                    filters: Filters,
                                                    effectiveRepo: String?,
                                                    effectivePath: String?,
                                                    effectiveSideChatsOnly: Bool? = nil,
                                                    effectiveProjectIdentity: ProjectIdentity? = nil) -> [Session] {
        let metadataFilters = Filters(query: "",
                                       dateFrom: filters.dateFrom,
                                       dateTo: filters.dateTo,
                                       model: filters.model,
                                       kinds: filters.kinds,
                                       repoName: effectiveRepo,
                                       pathContains: effectivePath,
                                       archivedCodexDesktopOnly: filters.archivedCodexDesktopOnly,
                                       archivedClaudeDesktopOnly: filters.archivedClaudeDesktopOnly,
                                       archivedClaudeSessionIDs: filters.archivedClaudeSessionIDs,
                                       sideChatsOnly: effectiveSideChatsOnly ?? filters.sideChatsOnly,
                                       selectedProjectIdentity: effectiveProjectIdentity ?? filters.selectedProjectIdentity,
                                       hiddenProjectRoots: filters.hiddenProjectRoots)
        return FilterEngine.filterSessions(candidates,
                                           filters: metadataFilters,
                                           transcriptCache: nil,
                                           allowTranscriptGeneration: false)
    }

    private func finishCanceled(runID expected: UUID) async {
        await MainActor.run {
            if self.runID == expected {
                self.isRunning = false
                self.wasCanceled = true
                self.progress.phase = .idle
            }
        }
    }

    private static func sizeBytes(for s: Session) -> Int {
        if let b = s.fileSizeBytes { return b }
        let p = s.filePath
        if let num = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? NSNumber)?.intValue { return num }
        return 0
    }
}

extension Array {
    func chunks(of n: Int) -> [ArraySlice<Element>] {
        guard n > 0 else { return [self[...]] }
        return stride(from: 0, to: count, by: n).map { self[$0..<Swift.min($0 + n, count)] }
    }
}
