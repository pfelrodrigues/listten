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
        stored.values.filter { !$0.state.isTerminal }.sorted { $0.id < $1.id }
    }
}

actor RecordingPromptSpy: RecordingPrompting {
    private(set) var asked: [String] = []

    func askWhetherToRecord(sessionID: String) async {
        asked.append(sessionID)
    }
}

/// Replays a recording of a known length as if it were live, rotating on the
/// same interval as real capture, so the pipeline can be driven without audio
/// hardware or permissions.
actor FakeAudioCapture: AudioCapturing {
    private enum State {
        case idle, running, stopped
    }

    private let length: TimeInterval
    private let rotateEvery: TimeInterval
    private var closed: TimeInterval = 0
    private var state = State.idle

    init(length: TimeInterval, rotateEvery: TimeInterval) {
        precondition(rotateEvery > 0, "a rotation of zero never advances")
        self.length = length
        self.rotateEvery = rotateEvery
    }

    func start() async throws -> AsyncStream<Segment> {
        guard state == .idle else { throw CaptureAlreadyStarted() }
        state = .running

        var rotated: [Segment] = []
        var index = 0
        while closed + rotateEvery <= length {
            rotated += segments(index: index, start: closed, duration: rotateEvery)
            closed += rotateEvery
            index += 1
        }
        return AsyncStream { continuation in
            rotated.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func stop() async throws -> [Segment] {
        guard state == .running else { return [] }
        state = .stopped

        let remaining = length - closed
        guard remaining > 0 else { return [] }
        let partials = segments(
            index: Int(closed / rotateEvery),
            start: closed,
            duration: remaining
        )
        closed = length
        return partials
    }

    /// Both tracks close together, on the same instants.
    private func segments(index: Int, start: TimeInterval, duration: TimeInterval) -> [Segment] {
        Track.allCases.map {
            Segment(index: index, track: $0, start: start, duration: duration)
        }
    }
}

struct FixedTimeSource: TimeSource {
    var now = Date(timeIntervalSince1970: 0)
}
