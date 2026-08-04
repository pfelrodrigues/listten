import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Everything the machine plays, captured through a CoreAudio process tap.
///
/// A tap needs only the audio capture permission. ScreenCaptureKit would do the
/// same job and ask for screen recording, which is a great deal to grant
/// something that never looks at the screen.
///
/// The tap is global, so a call is captured whichever application hosts it, and
/// it is read through a private aggregate device: private because an aggregate
/// left visible turns up in the user's sound settings, and this one exists for
/// the length of a meeting.
///
/// Buffers are stamped with the host time CoreAudio reports for them, the same
/// clock `MicrophoneCapture` uses, which is what puts the two tracks on one
/// timeline.
public actor SystemAudioCapture: AudioSource {
    /// The tap could not be built. Almost always the permission: a global tap
    /// hears other applications, and the system refuses one until the user has
    /// agreed to it in Privacy and Security.
    public struct TapUnavailable: Error, Equatable {
        public let status: OSStatus
        public let stage: String
    }

    /// The system took longer to answer than a person would wait. Creating the
    /// I/O procedure blocks until the permission is resolved, and on a process
    /// that cannot show the prompt it blocks for good, which hung a recording
    /// once already through the microphone. A wait that ends is an error
    /// somebody can read.
    public struct TapSetupTimedOut: Error, Equatable {}

    private static let slots = 16
    fileprivate static let framesPerSlot = 16384

    private static let firstBufferGrace: TimeInterval = 3
    private static let silenceTolerance: TimeInterval = 2
    private static let watchInterval = Duration.milliseconds(500)
    private static let maxRestarts = 5
    fileprivate static let setupTimeout: TimeInterval = 20

    private let mono = MonoScratch(frames: framesPerSlot)
    private var continuation: AsyncStream<CapturedAudio>.Continuation?
    private var devices: TapDevices?
    private var outputObserver: (any NSObjectProtocol)?
    private var ring: CaptureRing?
    private var drain: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var outputChanged = false
    private var consecutiveRestarts = 0
    private var totalRestarts = 0
    private var droppedWhileRunning = 0

    public init() {}

    /// Buffers the audio thread had to throw away because the drain fell
    /// behind. Non-zero means audio is missing from the recording.
    public var droppedBuffers: Int { ring?.dropped ?? droppedWhileRunning }

    /// How many times the watchdog had to bring the tap back. Non-zero means
    /// the recording has gaps that were recovered rather than lost.
    public var restarts: Int { totalRestarts }

    public func start() async throws -> AsyncStream<CapturedAudio> {
        guard continuation == nil else { throw CaptureAlreadyStarted() }

        let ring = CaptureRing(slots: Self.slots, framesPerSlot: Self.framesPerSlot)
        self.ring = ring

        let (stream, continuation) = AsyncStream<CapturedAudio>
            .makeStream(
                bufferingPolicy: .bufferingNewest(Self.slots)
            )
        self.continuation = continuation

        let built: TapDevices
        do {
            built = try await TapDevices.built(feeding: ring, through: mono)
        } catch {
            tearDown()
            throw error
        }

        // An actor is reentrant, and the wait above lasts as long as the
        // permission takes to resolve. A caller that stopped in the meantime has
        // already been given a finished stream, and going on would leave a live
        // tap behind it with the recording indicator lit.
        guard self.continuation != nil, self.ring === ring else {
            built.destroy()
            return stream
        }
        devices = built

        drain = Task.detached(priority: .userInitiated) {
            await Self.drain(ring, into: continuation)
        }
        watchdog = Task { [weak self] in await self?.watch(ring) }
        observeDefaultOutputChanges()
        return stream
    }

    public func stop() {
        guard continuation != nil else { return }
        tearDown()
    }

    /// The tap reads the default output device, so swapping it leaves the
    /// aggregate reading a device nobody is playing through any more. Nothing is
    /// reported when that happens: the buffers simply stop, which is why the
    /// change is listened for rather than waited out.
    ///
    /// It raises a flag rather than rebuilding, because rebuilding suspends for
    /// as long as the tap takes to come up and the watchdog can want the same
    /// thing at the same moment. Two rebuilds in flight each finish holding a
    /// started tap, and only one of them can be kept: the other is a live tap,
    /// aggregate device and I/O procedure nobody holds, running for the rest of
    /// the process with the recording indicator lit. One rebuilder, and the
    /// question of who asked for it stops mattering.
    private func observeDefaultOutputChanges() {
        outputObserver = NotificationCenter.default.addObserver(
            forName: Self.defaultOutputChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.outputDeviceChanged() }
        }
        DefaultOutputWatcher.shared.add()
    }

    private func outputDeviceChanged() {
        outputChanged = true
    }

    /// Watches for the failure the whole design exists to avoid: a session that
    /// believes it is recording while nothing arrives. Unlike a microphone, a
    /// tap delivers buffers through silence, so nothing arriving is always
    /// wrong rather than a quiet room.
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
                consecutiveRestarts = 0
            }

            // A device swapped underneath, or one that changed rate without
            // changing identity. Neither stops the buffers, so neither reaches
            // the stall check below: audio keeps arriving, stamped at a rate the
            // device is no longer running at, and a track written that way plays
            // at the wrong speed and slides away from the microphone.
            if outputChanged || rateMoved() {
                outputChanged = false
                await restartCapture(countingIt: false)
                detector.received(at: Self.now())
                continue
            }

            guard detector.verdict(at: Self.now()) == .stalled else { continue }

            // Restarting forever would hide a tap that is never coming back.
            // Ending the stream tells the caller to finalize what it has.
            guard consecutiveRestarts < Self.maxRestarts else {
                tearDown()
                return
            }
            await restartCapture(countingIt: true)
        }
    }

    /// Rebuilding the tap and the aggregate leaves the ring and its timestamps
    /// alone, so the silence shows up as a gap on the timeline instead of
    /// shifting everything that follows.
    ///
    /// Called only from the watchdog, which is a single loop that awaits this
    /// before going round again. That is what makes one rebuild at a time true
    /// rather than hoped for.
    private func restartCapture(countingIt counted: Bool) async {
        guard let ring, continuation != nil else { return }
        if counted {
            consecutiveRestarts += 1
            totalRestarts += 1
        }

        devices?.destroy()
        devices = nil
        do {
            let built = try await TapDevices.built(feeding: ring, through: mono)
            guard continuation != nil, self.ring === ring else { return built.destroy() }
            devices = built
        } catch {
            // A default device halfway through being swapped refuses the tap,
            // and that is a moment rather than a verdict. Ending the session
            // here reads to the caller as a clean finish and silently truncates
            // the meeting, so the watchdog is left to try again; it is the one
            // that eventually gives up, loudly, after a bounded number of tries.
            return
        }
    }

    /// Whether the aggregate is running at a rate other than the one every
    /// buffer is being stamped with. Polled rather than listened for: the rate
    /// can move without the default device changing, and reading one property
    /// twice a second costs nothing next to a track recorded at the wrong speed.
    private func rateMoved() -> Bool {
        guard let devices else { return false }
        let now = TapDevices.sampleRate(of: devices.aggregate)
        return now > 0 && now != devices.rate
    }

    private static func now() -> TimeInterval {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
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
        if let outputObserver {
            NotificationCenter.default.removeObserver(outputObserver)
            DefaultOutputWatcher.shared.remove()
        }
        outputObserver = nil

        devices?.destroy()
        devices = nil

        watchdog?.cancel()
        watchdog = nil

        if let drain {
            drain.cancel()
        } else {
            continuation?.finish()
        }
        drain = nil
        continuation = nil
        droppedWhileRunning = ring?.dropped ?? droppedWhileRunning
        ring = nil
    }

    static let defaultOutputChanged = Notification.Name("listten.defaultOutputChanged")
}

