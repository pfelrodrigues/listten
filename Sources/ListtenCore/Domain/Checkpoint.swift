import Foundation

/// One piece of work the pipeline does to durable state, named rather than
/// described: two entries about the same step have to be recognisable as the
/// same step, which is what a payload of results could not promise.
public enum PipelineStep: Sendable, Equatable, Codable {
    case closingSegment(track: Track, index: Int)
    case transcribingChunk(index: Int)
}

/// One end of a step, written around the work rather than after it: the intent
/// before the step acts, the completion once it has.
///
/// An intent with no completion is a step the process died inside, so recovery
/// redoes that one instead of guessing from the state which step the state was
/// reached by. Both present means it finished and must not run again.
public enum Checkpoint: Sendable, Equatable, Codable {
    case intent(PipelineStep)
    case completion(PipelineStep)
}
