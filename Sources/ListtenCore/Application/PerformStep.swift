import Foundation

/// Runs one step of the pipeline under the two-phase rule: the intent is
/// recorded before the work and the completion once it has returned, so a
/// process that dies in between leaves a step marked for redo rather than one
/// nobody can tell apart from a step that never started.
///
/// The intent is written first and its failure stops the step: work done without
/// an intent on disk is work recovery cannot know happened.
public struct PerformStep: Sendable {
    private let progress: any ProgressLogging

    public init(progress: any ProgressLogging) {
        self.progress = progress
    }

    @discardableResult
    public func callAsFunction<T>(
        _ step: PipelineStep,
        of sessionID: String,
        work: () async throws -> T
    ) async throws -> T {
        try await progress.append(.intent(step), for: sessionID)
        let result = try await work()
        try await progress.append(.completion(step), for: sessionID)
        return result
    }
}
