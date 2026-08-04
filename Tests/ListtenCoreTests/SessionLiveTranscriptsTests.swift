import Foundation
import Testing

@testable import ListtenCore

private let newline = UInt8(ascii: "\n")

private func spoken(_ index: Int, on track: Track = .microphone) -> LiveLine {
    // Long enough that a write split in two would leave a visible tear.
    try! LiveLine(
        track: track,
        start: Double(index) * 5,
        end: Double(index) * 5 + 5,
        text: String(repeating: "palavra \(index) ", count: 20)
    )
}

private func withTemporaryRoot<T>(_ body: (URL) throws -> T) throws -> T {
    let root = temporaryRoot()
    let result = try body(root)
    try FileManager.default.removeItem(at: root)
    return result
}

/// Beside the audio and not beside the state file, and named differently from
/// the transcript a note is written from: #90's whole point is that this file is
/// noisier and must not be mistaken for the record. Recovery ignores it, since
/// it only adopts files named like segments.
@Test("the live transcript lands beside the audio, under its own name")
func theLiveTranscriptLandsBesideTheAudio() throws {
    try withTemporaryRoot { root in
        let writer = SessionLiveTranscripts(root: root)

        try writer.append(spoken(0), for: "2026-01-01-aaa")

        let expected =
            root
            .appending(path: "2026-01-01-aaa")
            .appending(path: "audio")
            .appending(path: SessionLiveTranscripts.fileName)
        #expect(FileManager.default.fileExists(atPath: expected.path))
        #expect(expected == writer.url(for: "2026-01-01-aaa"))
    }
}

/// #90's second acceptance, read off the bytes rather than off the reader: the
/// file is readable at any instant during a meeting, never mid-line. Whatever a
/// reader tails it with, every line it sees is whole and decodes on its own.
@Test("at every instant during a meeting the file holds whole lines only")
func theFileHoldsWholeLinesAtEveryInstant() throws {
    try withTemporaryRoot { root in
        let writer = SessionLiveTranscripts(root: root)
        let url = writer.url(for: "meeting")

        for index in 0..<12 {
            try writer.append(spoken(index), for: "meeting")

            let stored = try Data(contentsOf: url)
            #expect(stored.last == newline, "the file ended mid-line after \(index + 1) appends")

            let lines = stored.split(separator: newline, omittingEmptySubsequences: false)
                .dropLast()
            #expect(lines.count == index + 1, "\(index + 1) lines were written as \(lines.count)")
            for line in lines {
                #expect(throws: Never.self) {
                    try JSONDecoder().decode(LiveLine.self, from: Data(line))
                }
            }
        }
    }
}

/// Two tracks settle independently and append to one file. Without a whole-line
/// atomic write they compute the same end and land inside each other, and a
/// reader following the meeting sees a line that is half of each.
@Test("two tracks appending at once each land a whole line")
func twoTracksAppendingAtOnceEachLandAWholeLine() throws {
    try withTemporaryRoot { root in
        let writer = SessionLiveTranscripts(root: root)
        let each = 64

        DispatchQueue.concurrentPerform(iterations: Track.allCases.count) { index in
            let track = Track.allCases[index]
            for line in 0..<each {
                #expect(throws: Never.self) {
                    try writer.append(spoken(line, on: track), for: "meeting")
                }
            }
        }

        let read = try JSONLLog<LiveLine>(url: writer.url(for: "meeting")).entries()
        #expect(read.count == Track.allCases.count * each)
        for track in Track.allCases {
            #expect(
                read.filter { $0.track == track }.map(\.start)
                    == (0..<each).map { Double($0) * 5 },
                "\(track) lost a line or had one torn"
            )
        }
    }
}
