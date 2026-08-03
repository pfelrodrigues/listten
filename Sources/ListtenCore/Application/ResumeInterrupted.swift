import Foundation

/// Runs at startup over the unfinished sessions, resolving the two states no
/// later step can and naming the step each one was interrupted inside. Recovery
/// is the normal path, not the exceptional one: a session left recording by a
/// crash keeps its closed segments, so it moves on as recorded rather than being
/// thrown away. It ends on the same terms a user pressing Stop would get, so how
/// the process died cannot change the verdict. An armed one is discarded
/// instead: its prompt did not survive the process, so nobody can answer it any
/// more, and nothing was recorded. Every other unfinished state is left for the
/// pipeline step that owns it, and reported only when a step was in flight.
///
/// What the progress log adds is which step to resume. A step whose intent has
/// no completion is one the process died inside, so it is named for redo; a step
/// with both ends is finished and must not run again.
public struct ResumeInterrupted: Sendable {
    /// What a recovery run found, reported rather than thrown. Throwing put the
    /// whole run on the floor for one damaged file, including sessions it was
    /// never going to touch, and nothing cleared the file, so every later run
    /// failed the same way. A loss is named beside the sessions that resolved.
    public struct Recovery: Sendable, Equatable {
        public let resumed: [Resumption]
        /// Sessions whose `session.json` could not be read.
        public let unreadableState: [String]
        /// Sessions whose `progress.jsonl` could not be read. Kept apart from
        /// the above because they are different files, and sending someone to
        /// the wrong one is the expensive part of a bad diagnosis.
        public let unreadableProgress: [String]
        /// Sessions whose audio directory could not be listed, so a file a
        /// crash orphaned there could not be looked for.
        public let unreadableAudio: [String]
        /// Logs that pair up wrong: a completion nobody intended describes work
        /// that cannot have happened, so the session must not be resumed from it.
        public let brokenProgress: [String: ProgressLedger.BrokenLog]

        public var isClean: Bool {
            unreadableState.isEmpty && unreadableProgress.isEmpty && unreadableAudio.isEmpty
                && brokenProgress.isEmpty
        }
    }

    /// A session recovery resolved, and the steps it has to redo before the
    /// pipeline takes it back.
    public struct Resumption: Sendable, Equatable {
        public let session: Session
        public let redo: [PipelineStep]
    }

    private let sessions: any SessionStoring
    private let progress: any ProgressLogging
    private let audio: any RecordedAudio
    private let minimumDuration: TimeInterval

    public init(
        sessions: any SessionStoring,
        progress: any ProgressLogging,
        audio: any RecordedAudio,
        minimumDuration: TimeInterval
    ) {
        self.sessions = sessions
        self.progress = progress
        self.audio = audio
        self.minimumDuration = minimumDuration
    }

    /// The file carries no start, since where a segment sits on the timeline
    /// was only ever written into the state. The best available answer is where
    /// the track's audio had reached, which under-reports if the crash fell
    /// inside a gap and never over-reports the session.
    private func adopting(orphans: [SegmentFile], into session: Session) throws -> Session {
        var grown = session
        for file in orphans.sorted(by: {
            ($0.index, $0.track.rawValue) < ($1.index, $1.track.rawValue)
        }) {
            let known = grown.segments.filter { $0.track == file.track }
            guard !known.contains(where: { $0.index == file.index }) else { continue }
            grown = try grown.appending(
                Segment(
                    index: file.index,
                    track: file.track,
                    start: known.map(\.end).max() ?? 0,
                    duration: file.duration
                )
            )
        }
        return grown
    }

    public func callAsFunction() async throws -> Recovery {
        let unfinished = try await sessions.unfinished()
        var resolved: [Resumption] = []
        var unreadableProgress: [String] = []
        var unreadableAudio: [String] = []
        var broken: [String: ProgressLedger.BrokenLog] = [:]

        for session in unfinished.sessions {
            // Which step to redo needs the log; moving a crashed recording to
            // recorded never did. So a log that cannot be read, or one that
            // pairs up wrong and must not be believed, costs the redo list and
            // not the meeting: the session is still resolved, with nothing to
            // redo, and the loss is named.
            var ledger = ProgressLedger.nothingKnown
            do {
                ledger = try ProgressLedger(await progress.checkpoints(for: session.id))
            } catch let failure as ProgressLedger.BrokenLog {
                broken[session.id] = failure
            } catch {
                unreadableProgress.append(session.id)
            }

            // A file the state does not name is audio a crash caught between
            // closing it and recording that it closed. It is adopted before the
            // state is resolved, so the duration the verdict is made against is
            // the audio that exists rather than the audio that was written down.
            var session = session
            do {
                session = try adopting(
                    orphans: await audio.segments(for: session.id),
                    into: session
                )
            } catch {
                unreadableAudio.append(session.id)
            }

            let outcome: Session?
            switch session.state {
            case .recording: outcome = try session.stopping(minimumDuration: minimumDuration)
            case .armed: outcome = try session.applying(.discard)
            default: outcome = nil
            }
            if let outcome {
                try await sessions.save(outcome)
            }

            // Nothing survives a session recovery ended, so a step it died
            // inside is work nobody will ever want rather than work to redo.
            let resumed = outcome ?? session
            let redo = resumed.state.isTerminal ? [] : ledger.interrupted
            guard outcome != nil || !redo.isEmpty else { continue }
            resolved.append(Resumption(session: resumed, redo: redo))
        }

        return Recovery(
            resumed: resolved,
            unreadableState: unfinished.unreadable.sorted(),
            unreadableProgress: unreadableProgress.sorted(),
            unreadableAudio: unreadableAudio.sorted(),
            brokenProgress: broken
        )
    }
}
