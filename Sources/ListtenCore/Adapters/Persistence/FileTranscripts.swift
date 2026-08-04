import Foundation

/// Transcripts beside the audio they came from, one file per session.
///
/// Written whole rather than appended: a transcript is produced once per run and
/// rewritten wholesale when a run is redone, which is the opposite of the
/// progress log's job and wants the opposite mechanism.
public struct FileTranscripts: TranscriptStoring {
    public struct Unreadable: Error {
        public let id: String
        public let underlying: any Error
    }

    private static let fileName = "transcript.json"

    private let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(root: URL) {
        self.root = root
    }

    public func save(_ transcript: CorrectedTranscript, for sessionID: String) async throws {
        let directory = root.appending(path: sessionID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Temp then rename, like the session state: a reader sees the whole
        // previous transcript or the whole new one, never half of either.
        let destination = directory.appending(path: Self.fileName)
        let temporary = destination.appendingPathExtension("writing")
        try encoder.encode(transcript).write(to: temporary)
        guard rename(temporary.path, destination.path) == 0 else {
            throw Unreadable(
                id: sessionID,
                underlying: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            )
        }
    }

    public func load(for sessionID: String) async throws -> CorrectedTranscript? {
        let file = root.appending(path: sessionID).appending(path: Self.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            return try decoder.decode(CorrectedTranscript.self, from: try Data(contentsOf: file))
        } catch {
            // A transcript that exists and cannot be read is not the same as one
            // that was never made: reading it as nil would transcribe again and
            // overwrite whatever is there.
            throw Unreadable(id: sessionID, underlying: error)
        }
    }
}
