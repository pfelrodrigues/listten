import Foundation

@testable import ListtenCore

actor InMemorySessionStore: SessionStoring {
    private var stored: [String: Session] = [:]

    func save(_ session: Session) async throws {
        stored[session.id] = session
    }

    func load(id: String) async throws -> Session? {
        stored[id]
    }

    func unfinished() async throws -> [Session] {
        stored.values.filter { !$0.state.isTerminal }
    }
}

actor RecordingPromptSpy: RecordingPrompting {
    private(set) var asked: [String] = []

    func askWhetherToRecord(sessionID: String) async {
        asked.append(sessionID)
    }
}

struct FixedTimeSource: TimeSource {
    var now = Date(timeIntervalSince1970: 0)
}
