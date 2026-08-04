import Foundation
import Synchronization

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

/// Progress kept in memory, standing for the logs on disk. Held to the same
/// contract as them by `verifyProgressLoggingContract`.
actor InMemoryProgressLog: ProgressLogging {
    /// Without this the fake has no log that cannot be read, so what recovery
    /// does with one would be answered for by the file-backed log alone.
    struct Unreadable: Error {
        let id: String
    }

    private var logged: [String: [Checkpoint]] = [:]
    private var corrupted: Set<String> = []

    func corrupt(id: String) {
        corrupted.insert(id)
    }

    func append(_ checkpoint: Checkpoint, for sessionID: String) async throws {
        logged[sessionID, default: []].append(checkpoint)
    }

    func checkpoints(for sessionID: String) async throws -> [Checkpoint] {
        guard !corrupted.contains(sessionID) else { throw Unreadable(id: sessionID) }
        return logged[sessionID] ?? []
    }
}

/// Stands for whatever the notification centre refuses with.
struct PromptUndeliverable: Error, Equatable {}

actor RecordingPromptSpy: RecordingPrompting {
    private let failure: (any Error)?

    /// Every call, delivered or not, so a caller that asks twice is visible.
    private(set) var attempts: [String] = []

    /// Only the calls that reached the user.
    private(set) var asked: [String] = []

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    func askWhetherToRecord(sessionID: String) async throws {
        attempts.append(sessionID)
        if let failure { throw failure }
        asked.append(sessionID)
    }
}

/// A clock a test moves by hand, rather than one that runs with the wall.
///
/// It conforms to `TimeSource` so that whatever is measuring the capture reads
/// the same instant the buffers were stamped with, and a test can assert what
/// something held at that instant without the suite sleeping for it.
final class ManualTimeSource: TimeSource {
    private let instant: Mutex<Date>

    /// Never the epoch, whatever a caller asks for: a source is contractually
    /// forbidden a buffer stamped at zero, which is where it would stamp its first.
    init(now: Date = Date(timeIntervalSince1970: 1000)) {
        precondition(
            now.timeIntervalSince1970 > 0,
            "a clock at the epoch leaves the first buffer unstamped"
        )
        instant = Mutex(now)
    }

    var now: Date { instant.withLock { $0 } }

    /// Named for setting rather than advancing, since the sources sharing one
    /// derive the instant: moving this clock alone produces no audio.
    func set(to next: Date) {
        instant.withLock { $0 = next }
    }
}

/// A device that is not there. Either it delivers a fixed number of buffers and
/// finishes, or it delivers whatever the time a test hands it was worth.
/// Held to the same contract as the microphone by `verifyAudioSourceContract`.
actor FakeAudioSource: AudioSource {
    private enum State {
        case idle, running, stopped
    }

    /// Where the buffers come from: its own count, or the test's clock.
    private enum Drive {
        case buffers(Int)
        case clock
    }

    private let drive: Drive
    private let clock: ManualTimeSource
    private let origin: TimeInterval
    private let sampleRate: Double
    private let bufferDuration: TimeInterval
    private let frames: Int

    private var elapsed: TimeInterval = 0
    private var produced = 0
    private var continuation: AsyncStream<CapturedAudio>.Continuation?
    private var state = State.idle

    /// Self-driving: the stream carries that many buffers and finishes at once.
    ///
    /// `startingAt` stamps the first buffer, so two sources can be staged
    /// starting at different instants, which is what two real devices do.
    init(
        buffers: Int,
        sampleRate: Double = 48000,
        bufferDuration: TimeInterval = 0.1,
        startingAt origin: TimeInterval? = nil
    ) {
        self.init(
            drive: .buffers(buffers),
            clock: origin.map { ManualTimeSource(now: Date(timeIntervalSince1970: $0)) }
                ?? ManualTimeSource(),
            sampleRate: sampleRate,
            bufferDuration: bufferDuration
        )
    }

    /// Clock-driven: nothing is delivered until `advance(by:)` moves the clock,
    /// and the stream stays open until this source is stopped.
    init(clock: ManualTimeSource, sampleRate: Double = 48000, bufferDuration: TimeInterval = 0.1) {
        self.init(
            drive: .clock,
            clock: clock,
            sampleRate: sampleRate,
            bufferDuration: bufferDuration
        )
    }

    private init(
        drive: Drive,
        clock: ManualTimeSource,
        sampleRate: Double,
        bufferDuration: TimeInterval
    ) {
        precondition(bufferDuration > 0, "a buffer of no duration never fills")
        self.drive = drive
        self.clock = clock
        self.origin = clock.now.timeIntervalSince1970
        self.sampleRate = sampleRate
        self.bufferDuration = bufferDuration
        self.frames = Int(sampleRate * bufferDuration)
    }

    func start() async throws -> AsyncStream<CapturedAudio> {
        guard state == .idle else { throw CaptureAlreadyStarted() }
        state = .running

        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        self.continuation = continuation
        if case .buffers(let count) = drive {
            advance(by: Double(count) * bufferDuration)
            // Done before start returns, so it is no longer running and holds no
            // continuation: time passing now would yield into a finished stream.
            continuation.finish()
            self.continuation = nil
            state = .stopped
        }
        return stream
    }

    /// Moves the clock and delivers the buffers that instant went past. Time the
    /// device spent producing is what makes a buffer, so a caller that never
    /// advances hears nothing at all.
    func advance(by interval: TimeInterval) {
        precondition(interval >= 0, "a device does not un-produce audio")
        // Time passing before start, after stop, or once a source finished its
        // own stream leaves the buffers it was worth yielded into nothing.
        precondition(state == .running, "a source that is not running produces nothing")
        elapsed += interval
        // Absolute, so two sources over the same window write the same instant.
        // Compared as Dates, whose own precision absorbs how each one got there.
        let next = Date(timeIntervalSince1970: origin + elapsed)
        precondition(next >= clock.now, "a source may not push a shared clock backwards")
        clock.set(to: next)

        // Slack of a nanosecond, since three tenths of a second is not three
        // buffers of a tenth once both are Doubles.
        while Double(produced + 1) * bufferDuration <= elapsed + 1e-9 {
            let audio = CapturedAudio(
                hostTime: origin + Double(produced) * bufferDuration,
                sampleRate: sampleRate,
                samples: Array(repeating: 0.25, count: frames)
            )
            continuation?.yield(audio)
            produced += 1
        }
    }

    func stop() async {
        guard state == .running else { return }
        state = .stopped
        continuation?.finish()
        continuation = nil
    }
}

