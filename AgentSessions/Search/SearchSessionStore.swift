import Foundation
import Dispatch

protocol SearchSessionStoring {
    func transcriptCache(for source: SessionSource) -> TranscriptCache?
    func updateSession(_ session: Session)
    func parseFull(session: Session) async -> Session?
    /// Parses the file even when `session` holds events: they can lag a file still being written.
    func reread(session: Session) async -> Session?
}

extension SearchSessionStoring {
    func reread(session: Session) async -> Session? { await parseFull(session: session) }
}

final class SearchSessionStore: SearchSessionStoring {
    struct Adapter {
        struct UpdateHandler: @unchecked Sendable {
            let call: (Session) -> Void

            init(_ call: @escaping (Session) -> Void) {
                self.call = call
            }
        }

        var transcriptCache: TranscriptCache
        var update: UpdateHandler
        var parseFull: (URL, String) -> Session?

        init(transcriptCache: TranscriptCache,
             update: @escaping (Session) -> Void,
             parseFull: @escaping (URL, String) -> Session?) {
            self.transcriptCache = transcriptCache
            self.update = UpdateHandler(update)
            self.parseFull = parseFull
        }
    }

    private let adapters: [SessionSource: Adapter]

    init(adapters: [SessionSource: Adapter]) {
        self.adapters = adapters
    }

    func transcriptCache(for source: SessionSource) -> TranscriptCache? {
        adapters[source]?.transcriptCache
    }

    func updateSession(_ session: Session) {
        guard let update = adapters[session.source]?.update else { return }
        DispatchQueue.main.async {
            update.call(session)
        }
    }

    func parseFull(session: Session) async -> Session? {
        guard session.events.isEmpty else { return session }
        return await reread(session: session)
    }

    func reread(session: Session) async -> Session? {
        guard let adapter = adapters[session.source] else { return nil }
        return adapter.parseFull(URL(fileURLWithPath: session.filePath), session.id)
    }
}
