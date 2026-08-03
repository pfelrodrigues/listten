import Foundation

@testable import ListtenCore

actor InMemorySessionStore: SessionStoring {
    /// Without this the fake has no unreadable state to have, so the rule the
    /// port promises about it would be met by production alone.
    struct Unreadable: Error {
        let id: String
    }

    private var stored: [String: Session] = [:]
    private var corrupted: Set<String> = []

    func corrupt(id: String) {
        corrupted.insert(id)
    }

    func save(_ session: Session) async throws {
        stored[session.id] = session
    }

    func load(id: String) async throws -> Session? {
        guard !corrupted.contains(id) else { throw Unreadable(id: id) }
        return stored[id]
    }

    func unfinished() async throws -> UnfinishedSessions {
        UnfinishedSessions(
            sessions: stored.values
                .filter { !corrupted.contains($0.id) && !$0.state.isTerminal }
                .sorted { $0.id < $1.id },
            unreadable: corrupted.sorted()
        )
    }
}

actor RecordingPromptSpy: RecordingPrompting {
    private(set) var asked: [String] = []

    func askWhetherToRecord(sessionID: String) async {
        asked.append(sessionID)
    }
}

/// A device that is not there: delivers a fixed number of buffers and stops.
/// Held to the same contract as the microphone by `verifyAudioSourceContract`.
actor FakeAudioSource: AudioSource {
    private enum State {
        case idle, running, stopped
    }

    private let buffers: Int
    private let sampleRate: Double
    private var state = State.idle

    init(buffers: Int, sampleRate: Double = 48000) {
        self.buffers = buffers
        self.sampleRate = sampleRate
    }

    func start() async throws -> AsyncStream<CapturedAudio> {
        guard state == .idle else { throw CaptureAlreadyStarted() }
        state = .running

        let frames = Int(sampleRate / 10)
        let audio = (0..<buffers)
            .map { index in
                CapturedAudio(
                    hostTime: 1000 + Double(index) / 10,
                    sampleRate: sampleRate,
                    samples: Array(repeating: 0.25, count: frames)
                )
            }
        return AsyncStream { continuation in
            audio.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func stop() async {
        guard state == .running else { return }
        state = .stopped
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
