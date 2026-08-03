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
    private let recorder: RecordingSession
    private let sessionsRoot: URL
    private var ticker: Timer?

    /// Held here because NSMenuItem.target is weak and NSStatusItem does not
    /// own its builder: a MenuBar the caller let go of leaves a status item that
    /// still draws and no longer answers a click.
    private static var installed: MenuBar?

    init(root: URL) {
        sessionsRoot = root
        recorder = RecordingSession(root: root)
        super.init()
    }

    func install() {
        Self.installed = self
        rebuild(for: .idle)

        // A second is enough to watch a recording grow and cheap enough to leave
        // running: the menu is the only place the state is visible.
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func refresh() async {
        rebuild(for: await recorder.current())
    }

    private func rebuild(for state: RecordingSession.State) {
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

        switch state {
        case .idle, .finished, .failed:
            menu.addItem(action("Start recording", #selector(startRecording)))
        case .recording:
            menu.addItem(action("Stop recording", #selector(stopRecording)))
        case .finishing:
            menu.addItem(Self.disabled("Finishing…"))
        }

        if case .finished = state {
            menu.addItem(action("Open this session", #selector(openSession)))
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
    private static func symbol(for state: RecordingSession.State) -> String {
        switch state {
        case .idle: return "waveform"
        case .recording: return "waveform.circle.fill"
        case .finishing: return "hourglass"
        case .finished: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private static func explanation(for state: RecordingSession.State) -> String {
        switch state {
        case .idle:
            return "Not recording"
        case .recording(let segments, let seconds):
            return "Recording — \(clock(seconds)) in \(segments) segment(s)"
        case .finishing:
            return "Finishing the last segment"
        case .finished(_, let outcome, let seconds):
            return "Last session \(outcome), \(clock(seconds))"
        case .failed(let reason):
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
        Task { @MainActor in
            guard let directory = await recorder.directory() else { return }
            NSWorkspace.shared.open(directory)
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
