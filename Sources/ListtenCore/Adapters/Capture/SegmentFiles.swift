import AVFoundation
import Foundation

/// Reads what a session's audio directory actually holds.
///
/// The names are the ones `SegmentedCapture` writes, and the durations come
/// from the files rather than from anything that remembers them, which is the
/// point: this is consulted precisely when the thing that remembers was cut off.
public struct SegmentFiles: RecordedAudio {
    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func segments(for sessionID: String) async throws -> [SegmentFile] {
        let directory = root.appending(path: sessionID).appending(path: "audio")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }

        return try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .compactMap(Self.described)
            .map { named in
                SegmentFile(
                    track: named.track,
                    index: named.index,
                    duration: try duration(of: directory.appending(path: named.name))
                )
            }
    }

    private func duration(of file: URL) throws -> TimeInterval {
        let audio = try AVAudioFile(forReading: file)
        return Double(audio.length) / audio.fileFormat.sampleRate
    }

    /// `mic-0001.caf`, the shape `SegmentedCapture.url(for:index:)` writes. A
    /// file that does not match is not ours and is left alone.
    private static func described(_ name: String) -> (name: String, track: Track, index: Int)? {
        let parts = name.replacingOccurrences(of: ".caf", with: "").split(separator: "-")
        guard
            parts.count == 2,
            name.hasSuffix(".caf"),
            let number = Int(parts[1]),
            number > 0
        else { return nil }

        switch parts[0] {
        case "mic": return (name, .microphone, number - 1)
        case "sys": return (name, .system, number - 1)
        default: return nil
        }
    }
}
