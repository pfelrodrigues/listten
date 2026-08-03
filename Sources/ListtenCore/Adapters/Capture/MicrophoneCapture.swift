import AVFoundation
import Foundation

/// Microphone input, delivered as buffers stamped on the machine clock.
///
/// The stamp is the host time AVFoundation reports for the buffer, not the
/// instant this process happened to see it, so the microphone and the system
/// tap describe the same conversation on one timeline.
public actor MicrophoneCapture: AudioSource {
    /// Sized so the drain can fall behind for over a second before anything is
    /// lost, at about 1 MB. The device may hand over more frames than the tap
    /// asked for, so a slot is several times the requested buffer.
    private static let slots = 16
    private static let framesPerSlot = 16384

    /// A device may take a moment to start; once it is running, silence this
    /// long means something is wrong rather than quiet.
    private static let firstBufferGrace: TimeInterval = 3
    private static let silenceTolerance: TimeInterval = 2
    private static let watchInterval = Duration.milliseconds(500)
    private static let maxRestarts = 5

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<CapturedAudio>.Continuation?
    private var configurationObserver: (any NSObjectProtocol)?
    private var ring: CaptureRing?
    private var drain: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var restartCount = 0

    public init() {}

    /// Buffers the audio thread had to throw away because the drain fell
    /// behind. Non-zero means audio is missing from the recording. It survives
    /// stopping, since the caller only asks once the stream has ended.
    public var droppedBuffers: Int { ring?.dropped ?? droppedWhileRunning }
    private var droppedWhileRunning = 0

    /// How many times the watchdog had to bring the device back. Non-zero means
    /// the recording has gaps that were recovered rather than lost.
    public var restarts: Int { restartCount }

    public func start() throws -> AsyncStream<CapturedAudio> {
        guard continuation == nil else { throw CaptureAlreadyStarted() }

        let ring = CaptureRing(slots: Self.slots, framesPerSlot: Self.framesPerSlot)
        self.ring = ring

        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        self.continuation = continuation

        installTap(into: ring)
        observeConfigurationChanges()

        engine.prepare()
        do {
            try engine.start()
        } catch {
            tearDown()
            throw error
        }

        drain = Task.detached(priority: .userInitiated) {
            await Self.drain(ring, into: continuation)
        }
        watchdog = Task { [weak self] in await self?.watch(ring) }
        return stream
    }

    public func stop() {
        guard continuation != nil else { return }
        tearDown()
    }

    /// The engine reports a configuration change when the input device is
    /// swapped. The tap is bound to the old format, so both it and the engine
    /// have to be brought back up; the ring and its timestamps carry on, which
    /// is what keeps the two tracks aligned across the gap.
    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.restartAfterConfigurationChange() }
        }
    }

    private func restartAfterConfigurationChange() {
        restartCapture(countingIt: false)
    }

    /// Watches for the failure the whole design exists to avoid: a session that
    /// believes it is recording while nothing arrives. A configuration change
    /// announces itself; an engine that wedges or a device that vanishes without
    /// one does not, and only the buffer count gives it away.
    private func watch(_ ring: CaptureRing) async {
        var detector = StallDetector(
            startedAt: Self.now(),
            grace: Self.firstBufferGrace,
            tolerance: Self.silenceTolerance
        )
        var seen = 0

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.watchInterval)
            } catch {
                return
            }
            guard self.ring === ring else { return }

            let delivered = ring.delivered
            if delivered > seen {
                seen = delivered
                detector.received(at: Self.now())
            }

            guard detector.verdict(at: Self.now()) == .stalled else { continue }

            // Restarting forever would hide a device that is never coming back.
            // Ending the stream tells the caller to finalize what it has, which
            // is the same answer a device that vanishes for good already gets.
            guard restartCount < Self.maxRestarts else {
                tearDown()
                return
            }
            restartCapture(countingIt: true)
        }
    }

    /// Rebuilding the tap and the engine leaves the ring and its timestamps
    /// alone, so the silence shows up as a gap on the timeline instead of
    /// shifting everything that follows.
    private func restartCapture(countingIt counted: Bool) {
        guard let ring, continuation != nil else { return }
        if counted { restartCount += 1 }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        installTap(into: ring)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // The device went away for good. Tearing down ends the stream, which
            // tells the caller to finalize what it has rather than wait for
            // audio that is not coming.
            tearDown()
        }
    }

    private static func now() -> TimeInterval {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    /// Everything inside the tap block runs on the audio thread, where
    /// allocating, locking or waiting would cost recorded audio. It copies into
    /// a slot that already exists and returns.
    /// A device caught mid-swap reports a format that nothing can be tapped
    /// with, and AVFoundation answers that with an Objective-C exception, which
    /// Swift cannot catch and which takes the recording down with the process.
    /// Skipping leaves the watchdog to try again a moment later.
    private func installTap(into ring: CaptureRing) {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        // Passing nil means the node's own format, so there is no second
        // opinion to disagree with; the rate then comes from each buffer, which
        // is also what makes a device returning at another rate survivable.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, time in
            guard let channel = buffer.floatChannelData?[0] else { return }
            _ = ring.write(
                samples: channel,
                frames: Int(buffer.frameLength),
                hostTime: AVAudioTime.seconds(forHostTime: time.hostTime),
                sampleRate: buffer.format.sampleRate
            )
        }
    }

    /// Off the audio thread, so this is where buffers become Swift values. On
    /// cancellation it flushes what the ring still holds before finishing, so
    /// stopping does not cost the last fraction of a second.
    private static func drain(
        _ ring: CaptureRing,
        into continuation: AsyncStream<CapturedAudio>.Continuation
    ) async {
        while !Task.isCancelled {
            var moved = false
            while let audio = ring.read() {
                continuation.yield(audio)
                moved = true
            }
            guard !moved else { continue }
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                break
            }
        }

        while let audio = ring.read() {
            continuation.yield(audio)
        }
        continuation.finish()
    }

    private func tearDown() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        watchdog?.cancel()
        watchdog = nil

        if let drain {
            // The drain flushes the ring and finishes the stream on its way out.
            drain.cancel()
        } else {
            continuation?.finish()
        }
        drain = nil
        continuation = nil
        droppedWhileRunning = ring?.dropped ?? droppedWhileRunning
        ring = nil
    }
}
