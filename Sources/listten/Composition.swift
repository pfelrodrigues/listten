import Foundation
import ListtenCore

/// Where the ports meet the adapters. Kept apart from both, so the driver stays
/// testable against fakes and the menu stays ignorant of what is behind them.
enum Composition {
    static func recorder(
        root: URL,
        notes: URL,
        rotateEvery: TimeInterval = 45,
        // The live transcript has to name a language before there is any audio
        // to work it out from, which is the one thing the note does not have to
        // do. So this is what the user said, or the Mac's own guess: wrong often
        // enough that the note detects instead, and cheap enough here that a
        // meeting in another language costs a live transcript rather than a
        // record of the meeting.
        language: String = ProcessInfo.processInfo.environment["LISTTEN_LANGUAGE"]
            ?? Locale.current.identifier(.bcp47)
    ) -> SessionRecorder {
        SessionRecorder(
            sessions: FileSessionStore(root: root),
            progress: SessionProgressLogs(root: root),
            prompt: SilentPrompt(),
            clock: SystemTimeSource(),
            minimumDuration: 1,
            capture: arming(root: root, rotateEvery: rotateEvery, language: language),
            process: processor(root: root, notes: notes)
        )
    }

    /// What a recording is made of, built the same way for the agent and for the
    /// command line. Kept in one place because `kill9` and `listten record` are
    /// how capture is checked, and checking a capture the product does not use
    /// proves nothing about the product.
    static func arming(
        root: URL,
        rotateEvery: TimeInterval = 45,
        language: String = ProcessInfo.processInfo.environment["LISTTEN_LANGUAGE"]
            ?? Locale.current.identifier(.bcp47)
    ) -> SessionRecorder.CaptureFactory {
        { sessionID in
            let audio = root.appending(path: sessionID).appending(path: "audio")
            let sources: [Track: any AudioSource] = [
                .microphone: MicrophoneCapture(), .system: SystemAudioCapture(),
            ]
            let backend = await SpeechLiveTranscription.installed()

            // No model for this language means no live transcript, and a
            // capture byte-identical to the one before it existed. The live
            // path is additive and switched off by absence.
            guard backend.capabilities.languages.contains(language) else {
                return ArmedRecording(
                    capture: SegmentedCapture(
                        sources: sources,
                        directory: audio,
                        rotateEvery: rotateEvery
                    )
                )
            }

            let sink = StreamingLiveAudioSink()
            return ArmedRecording(
                capture: SegmentedCapture(
                    sources: sources,
                    directory: audio,
                    rotateEvery: rotateEvery,
                    live: sink
                ),
                live: LiveTranscript(
                    audio: sink.stream,
                    sink: sink,
                    backend: backend,
                    writer: SessionLiveTranscripts(root: root),
                    sessionID: sessionID,
                    language: language
                )
            )
        }
    }

    /// Everything after the audio: transcribe each segment, correct, write the
    /// note, deliver it.
    ///
    /// Assembled per run rather than once, because a speech model installed
    /// after launch is then picked up, and this happens once per meeting.
    static func processor(root: URL, notes: URL) -> SessionRecorder.ProcessingFactory {
        { sessionID in
            let engine = await SpeechTranscription.installed()

            // Delivery never creates the destination, by design, so the folder
            // has to exist before the first note is written. Doing it here
            // rather than at launch also means a folder the user deleted is
            // back by the time they ask for the note again.
            try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)

            return try await ProcessSession(
                sessions: FileSessionStore(root: root),
                progress: SessionProgressLogs(root: root),
                audio: SegmentFiles(root: root),
                transcripts: FileTranscripts(root: root),
                transcriber: engine,
                notes: MarkdownNoteWriter(sessionsRoot: root, destination: notes),
                // Nothing loads a glossary yet, and correcting against an empty
                // one is the identity, so this loses nothing.
                glossary: Glossary(entries: []),
                // Worked out from the audio unless the user said otherwise. The
                // Mac's own language says nothing about the room: this one runs
                // its menus in English and holds its meetings in Portuguese.
                language: Self.language(from: engine.capabilities.languages),
                detector: await SpeechLanguageDetection.installed()
            )(sessionID: sessionID)
        }
    }

    /// `LISTTEN_LANGUAGE` overrules detection, which is worth having for a
    /// meeting held in a language the first minute does not reach and for
    /// anyone who would rather not pay for the detection at all.
    private static func language(from installed: Set<String>) -> LanguageChoice {
        guard let wanted = ProcessInfo.processInfo.environment["LISTTEN_LANGUAGE"] else {
            return .detected
        }
        // Held to the same rule as anything else asked for: a tag with no model
        // takes the nearest dialect rather than failing every segment. A tag
        // with nothing near it is passed through, so the failure names what the
        // user asked for rather than something this substituted.
        do {
            return .fixed(try ChooseLanguage(installed: installed)(preferring: wanted))
        } catch {
            return .fixed(wanted)
        }
    }
}

/// The notification with a Record button is #26. Until it exists, the click on
/// the menu is the answer, so there is nothing left to ask.
private struct SilentPrompt: RecordingPrompting {
    func askWhetherToRecord(sessionID: String) async throws {}
}

struct SystemTimeSource: TimeSource {
    var now: Date { Date() }
}