/// The live transcript kept in memory, standing for the file on disk. Held to
/// the same contract as it by `verifyLiveTranscriptWritingContract`.
actor InMemoryLiveTranscripts: LiveTranscriptWriting {
    /// Without this the fake has no way to refuse a line, so what an orchestrator
    /// does when the transcript stops taking them would be answered for by a full
    /// disk alone.
    struct Refused: Error, Equatable {}

    private var written: [String: [LiveLine]] = [:]
    private var refusing: Set<Int> = []
    private var offered = 0
    private var pause: Duration = .zero

    /// A transcript still being written when the recording stops. Without one, a
    /// caller that waits for the live side and a caller that walks away from it
    /// are indistinguishable, since a fake that answers instantly is finished
    /// either way.
    func takesItsTime(_ pause: Duration) {
        self.pause = pause
    }

    /// Which appends fail, counted from zero across every session. Naming them
    /// rather than a cut-off is what lets a failure in the middle be staged: a
    /// disk that filled up for good and one line that did not land are
    /// different things, and only the second says whether the next one still
    /// does.
    func refuse(appends: Set<Int>) {
        refusing = appends
    }

    func append(_ line: LiveLine, for sessionID: String) async throws {
        let index = offered
        offered += 1
        guard !refusing.contains(index) else { throw Refused() }
        if pause != .zero {
            try await Task.sleep(for: pause)
        }
        written[sessionID, default: []].append(line)
    }

    func lines(for sessionID: String) -> [LiveLine] {
        written[sessionID] ?? []
    }
}

/// A live sink that keeps what it was handed, standing for the streaming one.
///
/// Bounded like it is, and dropping the other end of the queue: it keeps the
/// oldest buffers where the streaming sink keeps the newest. The contract has to
/// hold for both, which is what stops it from writing down one implementation's
/// policy as though it were a rule.
final class InMemoryLiveAudioSink: LiveAudioSink {
    private struct State {
        var held: [LiveAudio] = []
        var dropped = 0
        var finished = false
        var handedAfterFinish = false
    }

    private let capacity: Int
    private let state = Mutex(State())

    init(capacity: Int = StreamingLiveAudioSink.defaultCapacity) {
        self.capacity = capacity
    }

    func hand(_ live: LiveAudio) {
        state.withLock { state in
            guard !state.finished else {
                state.handedAfterFinish = true
                return
            }
            guard state.held.count < capacity else {
                state.dropped += 1
                return
            }
            state.held.append(live)
        }
    }

    func finish() {
        state.withLock { $0.finished = true }
    }

    var dropped: Int { state.withLock { $0.dropped } }

    var endedEarly: Bool { state.withLock { $0.handedAfterFinish } }

    var received: [LiveAudio] { state.withLock { $0.held } }
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
            rotated += try segments(index: rotations, start: closed, duration: rotateEvery)
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
        return try segments(index: rotations, start: closed, duration: remaining)
    }

    /// Both tracks close together, on the same instants.
    private func segments(
        index: Int,
        start: TimeInterval,
        duration: TimeInterval
    ) throws
        -> [Segment]
    {
        try Track.allCases.map {
            try Segment(index: index, track: $0, start: start, duration: duration)
        }
    }
}

