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
        case "record":
            let rest = Array(args.dropFirst())
            await Recording.run(
                seconds: rest.first.flatMap(Double.init) ?? 60,
                root: rest.dropFirst().first.map { URL(filePath: $0) } ?? Self.defaultRoot,
                // Overridable so a short check does not need to run 45 seconds
                // before it has anything to show.
                rotateEvery: rest.dropFirst(2).first.flatMap(Double.init) ?? 45
            )
        case "resume":
            await Recording.resume(
                root: args.dropFirst().first.map { URL(filePath: $0) } ?? Self.defaultRoot
            )
        case "capture":
            let rest = Array(args.dropFirst())
            await captureFromMicrophone(
                seconds: rest.first.flatMap(Double.init) ?? 5,
                writingTo: rest.dropFirst().first.map { URL(filePath: $0) }
            )
        case "tap":
            let rest = Array(args.dropFirst())
            captureFromSystem(seconds: rest.first.flatMap(Double.init) ?? 5)
        default:
            FileHandle.standardError.write(Data("unknown command: \(args[0])\n".utf8))
            exit(64)
        }
    }

    /// Runs the real microphone against the real clock and reports what turned
    /// up. Unplug a headset while it runs: the gap it prints is the device
    /// change, and the session continuing past it is the point.
    private static func captureFromMicrophone(seconds: Double, writingTo directory: URL?) async {
        guard let directory else {
            await reportBuffers(seconds: seconds)
            return
        }
        await writeSegments(seconds: seconds, to: directory)
    }

    /// Records to numbered files and prints them as they close, so a `kill -9`
    /// part-way through can be checked against what it claimed was already safe.
    private static func writeSegments(seconds: Double, to directory: URL) async {
        let capture = SegmentedCapture(
            sources: [.microphone: MicrophoneCapture()],
            directory: directory,
            rotateEvery: 5
        )
        let stream: AsyncStream<Segment>
        do {
            stream = try await capture.start()
        } catch {
            FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
            exit(1)
        }

        print("Recording \(seconds)s into \(directory.path), 5s segments.")
        // The stopper owns the result: stopping is what ends the stream, so
        // asking again afterwards would answer with nothing and hide both the
        // last segment and any write that failed.
        let stopper = Task {
            try await Task.sleep(for: .seconds(seconds))
            return try await capture.stop()
        }

        for await segment in stream {
            print(
                "closed \(capture.url(for: segment.track, index: segment.index).lastPathComponent)"
                    + " \(String(format: "%.2f", segment.duration))s"
            )
        }

        do {
            for partial in try await stopper.value {
                print(
                    "final  \(capture.url(for: partial.track, index: partial.index).lastPathComponent)"
                        + " \(String(format: "%.2f", partial.duration))s"
                )
            }
        } catch {
            FileHandle.standardError.write(Data("stopping reported: \(error)\n".utf8))
            exit(1)
        }
    }

    /// The system track on its own, which is what the process tap is for: play
    /// something while it runs, and the peak level is the whole verdict. Unlike
    /// the microphone, a tap delivers buffers through silence, so no buffers at
    /// all means the tap is not running rather than that the room is quiet.
    ///
    /// Run inside a running application rather than as a plain command, because
    /// the first tap on a machine blocks until the user has answered the audio
    /// capture prompt, and the system has nowhere to show that prompt to a
    /// process with no application behind it: measured, the request simply never
    /// returns. The agent this ships as has one, so this is what the product
    /// does rather than a concession to testing.
    @MainActor
    private static func captureFromSystem(seconds: Double) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        Task.detached {
            let tap = SystemAudioCapture()
            print(
                "Tapping system audio for \(seconds)s. Play something. "
                    + "Grant access if macOS asks."
            )
            await reportBuffers(
                seconds: seconds,
                track: .system,
                source: tap,
                dropped: { await tap.droppedBuffers },
                restarts: { await tap.restarts }
            )
            exit(0)
        }

        app.run()
        exit(0)
    }

    private static func reportBuffers(seconds: Double) async {
        let microphone = MicrophoneCapture()
        print("Capturing for \(seconds)s. Grant microphone access if macOS asks.")
        await reportBuffers(
            seconds: seconds,
            track: .microphone,
            source: microphone,
            dropped: { await microphone.droppedBuffers },
            restarts: { await microphone.restarts }
        )
    }

    private static func reportBuffers(
        seconds: Double,
        track: Track,
        source: some AudioSource,
        dropped: @Sendable () async -> Int,
        restarts: @Sendable () async -> Int
    ) async {
        let stream: AsyncStream<CapturedAudio>
        do {
            stream = try await source.start()
        } catch {
            FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
            exit(1)
        }

        let stopper = Task {
            try await Task.sleep(for: .seconds(seconds))
            await source.stop()
        }

        let began = Date()
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
                        track: track,
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

        report(
            segments: segments,
            sampleRate: rate,
            peak: loudest,
            dropped: await dropped(),
            restarts: await restarts(),
            // Measured, not inferred: silence at the end is a quiet moment, and
            // a stream that stopped before its time is a lost recording.
            cutShortBy: seconds - Date().timeIntervalSince(began)
        )
    }

    private static func report(
        segments: [Segment],
        sampleRate: Double,
        peak: Float,
        dropped: Int,
        restarts: Int,
        cutShortBy: Double
    ) {
        guard let last = segments.last else {
            // The counters are the whole diagnosis when nothing arrived: a
            // watchdog that kept restarting says the device is there and mute.
            _ = cutShortBy
            print("No audio arrived, after \(restarts) restart(s) and \(dropped) drop(s).")
            print("Check that an input device is selected and that access is granted.")
            exit(1)
        }

        let audioSeconds = segments.reduce(0) { $0 + $1.duration }
        print("Buffers:      \(segments.count)")
        print("Sample rate:  \(Int(sampleRate)) Hz")
        print("Audio:        \(String(format: "%.2f", audioSeconds))s")
        print("Timeline:     \(String(format: "%.2f", last.end))s")
        print("Peak level:   \(String(format: "%.4f", peak))")

        let silences = zip(segments, segments.dropFirst())
            .map { ($0.end, $1.start) }
            .filter { $1 - $0 > 0.05 }
        let gaps = silences.map { String(format: "%.2fs–%.2fs", $0, $1) }
        print("Gaps:         \(gaps.isEmpty ? "none" : gaps.joined(separator: ", "))")
        print("Dropped:      \(dropped) buffer(s)")
        print("Restarts:     \(restarts)")

        if cutShortBy > 0.5 {
            print(
                "Ended early: the capture stopped "
                    + String(format: "%.1f", cutShortBy) + "s before it was asked to."
            )
        }

        if dropped > 0 {
            print("Audio was lost: the drain could not keep up with the device.")
        }
        if peak == 0 {
            print("Silence throughout: the device is connected but nothing is reaching it.")
        }
        // The symptom of a rate that is declared but not delivered: buffers
        // arriving steadily and an hour of meeting written into half an hour of
        // file. It plays back fast and slides away from the other track, which
        // no listener would call a recording.
        //
        // Measured against the span the buffers actually cover rather than the
        // whole timeline, so a device swap in the middle does not excuse a rate
        // that is wrong: the two failures are separate and a capture can have
        // both, which is exactly when a diagnosis is worth having.
        let covered = last.end - silences.reduce(0) { $0 + ($1.1 - $1.0) }
        if covered > 0, audioSeconds < covered * 0.9 {
            print(
                "The audio is shorter than the span it covers: "
                    + String(format: "%.2f", audioSeconds) + "s of samples over "
                    + String(format: "%.2f", covered)
                    + "s of recording. The device is not running at the rate it reports."
            )
        }
    }

    @MainActor
    private static func runAgent() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let bar = MenuBar(root: Self.defaultRoot)
        bar.install()

        app.run()
        exit(0)
    }

    /// ~/Library/Application Support/listten/sessions, the layout the design
    /// describes and the one a bundled agent will use.
    static var defaultRoot: URL {
        URL.applicationSupportDirectory
            .appending(path: "listten")
            .appending(path: "sessions")
    }

    private static func printUsage() {
        print(
            """
            listten \(Listten.version)

            Usage:
              listten                    run the menu bar agent
              listten record [seconds] [root] [rotation]
                                         record a session: state, checkpoints
                                         and audio, under the sessions root
              listten resume [root]      resolve whatever a previous run left
                                         open, the way a launch would
              listten capture [seconds] [directory]
                                         raw microphone check, no session
              listten tap [seconds]      raw system audio check, no session

            Options:
              -v, --version   print the version
              -h, --help      print this help
            """
        )
    }
}
