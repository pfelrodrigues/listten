import Foundation
import Synchronization

/// A live sink that hands its audio to one consumer through an `AsyncStream`.
///
/// Nothing here allocates a lock or awaits: the writer task calls `hand` between
/// two disk writes, so the only thing it may do is enqueue and return. What the
/// consumer never saw is counted rather than waited for, since growing memory to
/// keep up with a stalled reader is how a recording runs a machine out of room.
public final class StreamingLiveAudioSink: LiveAudioSink {
    /// About five seconds of one track at the buffers the devices deliver,
    /// roughly a megabyte of PCM: enough slack for a consumer that runs long,
    /// too little for a stalled one to grow.
    public static let defaultCapacity = 64

    /// Single consumer, made once at init. Draining it twice drops buffers on
    /// the floor, which is why it is not on the port.
    public let stream: AsyncStream<LiveAudio>

    private let continuation: AsyncStream<LiveAudio>.Continuation
    private let droppedCount = Atomic<Int>(0)
    private let handedAfterFinish = Atomic<Bool>(false)

    /// The oldest buffer goes first when the consumer falls behind, so what it
    /// reads stays close to now. Keeping the oldest instead would leave a live
    /// transcript falling further behind the meeting for the rest of it.
    public init(capacity: Int = defaultCapacity) {
        precondition(capacity > 0)
        (stream, continuation) = AsyncStream<LiveAudio>
            .makeStream(
                bufferingPolicy: .bufferingNewest(capacity)
            )
    }

    public func hand(_ live: LiveAudio) {
        switch continuation.yield(live) {
        case .dropped:
            droppedCount.wrappingAdd(1, ordering: .relaxed)
        case .terminated:
            handedAfterFinish.store(true, ordering: .relaxed)
        default:
            break
        }
    }

    public func finish() {
        continuation.finish()
    }

    public var dropped: Int { droppedCount.load(ordering: .relaxed) }

    public var endedEarly: Bool { handedAfterFinish.load(ordering: .relaxed) }
}