/// A capture that runs and then refuses to be finalized, which is what a disk
/// filling up during the last write looks like from the recorder.
actor CaptureThatFailsToStop: AudioCapturing {
    struct Refused: Error, Equatable {}

    func start() async throws -> AsyncStream<Segment> {
        AsyncStream { $0.finish() }
    }

    func stop() async throws -> [Segment] {
        throw Refused()
    }
}

struct FixedTimeSource: TimeSource {
    var now = Date(timeIntervalSince1970: 0)
}

/// A fake the contract can write into, which `FakeRecordedAudio` cannot: it is
/// built from what it will answer with and never told anything afterwards.
actor FakeRecordedAudioStore: RecordedAudio {
    private var stored: [String: [SegmentFile]] = [:]

    func put(_ files: [SegmentFile], for sessionID: String) {
        stored[sessionID] = files
    }

    func segments(for sessionID: String) async throws -> [SegmentFile] {
        stored[sessionID] ?? []
    }
}

actor FakeRecordedAudio: RecordedAudio {
    private let stored: [String: [SegmentFile]]

    init(segments: [String: [SegmentFile]]) {
        stored = segments
    }

    func segments(for sessionID: String) async throws -> [SegmentFile] {
        stored[sessionID] ?? []
    }
}

struct FailingRecordedAudio: RecordedAudio {
    struct Unlistable: Error {}

    func segments(for sessionID: String) async throws -> [SegmentFile] {
        throw Unlistable()
    }
}

actor RefusingAudioSource: AudioSource {
    struct Refused: Error, Equatable {}

    func start() async throws -> AsyncStream<CapturedAudio> {
        throw Refused()
    }

    func stop() async {}
}

/// A store that takes a session in and refuses the ones that follow, which is
/// what a disk filling up mid-recording looks like from here.
actor StoreThatRefusesToSave: SessionStoring {
    struct Refused: Error, Equatable {}

    private var stored: [String: Session] = [:]
    private var accepted = 0

    func save(_ session: Session) async throws {
        guard accepted < 2 else { throw Refused() }
        accepted += 1
        stored[session.id] = session
    }

    func load(id: String) async throws -> Session? { stored[id] }

    func unfinished() async throws -> UnfinishedSessions {
        UnfinishedSessions(sessions: stored.values.filter { !$0.state.isTerminal })
    }
}

actor InMemoryTranscripts: TranscriptStoring {
    struct Unreadable: Error {
        let id: String
    }

    private var stored: [String: CorrectedTranscript] = [:]
    private var corrupted: Set<String> = []

    /// What a half-written file on disk looks like from here, so the rule that a
    /// damaged transcript is refused rather than read as absent is one both
    /// implementations answer to.
    func corrupt(_ sessionID: String) {
        corrupted.insert(sessionID)
    }

    func save(_ transcript: CorrectedTranscript, for sessionID: String) async throws {
        stored[sessionID] = transcript
    }

    func load(for sessionID: String) async throws -> CorrectedTranscript? {
        guard !corrupted.contains(sessionID) else { throw Unreadable(id: sessionID) }
        return stored[sessionID]
    }
}

/// Parks work where it waits, so a test can act while it is waiting rather than
/// race it.
actor Gate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var opened = false

    nonisolated var sleeping: @Sendable (Duration) async throws -> Void {
        { _ in await self.wait() }
    }

    func open() {
        opened = true
        waiting?.resume()
        waiting = nil
    }

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiting = $0 }
    }
}

/// Answers from a table keyed by file name, so a test says what a recording is
/// in rather than depending on a model to work it out.
struct FakeLanguageDetection: LanguageDetecting {
    let candidates: [String]
    private let heard: [String: String]

    init(candidates: [String], heard: [String: String]) {
        self.candidates = candidates
        self.heard = heard
    }

    func language(of sample: SegmentFile) async throws -> String? {
        heard[sample.url.lastPathComponent]
    }
}

/// Refuses one save and takes every other, which is what a segment lost to a
/// momentary failure looks like: the recording carries on and stopping works.
actor StoreThatRefusesOneSave: SessionStoring {
    struct Refused: Error, Equatable {}

    private var stored: [String: Session] = [:]
    private var saves = 0
    private let refusing: Int

    init(refusing: Int) {
        self.refusing = refusing
    }

    func save(_ session: Session) async throws {
        saves += 1
        guard saves != refusing else { throw Refused() }
        stored[session.id] = session
    }

    func load(id: String) async throws -> Session? { stored[id] }

    func unfinished() async throws -> UnfinishedSessions {
        UnfinishedSessions(sessions: stored.values.filter { !$0.state.isTerminal })
    }
}

/// A store that cannot be listed, which is a sessions directory that will not
/// read: the meetings are there and nothing can find out what they are.
actor StoreThatCannotBeListed: SessionStoring {
    struct Unlistable: Error, Equatable {}

    private var stored: [String: Session] = [:]

    func save(_ session: Session) async throws { stored[session.id] = session }

    func load(id: String) async throws -> Session? { stored[id] }

    func unfinished() async throws -> UnfinishedSessions { throw Unlistable() }
}
