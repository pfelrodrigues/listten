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
    private var rotations = 0
    private var state = State.idle

    /// Derived from the count, never accumulated: a running sum drifts and hands
    /// out an index twice on a rotation that does not divide the length.
    private var closed: TimeInterval { Double(rotations) * rotateEvery }

    init(length: TimeInterval, rotateEvery: TimeInterval) {
        precondition(rotateEvery > 0, "a rotation of zero never advances")
        self.length = length
        self.rotateEvery = rotateEvery
    }

    func start() async throws -> AsyncStream<Segment> {
        guard state == .idle else { throw CaptureAlreadyStarted() }
        state = .running

        var rotated: [Segment] = []
        while closed + rotateEvery <= length {
            rotated += segments(index: rotations, start: closed, duration: rotateEvery)
            rotations += 1
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
        // The next index, not one recomputed from time: the last rotation already used its own.
        return segments(index: rotations, start: closed, duration: remaining)
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
