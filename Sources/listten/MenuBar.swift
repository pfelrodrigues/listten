import AppKit
import Foundation
import ListtenCore

/// The menu bar agent.
///
/// The state has to be readable at a glance, because the failure this product
/// cannot afford is a meeting nobody recorded: "not recording" has to be
/// noticeable during a call, and "recording" has to carry enough to tell working
/// from wedged. So the title is the state and the first menu line spells it out.
@MainActor
final class MenuBar: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(
        withLength: NSStatusItem.variableLength
    )
    private let recorder: SessionRecorder
    private let sessionsRoot: URL
    private var ticker: Timer?

    /// Held here because NSMenuItem.target is weak and NSStatusItem does not
    /// own its builder: a MenuBar the caller let go of leaves a status item that
    /// still draws and no longer answers a click.
    private static var installed: MenuBar?

    init(root: URL, notes: URL) {
        sessionsRoot = root
        recorder = Composition.recorder(root: root, notes: notes)
        super.init()
    }

    func install() {
        Self.installed = self
        shown = .idle
        rebuild(for: .idle)

        // A second is enough to watch a recording grow and cheap enough to leave
        // running: the menu is the only place the state is visible.
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }

        // Quitting during a write-up leaves a meeting recorded and unwritten,
        // and nothing else ever looks at it. Offered rather than started: a
        // launch is not the moment to spend a minute transcribing without being
        // asked, and the menu now carries the meeting until somebody does.
        Task { @MainActor in
            await recorder.writeUpWhatIsUnwritten()
            await refresh()
        }
    }

    private var shown: SessionRecorder.State?
    /// Meetings whose note was never written. Read alongside the state because a
    /// write-up that failed while the next meeting was recording is not in the
    /// state at all, and a meeting nobody mentions again is a meeting lost.
    private var unwritten: [String: String] = [:]

    /// Rebuilt only when something changed. Replacing the menu every second is
    /// visible, and replacing it under a menu somebody has open is worse.
    private func refresh() async {
        let state = await recorder.current()
        let pending = await recorder.unwrittenNotes()
        let live = await recorder.liveOutcome()
        guard state != shown || pending != unwritten || live != lastLive else { return }
        shown = state
        unwritten = pending
        lastLive = live
        rebuild(for: state)
    }

    /// How the last live transcript went. Shown because the file it writes is
    /// the whole point of the feature and nothing else would say whether it
    /// worked: a meeting with a hole in its transcript looks exactly like a
    /// meeting nobody spoke in.
    private var lastLive: LiveTranscript.Outcome?

    private static func summary(of outcome: LiveTranscript.Outcome) -> String {
        if let failure = outcome.failure {
            return "Live transcript stopped: \(failure)"
        }
        var said = "Live transcript: \(outcome.lines) line(s)"
        if outcome.dropped > 0 { said += ", \(outcome.dropped) buffer(s) lost" }
        if outcome.endedEarly { said += ", ended early" }
        return said
    }

    private func rebuild(for state: SessionRecorder.State) {
        // A symbol rather than text: a menu bar with a notch hides what does not
        // fit, and "● 12:34" is wide enough to be the thing that gets hidden.
        // The detail lives one click away, where there is room for it.
        let symbol = Self.symbol(for: state)
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: Self.explanation(for: state)
        )
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "Listten — \(Self.explanation(for: state))"

        let menu = NSMenu()
        menu.addItem(Self.disabled(Self.explanation(for: state)))
        menu.addItem(.separator())

        // Recording is offered while the last session is still being written up:
        // transcription can be run again from the audio and the meeting starting
        // now cannot.
        switch state {
        case .idle, .finished, .failed, .processing, .processed, .processingFailed:
            menu.addItem(action("Start recording", #selector(startRecording)))
        case .recording:
            menu.addItem(action("Stop recording", #selector(stopRecording)))
        case .finishing:
            menu.addItem(Self.disabled("Finishing…"))
        }

        switch state {
        case .processed:
            menu.addItem(action("Open the note", #selector(openNote)))
        case .processingFailed:
            menu.addItem(action("Write the note again", #selector(processAgain)))
        default:
            break
        }
        // Every meeting still without a note, whatever the recorder is doing
        // now. The one in the state above is already offered, so it is not
        // offered twice.
        for id in unwritten.keys.sorted() where id != Self.session(of: state) {
            menu.addItem(action("Write the note for \(id)", #selector(processPending)))
        }
        if Self.session(of: state) != nil {
            menu.addItem(action("Open this session", #selector(openSession)))
        }
        if let lastLive {
            menu.addItem(Self.disabled(Self.summary(of: lastLive)))
        }
        menu.addItem(action("Open sessions folder", #selector(openSessionsFolder)))
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Listten",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusItem.menu = menu
    }

    /// Filled means recording, which is the one distinction that has to survive
    /// a glance. The elapsed time is what says audio is still arriving rather
    /// than merely switched on, so it is the first line of the menu.
    private static func symbol(for state: SessionRecorder.State) -> String {
        switch state {
        case .idle: return "waveform"
        case .recording: return "waveform.circle.fill"
        case .finishing: return "hourglass"
        case .processing: return "ellipsis.circle"
        case .processed: return "doc.text"
        case .finished: return "checkmark.circle"
        case .failed, .processingFailed: return "exclamationmark.triangle"
        }
    }

    /// The session a state is about, where it is about one. Both "open this
    /// session" and the retry need it, and a state that has none is exactly a
    /// state neither belongs on.
    private static func session(of state: SessionRecorder.State) -> String? {
        switch state {
        case .processing(let id), .processed(let id, _), .processingFailed(let id, _):
            return id
        case .finished(let id, _, _):
            return id
        case .idle, .recording, .finishing, .failed:
            return nil
        }
    }

    private static func explanation(for state: SessionRecorder.State) -> String {
        switch state {
        case .idle:
            return "Not recording"
        case .recording(let segments, let seconds):
            return "Recording — \(clock(seconds)) in \(segments) segment(s)"
        case .finishing:
            return "Finishing the last segment"
        case .processing:
            return "Writing up the last recording"
        case .processed(_, let note):
            return "Note ready: \(note.lastPathComponent)"
        case .finished(_, let outcome, let seconds):
            return "Last session \(outcome.rawValue), \(clock(seconds))"
        case .failed(let reason), .processingFailed(_, let reason):
            return reason
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func startRecording() {
        Task { @MainActor in
            await recorder.start()
            await refresh()
        }
    }

    @objc private func stopRecording() {
        Task { @MainActor in
            await recorder.stop()
            await refresh()
        }
    }

    @objc private func openSession() {
        guard let shown, let id = Self.session(of: shown) else { return }
        NSWorkspace.shared.open(sessionsRoot.appending(path: id))
    }

    @objc private func openNote() {
        guard case .processed(_, let note) = shown else { return }
        NSWorkspace.shared.open(note)
    }

    /// The pipeline reruns a session from its audio, so the retry is this and
    /// nothing else.
    @objc private func processAgain() {
        guard case .processingFailed(let id, _) = shown else { return }
        Task { @MainActor in
            await recorder.process(id: id)
            await refresh()
        }
    }

    /// Which meeting a stale menu item names cannot be read off the state, so it
    /// is read off the item that was clicked.
    @objc private func processPending(_ sender: NSMenuItem) {
        let id = sender.title.replacingOccurrences(of: "Write the note for ", with: "")
        guard unwritten[id] != nil else { return }
        Task { @MainActor in
            await recorder.process(id: id)
            await refresh()
        }
    }

    @objc private func openSessionsFolder() {
        // Nothing has recorded yet on a first run, so the folder may not exist.
        // A failure to make it is worth saying rather than swallowing.
        do {
            try FileManager.default.createDirectory(
                at: sessionsRoot,
                withIntermediateDirectories: true
            )
        } catch {
            rebuild(for: .failed("Cannot open \(sessionsRoot.path): \(error)"))
            return
        }
        NSWorkspace.shared.open(sessionsRoot)
    }
}
