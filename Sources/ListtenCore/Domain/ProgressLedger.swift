import Foundation

/// What a progress log means once its intents and completions are matched.
public struct ProgressLedger: Sendable, Equatable {
    /// A completion is only ever written by the step that declared the intent,
    /// so one without it is a log to disbelieve rather than to read around.
    public struct BrokenLog: Error, Equatable {
        public let completionWithoutIntent: PipelineStep

        public init(completionWithoutIntent: PipelineStep) {
            self.completionWithoutIntent = completionWithoutIntent
        }
    }

    /// Steps the process died inside, in the order their intents were written.
    public let interrupted: [PipelineStep]

    /// Steps that reached their completion, which must not run again.
    public let finished: [PipelineStep]

    /// What a log nobody could read leaves known: nothing was in flight as far
    /// as anyone can tell, and nothing may be skipped as finished.
    public static let nothingKnown = ProgressLedger()

    private init() {
        interrupted = []
        finished = []
    }

    /// Folded in the order the log holds, which is the order the steps ran: a
    /// completion answers the intent before it, and an intent written again puts
    /// a step that had finished back in flight, since a redo is a fresh attempt
    /// rather than a record of the attempt before.
    public init(_ checkpoints: [Checkpoint]) throws {
        var inFlight: [PipelineStep] = []
        var done: [PipelineStep] = []

        for checkpoint in checkpoints {
            switch checkpoint {
            case .intent(let step):
                done.removeAll { $0 == step }
                // Twice for one step is a step interrupted twice, not two steps.
                if !inFlight.contains(step) { inFlight.append(step) }
            case .completion(let step):
                guard let started = inFlight.firstIndex(of: step) else {
                    throw BrokenLog(completionWithoutIntent: step)
                }
                inFlight.remove(at: started)
                done.append(step)
            }
        }

        interrupted = inFlight
        finished = done
    }
}
