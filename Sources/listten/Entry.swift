import AppKit
import Foundation
import ListtenCore

// One binary, two modes: no arguments runs the menu bar agent, arguments run the CLI.
@main
enum Entry {
    @MainActor
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())

        switch args.first {
        case nil:
            runAgent()
        case "--version", "-v":
            print(Listten.version)
        case "--help", "-h":
            printUsage()
        case "capture":
            await captureFromMicrophone(seconds: args.dropFirst().first.flatMap(Double.init) ?? 5)
        default:
            FileHandle.standardError.write(Data("unknown command: \(args[0])\n".utf8))
            exit(64)
        }
    }

    /// Runs the real microphone against the real clock and reports what turned
    /// up. Unplug a headset while it runs: the gap it prints is the device
    /// change, and the session continuing past it is the point.
    private static func captureFromMicrophone(seconds: Double) async {
        let microphone = MicrophoneCapture()
        let stream: AsyncStream<CapturedAudio>
        do {
            stream = try await microphone.start()
        } catch {
            FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
            exit(1)
        }

        print("Capturing for \(seconds)s. Grant microphone access if macOS asks.")
        let stopper = Task {
            try? await Task.sleep(for: .seconds(seconds))
            await microphone.stop()
        }

        var timeline: CaptureTimeline?
        var segments: [Segment] = []
        var loudest: Float = 0
        var rate = 0.0
        for await audio in stream {
            let anchor = timeline ?? CaptureTimeline(anchor: audio.hostTime)
            timeline = anchor
            do {
                segments.append(
                    try anchor.segment(
                        index: segments.count,
                        track: .microphone,
                        hostTime: audio.hostTime,
                        frames: audio.frames,
                        sampleRate: audio.sampleRate
                    )
                )
            } catch {
                FileHandle.standardError.write(Data("unusable buffer: \(error)\n".utf8))
            }
            if audio.peak > loudest { loudest = audio.peak }
            rate = audio.sampleRate
        }
        stopper.cancel()

        report(segments: segments, sampleRate: rate, peak: loudest)
    }

    private static func report(segments: [Segment], sampleRate: Double, peak: Float) {
        guard let last = segments.last else {
            print("No audio arrived. Check that an input device is selected and permitted.")
            exit(1)
        }

        let audioSeconds = segments.reduce(0) { $0 + $1.duration }
        print("Buffers:      \(segments.count)")
        print("Sample rate:  \(Int(sampleRate)) Hz")
        print("Audio:        \(String(format: "%.2f", audioSeconds))s")
        print("Timeline:     \(String(format: "%.2f", last.end))s")
        print("Peak level:   \(String(format: "%.4f", peak))")

        let gaps = zip(segments, segments.dropFirst())
            .filter { $1.start - $0.end > 0.05 }
            .map { String(format: "%.2fs–%.2fs", $0.end, $1.start) }
        print("Gaps:         \(gaps.isEmpty ? "none" : gaps.joined(separator: ", "))")

        if peak == 0 {
            print("Silence throughout: the device is connected but nothing is reaching it.")
        }
    }

    @MainActor
    private static func runAgent() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "L"

        let menu = NSMenu()
        menu.addItem(withTitle: "Listten \(Listten.version)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusItem.menu = menu

        app.run()
        exit(0)
    }

    private static func printUsage() {
        print(
            """
            listten \(Listten.version)

            Usage:
              listten                    run the menu bar agent
              listten capture [seconds]  record from the microphone and report
                                         what arrived, for checking a device

            Options:
              -v, --version   print the version
              -h, --help      print this help
            """
        )
    }
}
