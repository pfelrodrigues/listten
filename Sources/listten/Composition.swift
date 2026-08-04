import Foundation
import ListtenCore

/// Where the ports meet the adapters. Kept apart from both, so the driver stays
/// testable against fakes and the menu stays ignorant of what is behind them.
enum Composition {
    static func recorder(root: URL, rotateEvery: TimeInterval = 45) -> SessionRecorder {
        SessionRecorder(
            sessions: FileSessionStore(root: root),
            progress: SessionProgressLogs(root: root),
            prompt: SilentPrompt(),
            clock: SystemTimeSource(),
            minimumDuration: 1,
            capture: { sessionID in
                SegmentedCapture(
                    sources: [.microphone: MicrophoneCapture(), .system: SystemAudioCapture()],
                    directory: root.appending(path: sessionID).appending(path: "audio"),
                    rotateEvery: rotateEvery
                )
            }
        )
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
