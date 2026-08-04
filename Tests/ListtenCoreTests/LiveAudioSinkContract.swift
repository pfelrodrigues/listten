import Foundation
import Testing

@testable import ListtenCore

/// One buffer, stamped so a test can tell it from its neighbours.
func liveBuffer(at start: TimeInterval, of track: Track = .microphone) -> LiveAudio {
    LiveAudio(
        track: track,
        audio: CapturedAudio(
            hostTime: 1000 + start,
            sampleRate: 16000,
            samples: Array(repeating: Float(start), count: 4)
        ),
        start: start
    )
}

/// The rules every `LiveAudioSink` obeys, written once so a fake cannot be tidier
/// than the one production hands the recording to. `readBack` is how this
/// implementation is asked what its consumer saw, since a stream and an array
/// are not read the same way.
func verifyLiveAudioSinkContract<Sink: LiveAudioSink>(
    _ make: @Sendable () -> Sink,
    readBack: @Sendable (Sink) async -> [LiveAudio],
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let handed = (0..<8)
        .map {
            liveBuffer(at: Double($0), of: $0.isMultiple(of: 2) ? .microphone : .system)
        }

    let kept = make()
    for buffer in handed {
        kept.hand(buffer)
    }
    kept.finish()
    let delivered = await readBack(kept)

    #expect(
        delivered == handed,
        "what was handed over came back changed, reordered, or on another track",
        sourceLocation: sourceLocation
    )
    #expect(kept.dropped == 0, "a sink that kept up counted a drop", sourceLocation: sourceLocation)
    #expect(
        !kept.endedEarly,
        "a sink nobody handed to after finishing said it ended early",
        sourceLocation: sourceLocation
    )

    // Nothing is read until after the sink is finished, so anything with a bound
    // has to reach it. Whichever end of the queue it drops, everything handed
    // over is either delivered or counted: audio that vanishes silently reads as
    // a quiet meeting, which is the failure this seam exists to close.
    let flooded = make()
    let many = (0..<512).map { liveBuffer(at: Double($0)) }
    for buffer in many {
        flooded.hand(buffer)
    }
    flooded.finish()
    let arrived = await readBack(flooded)

    #expect(
        arrived.count + flooded.dropped == many.count,
        "\(many.count - arrived.count - flooded.dropped) buffers went missing uncounted",
        sourceLocation: sourceLocation
    )
    #expect(
        arrived.map(\.start) == arrived.map(\.start).sorted(),
        "an overflowing sink delivered buffers out of order",
        sourceLocation: sourceLocation
    )

    let closed = make()
    closed.hand(handed[0])
    closed.finish()
    closed.hand(handed[1])
    let afterFinish = await readBack(closed)

    #expect(
        afterFinish == [handed[0]],
        "a buffer handed over after finishing was delivered anyway",
        sourceLocation: sourceLocation
    )
    #expect(
        closed.endedEarly,
        "a sink handed audio after finishing did not say the transcript stops short",
        sourceLocation: sourceLocation
    )
    #expect(
        closed.dropped == 0,
        "the end of input was counted as audio the consumer fell behind on",
        sourceLocation: sourceLocation
    )
}

@Test("the in-memory sink honours the contract")
func inMemoryLiveSinkHonoursTheContract() async {
    await verifyLiveAudioSinkContract({ InMemoryLiveAudioSink() }, readBack: { $0.received })
}

/// The one production hands the recording to, held to the same rules. Its stream
/// is drained after it is finished, which is the only order a single-consumer
/// stream can be read in from here.
@Test("the streaming sink honours the same contract as the fake")
func streamingLiveSinkHonoursTheContract() async {
    await verifyLiveAudioSinkContract({ StreamingLiveAudioSink() }) { sink in
        var received: [LiveAudio] = []
        for await audio in sink.stream {
            received.append(audio)
        }
        return received
    }
}

/// A capacity of zero would drop every buffer and report a meeting that never
/// happened, which reads as a quiet room rather than as a broken sink.
@Test("a sink with nowhere to put a buffer is refused")
func aSinkWithNoCapacityIsRefused() async {
    await #expect(processExitsWith: .failure) {
        _ = StreamingLiveAudioSink(capacity: 0)
    }
}
