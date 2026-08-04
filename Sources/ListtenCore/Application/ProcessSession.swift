import Foundation

/// Walks a recorded session to a written note.
///
/// Transcribe each segment, put the lines back where they belong on the session
/// clock, merge the tracks, correct, keep both transcripts, render, write.
///
/// Nothing here deletes audio, and nothing rewrites a segment. Every artefact
/// after the audio is reproducible from it, which is what makes running this
/// again the answer to a failure: a session left part-way through is picked up
/// where it stands and the work is redone from the audio rather than resumed
/// from half a transcript. Transcription runs at better than a hundred times
/// real time, so redoing it costs less than persisting partial results would.
///
/// There is no summary yet: #21 has the backend and until it exists a note
/// carries its transcript and says so, rather than carrying a port nothing
/// implements.
public struct ProcessSession: Sendable {
    /// A session that has not finished recording, or one already finished with.
    /// Everything between is fair game, because that is what resuming means.
    public struct NotProcessable: Error, Equatable {
        public let id: String
        public let state: SessionState
    }

    public struct NoAudio: Error, Equatable {
        public let id: String
    }

    /// Audio on disk the session does not name, which a crash between closing a
    /// segment and recording that it closed leaves behind. Writing the note
    /// without it would lose that stretch of the meeting for good, since a
    /// completed session is terminal and recovery only looks at unfinished ones.
    ///
    /// Adopting it belongs to `ResumeInterrupted`, which runs at startup over
    /// every unfinished session and is what makes this a delay rather than a
    /// dead end: refusing leaves the session where it stands, recovery adopts
    /// the file, and the next run processes the whole meeting.
    public struct UnaccountedAudio: Error, Equatable {
        public let id: String
        public let track: Track
        public let index: Int
    }

    /// A segment the session recorded whose file is not on disk. Skipping it
    /// would hand back a transcript missing that stretch with nothing saying so,
    /// and a note quietly missing a minute of a meeting is worse than no note.
    public struct SegmentMissing: Error, Equatable {
        public let id: String
        public let track: Track
        public let index: Int
    }

    private let sessions: any SessionStoring
    private let progress: any ProgressLogging
    private let audio: any RecordedAudio
    private let transcripts: any TranscriptStoring
    private let transcriber: any Transcribing
    private let notes: any NoteWriting
    private let glossary: Glossary
    private let language: String

    public init(
        sessions: any SessionStoring,
        progress: any ProgressLogging,
        audio: any RecordedAudio,
        transcripts: any TranscriptStoring,
        transcriber: any Transcribing,
        notes: any NoteWriting,
        glossary: Glossary,
        language: String
    ) {
        self.sessions = sessions
        self.progress = progress
        self.audio = audio
        self.transcripts = transcripts
        self.transcriber = transcriber
        self.notes = notes
        self.glossary = glossary
        self.language = language
    }

    public func callAsFunction(sessionID: String) async throws -> NoteLocation {
        guard let recorded = try await sessions.load(id: sessionID) else {
            throw SessionNotFound(id: sessionID)
        }
        // Anything between recorded and completed, so a run that died part-way
        // through is picked up rather than stranded: the state machine has no
        // arc back to recorded, and refusing everything else made a transient
        // failure permanent.
        guard Self.pipeline.dropLast().contains(recorded.state) else {
            throw NotProcessable(id: sessionID, state: recorded.state)
        }

        let files = try await audio.segments(for: sessionID)
        guard !files.isEmpty else { throw NoAudio(id: sessionID) }
        try accountFor(files, against: recorded.segments, of: sessionID)

        var session = try await advancing(recorded, to: .transcribing)
        let transcript = try await transcribing(recorded.segments, from: files, of: sessionID)

        // Correction is derived and both survive, which is why this is one value
        // rather than a transcript that was overwritten in place.
        let corrected = try CorrectedTranscript(raw: transcript, glossary: glossary)
        try await transcripts.save(corrected, for: sessionID)

        session = try await advancing(session, to: .transcribed)
        session = try await advancing(session, to: .summarizing)

        let note = MeetingNote(
            title: sessionID,
            summary: "",
            actionItems: [],
            transcript: corrected.corrected
        )
        let location = try await PerformStep(progress: progress)(.writingNote, of: sessionID) {
            try await notes.write(note, for: sessionID)
        }

        _ = try await advancing(session, to: .completed)
        return location
    }