/// The three CoreAudio objects a tap needs, built and destroyed together.
///
/// Kept as one value because a half-built tap leaks: an aggregate device that
/// nobody destroys survives the process and shows up in the user's sound
/// settings, and a tap that outlives its aggregate keeps the permission
/// indicator lit for a recording that ended.
private struct TapDevices: Sendable {
    let tap: AudioObjectID
    let aggregate: AudioObjectID
    let proc: AudioDeviceIOProcID
    /// What every buffer this built is stamped with, kept so a device that
    /// moves off it can be noticed.
    let rate: Double

    /// Built on a thread of its own, because creating the I/O procedure blocks
    /// the calling thread until the system has resolved the audio capture
    /// permission, and on a process that cannot show the prompt it blocks for
    /// good. A dispatch queue rather than a `Task`: cancelling a task does not
    /// interrupt a blocked C call, so the wait would go on with the machinery
    /// around it doing nothing, and a blocked cooperative thread is one the rest
    /// of the program has lost.
    ///
    /// Whichever of the two arrives first answers, once. A build that comes back
    /// after the timeout destroys what it made rather than leaving a tap and an
    /// aggregate device behind that nobody holds.
    static func built(
        feeding ring: CaptureRing,
        through scratch: MonoScratch
    ) async throws -> TapDevices {
        let answered = Mutex(false)
        @Sendable func first() -> Bool {
            answered.withLock { alreadyAnswered in
                guard !alreadyAnswered else { return false }
                alreadyAnswered = true
                return true
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated)
                .async {
                    do {
                        let devices = try build(feeding: ring, through: scratch)
                        guard first() else { return devices.destroy() }
                        continuation.resume(returning: devices)
                    } catch {
                        guard first() else { return }
                        continuation.resume(throwing: error)
                    }
                }

            DispatchQueue.global()
                .asyncAfter(deadline: .now() + SystemAudioCapture.setupTimeout) {
                    guard first() else { return }
                    continuation.resume(throwing: SystemAudioCapture.TapSetupTimedOut())
                }
        }
    }

