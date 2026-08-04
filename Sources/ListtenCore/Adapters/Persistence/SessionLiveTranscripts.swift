import Foundation

/// One `live.jsonl` per session, beside the audio it was heard from.
///
/// Beside the audio rather than beside the state file, and with a different
/// extension from `transcript.json`, because the two must not be mistakable for
/// each other. This one is noisier — on the same audio the live engine heard
/// "os criptos" where the file backend heard "os scripts" — and the offline
/// transcript is the record a note gets written from.
///
/// Appended rather than written and renamed, for the reason the log it is built
/// on already gives: a reader following the meeting must never see half a line.
///
/// The lines are in the order they settled, which is roughly but not strictly
/// chronological: two tracks settle independently and an append-only file cannot
/// be sorted. A reader wanting strict chronology sorts by `start`. Strict
/// interleaving lives in `Transcript.merging`, on the record.
public struct SessionLiveTranscripts: LiveTranscriptWriting {
    static let fileName = "live.jsonl"

    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The directory is created here rather than assumed: the first line may be
    /// written before capture has closed a single segment into it.
    public func append(_ line: LiveLine, for sessionID: String) throws {
        try FileManager.default.createDirectory(
            at: url(for: sessionID).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONLLog<LiveLine>(url: url(for: sessionID)).append(line)
    }

    /// Where a reader following the meeting should look.
    public func url(for sessionID: String) -> URL {
        root
            .appending(path: sessionID)
            .appending(path: "audio")
            .appending(path: Self.fileName)
    }
}
