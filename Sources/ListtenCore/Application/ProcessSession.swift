import Foundation

/// Walks a recorded session to a written note.
///
/// Transcribe each segment, put the lines back where they belong on the session
/// clock, merge the tracks, correct, keep both transcripts, render, write.
///
/// Nothing here deletes audio, and nothing rewrites a segment. Every artefact
/// after the audio is reproducible from it, so a failure at any step leaves the
/// meeting recoverable by running this again.
///
/// There is no summary yet: #21 has the backend and until it exists a note
/// carries its transcript and says so, rather than carrying a port nothing
/// implements.
public struct ProcessSession: Sendable {
    public struct NotRecorded: Error, Equatable {
        public let id: String
        public let state: SessionState
    }

    public struct NoAudio: Error, Equatable {
        public let id: String
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
        guard recorded.state == .recorded else {
            throw NotRecorded(id: sessionID, state: recorded.state)
        }

        let files = try await audio.segments(for: sessionID)
        guard !files.isEmpty else { throw NoAudio(id: sessionID) }

        var session = try await advance(recorded, by: .startTranscribing)
        let transcript = try await transcribing(recorded.segments, from: files, of: sessionID)

        // Correction is derived and both survive, which is why this is one value
        // rather than a transcript that was overwritten in place.
        let corrected = try CorrectedTranscript(raw: transcript, glossary: glossary)
        try await transcripts.save(corrected, for: sessionID)

        session = try await advance(session, by: .finishTranscribing)
        session = try await advance(session, by: .startSummarizing)

        let note = MeetingNote(
            title: sessionID,
            summary: "",
            actionItems: [],
            transcript: corrected.corrected
        )
        let location = try await PerformStep(progress: progress)(.writingNote, of: sessionID) {
            try await notes.write(note, for: sessionID)
        }

        _ = try await advance(session, by: .complete)
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

    private func advance(_ session: Session, by event: SessionEvent) async throws -> Session {
        let moved = try session.applying(event)
        try await sessions.save(moved)
        return moved
    }
}
