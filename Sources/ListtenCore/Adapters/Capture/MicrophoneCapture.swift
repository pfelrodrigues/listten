import AVFoundation
import Foundation

/// Microphone input, delivered as buffers stamped on the machine clock.
///
/// The stamp is the host time AVFoundation reports for the buffer, not the
/// instant this process happened to see it, so the microphone and the system
/// tap describe the same conversation on one timeline.
public actor MicrophoneCapture {
    public struct AlreadyRunning: Error, Equatable {}

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<CapturedAudio>.Continuation?
    private var configurationObserver: (any NSObjectProtocol)?

    public init() {}

    public func start() throws -> AsyncStream<CapturedAudio> {
        guard continuation == nil else { throw AlreadyRunning() }

        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        self.continuation = continuation

        installTap()
        observeConfigurationChanges()

        engine.prepare()
        do {
            try engine.start()
        } catch {
            tearDown()
            throw error
        }
        return stream
    }

    public func stop() {
        guard continuation != nil else { return }
        tearDown()
    }

    /// The engine reports a configuration change when the input device is
    /// swapped. The tap is bound to the old format, so both it and the engine
    /// have to be brought back up; the stream and its timestamps continue,
    /// which is what keeps the two tracks aligned across the gap.
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
        guard continuation != nil else { return }

        engine.inputNode.removeTap(onBus: 0)
        installTap()

        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // The device went away for good. Ending the stream tells the caller
            // to finalize what it has rather than wait for audio that is not
            // coming.
            continuation?.finish()
            tearDown()
        }
    }

    private func installTap() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let continuation = continuation

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            continuation?
                .yield(
                    CapturedAudio(
                        hostTime: AVAudioTime.seconds(forHostTime: time.hostTime),
                        sampleRate: format.sampleRate,
                        samples: samples
                    )
                )
        }
    }

    private func tearDown() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        continuation?.finish()
        continuation = nil
    }
}