    /// Blocking, and deliberately so: every call here is synchronous CoreAudio.
    /// It runs on a thread of its own, and each stage cleans up what the
    /// stages before it made, so a failure half way leaves nothing behind.
    private static func build(
        feeding ring: CaptureRing,
        through scratch: MonoScratch
    ) throws -> TapDevices {
        let output = try defaultOutputUID()

        // Global rather than a mixdown of named processes: a meeting is
        // whichever application happens to be hosting it, and a tap that has to
        // be told which one would miss the next.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Listten"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapped = AudioHardwareCreateProcessTap(description, &tap)
        guard tapped == noErr else {
            throw SystemAudioCapture.TapUnavailable(status: tapped, stage: "tap")
        }

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let built = AudioHardwareCreateAggregateDevice(
            [
                kAudioAggregateDeviceNameKey: "Listten",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: output,
                // Private, so a recording does not leave a device behind in the
                // user's sound settings for as long as the process lives.
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
                kAudioAggregateDeviceTapListKey: [
                    [
                        // The tap and the output device run off separate crystals
                        // that drift apart over a meeting, which without this
                        // shows up as audio slowly sliding off the timeline.
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                    ]
                ],
            ] as CFDictionary,
            &aggregate
        )
        guard built == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            throw SystemAudioCapture.TapUnavailable(status: built, stage: "aggregate")
        }

        let rate = sampleRate(of: aggregate)
        guard rate > 0 else {
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            throw SystemAudioCapture.TapUnavailable(status: noErr, stage: "rate")
        }
        guard deliversInterleavedFloat(tap) else {
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            throw SystemAudioCapture.TapUnavailable(status: noErr, stage: "layout")
        }

