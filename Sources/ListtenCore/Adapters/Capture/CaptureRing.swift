import Foundation
import Synchronization

/// Hand-off from the audio callback to the rest of the process.
///
/// The callback may not allocate, take a lock or wait, so it copies into a slot
/// that already exists and moves one index. Everything that allocates happens on
/// the reading side. When the reader falls behind, audio is dropped and counted:
/// growing memory from a thread that cannot allocate is not on offer.
///
/// One producer, one consumer. The audio thread only ever advances `writeIndex`,
/// the drain only ever advances `readIndex`, which is what makes the unchecked
/// conformance below true rather than hopeful.
final class CaptureRing: @unchecked Sendable {
    private struct Header {
        var hostTime: TimeInterval = 0
        var sampleRate: Double = 0
        var frames: Int = 0
    }

    private let slots: Int
    private let framesPerSlot: Int
    private let slab: UnsafeMutablePointer<Float>
    private let headers: UnsafeMutablePointer<Header>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let droppedCount = Atomic<Int>(0)

    init(slots: Int, framesPerSlot: Int) {
        precondition(slots > 0, "a ring with no slots can hold nothing")
        precondition(framesPerSlot > 0, "a slot with no frames can hold nothing")
        self.slots = slots
        self.framesPerSlot = framesPerSlot
        slab = .allocate(capacity: slots * framesPerSlot)
        slab.initialize(repeating: 0, count: slots * framesPerSlot)
        headers = .allocate(capacity: slots)
        headers.initialize(repeating: Header(), count: slots)
    }

    deinit {
        slab.deinitialize(count: slots * framesPerSlot)
        slab.deallocate()
        headers.deinitialize(count: slots)
        headers.deallocate()
    }

    /// Buffers the reader never saw. Silence here would look identical to a
    /// quiet meeting.
    var dropped: Int { droppedCount.load(ordering: .relaxed) }

    /// Called on the audio thread. Allocates nothing, waits for nothing.
    func write(
        samples: UnsafePointer<Float>,
        frames: Int,
        hostTime: TimeInterval,
        sampleRate: Double
    ) -> Bool {
        guard frames > 0, frames <= framesPerSlot else {
            droppedCount.wrappingAdd(1, ordering: .relaxed)
            return false
        }

        let write = writeIndex.load(ordering: .relaxed)
        guard write - readIndex.load(ordering: .acquiring) < slots else {
            droppedCount.wrappingAdd(1, ordering: .relaxed)
            return false
        }

        let slot = write % slots
        slab.advanced(by: slot * framesPerSlot).update(from: samples, count: frames)
        headers[slot] = Header(hostTime: hostTime, sampleRate: sampleRate, frames: frames)
        writeIndex.store(write + 1, ordering: .releasing)
        return true
    }

    /// Called off the audio thread, which is where allocating is allowed.
    func read() -> CapturedAudio? {
        let read = readIndex.load(ordering: .relaxed)
        guard read < writeIndex.load(ordering: .acquiring) else { return nil }

        let slot = read % slots
        let header = headers[slot]
        let audio = CapturedAudio(
            hostTime: header.hostTime,
            sampleRate: header.sampleRate,
            samples: Array(
                UnsafeBufferPointer(
                    start: slab.advanced(by: slot * framesPerSlot),
                    count: header.frames
                )
            )
        )
        readIndex.store(read + 1, ordering: .releasing)
        return audio
    }
}
