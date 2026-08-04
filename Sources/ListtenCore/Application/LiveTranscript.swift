import Foundation

/// Follows a recording as it happens and writes what it hears where another
/// program can read it while the meeting is still running.
///
/// One backend per track, opened on the first buffer that track delivers.
/// Attribution comes free from that: microphone lines are the user and system
/// lines are everyone else, because the tracks were separate before
/// transcription started. Opening lazily is also what keeps a refused session
/// free — a meeting nobody confirmed hands over no audio, so no analyser is
/// built and no model is made resident.
///
/// Nothing here can cost the recording. It reads a stream the capture yields
/// into without ever waiting for it, and every failure it meets is recorded and
/// reported rather than raised: a perfectly recorded meeting must not read as
/// failed because a transcript for following along stopped growing.
public actor LiveTranscript {
    /// What a caller can say about the transcript afterwards. The three ways it
    /// can be short are told apart, because a reader otherwise cannot tell a
    /// complete transcript from one with a hole in it.
    public struct Outcome: Sendable, Equatable {
        public let lines: Int
        /// Buffers the live side never saw. Every instant on that track after
        /// one is early by the audio that went missing, so this is a warning
        /// about the instants as much as about the words.
        public let dropped: Int
        /// Audio arrived after the sink was finished, so the transcript stops
        /// short of the meeting and nothing else would say so.
        public let endedEarly: Bool
        /// The first thing that went wrong, which is usually what explains the
        /// rest of them.
        public let failure: String?
    }

    /// Buffers and settles the backend never saw, which is not the same count as
    /// the sink's: this one is the queue in front of the analyser.
    private var behind = 0

    private func record(_ result: AsyncStream<LiveAudioEvent>.Continuation.YieldResult) {
        switch result {
        case .enqueued: return
        case .dropped, .terminated: behind += 1
        @unknown default: behind += 1
        }
    }

    private struct Feed {
        let feeding: AsyncStream<LiveAudioEvent>.Continuation
        let reader: Task<Void, Never>
    }

    /// About five seconds of one track at the buffers the devices deliver. A
    /// backend that falls behind loses audio rather than growing memory, which
    /// is the same bargain the sink in front of it makes.
    private static let backlog = 64

    private let audio: AsyncStream<LiveAudio>
    private let sink: any LiveAudioSink
    private let backend: any LiveTranscribing
    private let writer: any LiveTranscriptWriting
    private let sessionID: String
    private let language: String
    private let settleEvery: TimeInterval

    private var feeds: [Track: Feed] = [:]
    private var cadences: [Track: SettleCadence] = [:]
    private var refused: Set<Track> = []
    private var lines = 0
    private var failure: String?

    /// `sink` is the same object `audio` came out of. It is asked separately
    /// because what a stream delivered says nothing about what it dropped, and
    /// the count has to reach whoever reports the meeting.
    public init(
        audio: AsyncStream<LiveAudio>,
        sink: any LiveAudioSink,
        backend: any LiveTranscribing,
        writer: any LiveTranscriptWriting,
        sessionID: String,
        language: String,
        settleEvery: TimeInterval = 5
    ) {
        // Checked here rather than left to the first buffer, so a cadence that
        // cannot work fails before the meeting instead of a minute into it.
        precondition(settleEvery > 0)
        self.audio = audio
        self.sink = sink
        self.backend = backend
        self.writer = writer
        self.sessionID = sessionID
        self.language = language
        self.settleEvery = settleEvery
    }

    public func outcome() -> Outcome {
        Outcome(
            // Both places audio can go missing. The sink drops what the fork
            // could not hand over; this one drops what the backend could not
            // keep up with, and counting only the first made a transcript with a
            // hole in it report nothing dropped at all.
            lines: lines,
            dropped: sink.dropped + behind,
            endedEarly: sink.endedEarly,
            failure: failure
        )
    }

    /// Returns once the audio has ended and every trailing line has been
    /// written, so a caller that awaits this has the whole meeting.
    public func run() async {
        for await live in audio {
            guard !refused.contains(live.track) else { continue }
            if feeds[live.track] == nil {
                await open(live.track, from: live.start)
            }
            guard let feed = feeds[live.track] else { continue }

            // The backlog is bounded, so a backend that falls behind loses audio
            // rather than growing memory. What it must not do is lose it in
            // silence: a transcript with a minute missing reads exactly like a
            // minute nobody spoke in.
            record(feed.feeding.yield(.audio(live.audio)))

            var cadence = cadences[live.track] ?? SettleCadence(every: settleEvery)
            let settled = cadence.admitting(live.audio)
            cadences[live.track] = cadence
            guard settled else { continue }
            record(feed.feeding.yield(.settle))
        }

        // Finished first and awaited afterwards: a backend finalizes what is
        // left when its input ends, and those lines are the last thing anybody
        // said.
        for feed in feeds.values {
            feed.feeding.finish()
        }
        for feed in feeds.values {
            await feed.reader.value
        }
    }

    private func open(_ track: Track, from offset: TimeInterval) async {
        let (heard, feeding) = AsyncStream<LiveAudioEvent>
            .makeStream(
                bufferingPolicy: .bufferingNewest(Self.backlog)
            )
        do {
            let events = try await backend.transcribe(
                LiveTranscriptionRequest(language: language),
                hearing: heard
            )
            feeds[track] = Feed(
                feeding: feeding,
                reader: Task { [weak self] in await self?.read(events, of: track, from: offset) }
            )
        } catch {
            // A backend that will not take this track costs that track's
            // transcript and nothing else. The other track keeps being written,
            // and the recording never noticed.
            refused.insert(track)
            feeding.finish()
            record(error)
        }
    }

    private func read(
        _ events: AsyncThrowingStream<TranscriptionEvent, any Error>,
        of track: Track,
        from offset: TimeInterval
    ) async {
        do {
            for try await event in events {
                // Hypotheses are what the cadence exists to replace: they arrive
                // three times a second carrying the whole accumulated text, and
                // a file rewritten that often is not one a reader can follow.
                guard case .line(let line) = event else { continue }
                do {
                    try await write(line, of: track, from: offset)
                } catch {
                    // One line that could not be written is not the end of the
                    // transcript, and the next one may well land.
                    record(error)
                }
            }
        } catch {
            record(error)
        }
    }

    private func write(
        _ line: TranscriptLine,
        of track: Track,
        from offset: TimeInterval
    ) async throws {
        // The backend counts from the first buffer it was handed; the offset is
        // where that buffer sat in the session, which only this knows.
        try await writer.append(
            LiveLine(
                track: track,
                start: offset + line.start,
                end: offset + line.end,
                text: line.text
            ),
            for: sessionID
        )
        lines += 1
    }

    private func record(_ error: any Error) {
        failure = failure ?? String(describing: error)
    }
}