        // Everything inside this block runs on the audio thread, where
        // allocating, locking or waiting would cost recorded audio. It folds
        // into a buffer that already exists and returns.
        let mono = scratch.samples
        var proc: AudioDeviceIOProcID?
        // A queue of its own rather than nil. Nil asks CoreAudio for its own I/O
        // thread, which is what every example does and what works from a plain
        // command; from inside an application bundle the call then never
        // returns, measured, blocked in the exchange with coreaudiod that
        // registers the stream. Naming a queue is the difference between a tap
        // that starts and one that hangs where the whole recording waits on it.
        let queue = DispatchQueue(label: "br.com.pfelrodrigues.listten.tap", qos: .userInitiated)
        let created = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) {
            _,
            input,
            stamp,
            _,
            _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            // One buffer, checked when the tap was built. More would be one per
            // channel, and reading each as a whole buffer would write twice the
            // frames for one instant with the channels concatenated rather than
            // mixed. Unreachable, so it stops rather than guesses.
            guard list.count == 1 else { return }
            // The stamp CoreAudio put on the buffer, not the instant this
            // process saw it, so the two tracks describe one timeline.
            // A stamp of zero is a buffer CoreAudio did not place. Anchoring the
            // shared timeline on one would put both tracks in the wrong place,
            // so the machine clock stands in, which is the same clock the stamp
            // is drawn from.
            let stamped = stamp.pointee.mHostTime
            let hostTime = AVAudioTime.seconds(
                forHostTime: stamped > 0 ? stamped : mach_absolute_time()
            )
            for buffer in list {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, let data = buffer.mData else { continue }
                let frames = Int(buffer.mDataByteSize) / (4 * channels)
                guard frames > 0, frames <= SystemAudioCapture.framesPerSlot else { continue }

                ChannelMixdown.mix(
                    interleaved: data.assumingMemoryBound(to: Float.self),
                    channels: channels,
                    frames: frames,
                    into: mono
                )
                _ = ring.write(
                    samples: mono,
                    frames: frames,
                    hostTime: hostTime,
                    sampleRate: rate
                )
            }
        }
        guard created == noErr, let proc else {
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            throw SystemAudioCapture.TapUnavailable(status: created, stage: "ioproc")
        }

        let started = AudioDeviceStart(aggregate, proc)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(aggregate, proc)
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            throw SystemAudioCapture.TapUnavailable(status: started, stage: "start")
        }

        return TapDevices(tap: tap, aggregate: aggregate, proc: proc, rate: rate)
    }

    /// Whether the audio thread will get what it is written to read: one buffer
    /// of packed 32-bit floats with the channels alternating.
    ///
    /// Checked here rather than defended against per buffer, because the audio
    /// thread is no place to discover a layout it cannot use and dropping every
    /// buffer there would read as a tap that is merely quiet. Anything else is
    /// refused where refusing is still cheap and says so.
    private static func deliversInterleavedFloat(_ tap: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr else {
            return false
        }

        let flags = format.mFormatFlags
        return format.mChannelsPerFrame > 0
            && format.mBitsPerChannel == 32
            && flags & kAudioFormatFlagIsFloat != 0
            && flags & kAudioFormatFlagIsNonInterleaved == 0
    }

    /// Ignoring what these report is the point: they are called on the way out,
    /// where a device already gone is the outcome asked for. What must not
    /// happen is one of them being skipped, which is why none of them is
    /// conditional on the one before.
    func destroy() {
        AudioDeviceStop(aggregate, proc)
        AudioDeviceDestroyIOProcID(aggregate, proc)
        AudioHardwareDestroyAggregateDevice(aggregate)
        AudioHardwareDestroyProcessTap(tap)
    }

    private static func defaultOutputUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let found = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )
        guard found == noErr, device != AudioObjectID(kAudioObjectUnknown) else {
            throw SystemAudioCapture.TapUnavailable(status: found, stage: "output")
        }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Unmanaged because the property hands back a retained CFString, and
        // reading it into an Optional<CFString> makes CoreAudio write an object
        // reference through a pointer Swift believes it owns.
        var uid = Unmanaged<CFString>.passUnretained("" as CFString)
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        let read = AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid)
        guard read == noErr else {
            throw SystemAudioCapture.TapUnavailable(status: read, stage: "output-uid")
        }
        return uid.takeRetainedValue() as String
    }

    /// The rate the aggregate actually runs at, which is the one the audio is
    /// arriving at and the one a file has to be written with.
    ///
    /// Not the input stream's virtual format, and not the tap's: on a machine
    /// playing through Bluetooth both of those said 48000 while the device ran
    /// at 24000, and buffers arrived holding half the frames the clock had gone
    /// through. Written at the rate they claimed, the system track came out at
    /// twice the speed and half the length, sliding away from the microphone it
    /// is supposed to be interleaved with. Measured, not reasoned about: the
    /// nominal rate was the only one of the three that matched the buffers.
    static func sampleRate(of aggregate: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, &rate) == noErr else {
            return 0
        }
        return rate
    }
}

/// One CoreAudio listener for the default output device, however many captures
/// are running. Registering per capture would leave a listener behind for every
/// one that ended, since CoreAudio removes a listener by the block it was given
/// and nothing here holds those.
private final class DefaultOutputWatcher: @unchecked Sendable {
    static let shared = DefaultOutputWatcher()

    private let lock = NSLock()
    private var listeners = 0
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let block: AudioObjectPropertyListenerBlock = { _, _ in
        NotificationCenter.default.post(name: SystemAudioCapture.defaultOutputChanged, object: nil)
    }

    func add() {
        lock.withLock {
            listeners += 1
            guard listeners == 1 else { return }
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                nil,
                block
            )
        }
    }

    func remove() {
        lock.withLock {
            listeners -= 1
            guard listeners == 0 else { return }
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                nil,
                block
            )
        }
    }
}