    /// Each file on its own, then put back where it sits in the session.
    ///
    /// Driven by the session's segments rather than by the files, because only
    /// the session knows where each one starts. Deriving that from the index
    /// would assume every segment is the same length, which the last one never
    /// is and a device swap makes false for the rest.
    private func transcribing(
        _ segments: [Segment],
        from files: [SegmentFile],
        of sessionID: String
    ) async throws -> Transcript {
        var byTrack: [Track: [TranscriptLine]] = [:]

        for segment in segments.sorted(by: { $0.start < $1.start }) {
            guard
                let file = files.first(where: {
                    $0.track == segment.track && $0.index == segment.index
                })
            else {
                throw SegmentMissing(
                    id: sessionID,
                    track: segment.track,
                    index: segment.index
                )
            }

            let lines = try await PerformStep(progress: progress)(
                .transcribingSegment(track: segment.track, index: segment.index),
                of: sessionID
            ) {
                try await read(file, startingAt: segment.start)
            }
            byTrack[segment.track, default: []] += lines
        }

        return Transcript.merging(
            microphone: byTrack[.microphone] ?? [],
            system: byTrack[.system] ?? []
        )
    }

    private func read(
        _ file: SegmentFile,
        startingAt offset: TimeInterval
    ) async throws
        -> [TranscriptLine]
    {
        let stream = try await transcriber.transcribe(
            TranscriptionRequest(audio: [file.track: file.url], language: language)
        )

        var lines: [TranscriptLine] = []
        for try await event in stream {
            guard case .line(let line) = event else { continue }
            lines.append(
                try TranscriptLine(
                    speaker: line.speaker,
                    start: line.start + offset,
                    end: line.end + offset,
                    text: line.text
                )
            )
        }
        return lines
    }

    /// The states this walks through, in the order it walks them. Resuming means
    /// re-entering part-way along, so where the run wants a transition the
    /// session has already made there is nothing to do: asking the state machine
    /// for it again would be refused, and refusing a resumed run is what made a
    /// transient failure permanent.
    private static let pipeline: [SessionState] = [
        .recorded, .transcribing, .transcribed, .summarizing, .completed,
    ]

    /// A no-op where the session already stands at or beyond the state asked for.
    private func advancing(_ session: Session, to state: SessionState) async throws -> Session {
        guard
            let standing = Self.pipeline.firstIndex(of: session.state),
            let wanted = Self.pipeline.firstIndex(of: state),
            wanted > standing
        else { return session }

        // One step at a time, so a session resumed at recorded still passes
        // through every state on the way rather than jumping to the end.
        var moved = session
        for next in Self.pipeline[(standing + 1)...wanted] {
            moved = try moved.applying(Self.event(reaching: next))
        }
        try await sessions.save(moved)
        return moved
    }

    private static func event(reaching state: SessionState) -> SessionEvent {
        switch state {
        case .transcribing: .startTranscribing
        case .transcribed: .finishTranscribing
        case .summarizing: .startSummarizing
        default: .complete
        }
    }

    /// Every file has to belong to a segment the session knows about. One that
    /// does not is audio recovery should have adopted, and processing around it
    /// would lose it: the note would be written without it and the session
    /// closed, which is terminal.
    private func accountFor(
        _ files: [SegmentFile],
        against segments: [Segment],
        of sessionID: String
    ) throws {
        for file in files
        where !segments.contains(where: { $0.track == file.track && $0.index == file.index }) {
            throw UnaccountedAudio(id: sessionID, track: file.track, index: file.index)
        }
    }
}
