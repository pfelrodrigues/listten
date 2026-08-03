import Foundation
import Testing

@testable import ListtenCore

@Test("an utterance that ends before it starts cannot exist")
func lineEndingBeforeItStartsIsRefused() {
    #expect(throws: TranscriptLine.Impossible.endBeforeStart(start: 90, end: 10)) {
        try TranscriptLine(speaker: "me", start: 90, end: 10, text: "backwards")
    }
}

@Test("an utterance before the session started cannot exist")
func lineStartingBeforeTheSessionIsRefused() {
    #expect(throws: TranscriptLine.Impossible.negativeStart(-1)) {
        try TranscriptLine(speaker: "me", start: -1, end: 3, text: "early")
    }
}

/// A speaker is an open string so named diarization can arrive later, and a
/// recognizer that heard an instant of nothing still reports the instant.
@Test("an unnamed speaker saying nothing is still a line")
func emptySpeakerAndTextAreAccepted() throws {
    let line = try TranscriptLine(speaker: "", start: 4, end: 4, text: "")
    #expect(line.end == 4)
}

@Test("an utterance read back from a stored transcript answers to the same rules")
func decodingALineRefusesWhatConstructionRefuses() {
    let stored = Data(#"{"speaker":"me","start":90,"end":10,"text":"backwards"}"#.utf8)

    #expect(throws: TranscriptLine.Impossible.endBeforeStart(start: 90, end: 10)) {
        try JSONDecoder().decode(TranscriptLine.self, from: stored)
    }
}

@Test("an utterance survives the round trip it is stored by")
func lineRoundTrips() throws {
    let line = try TranscriptLine(speaker: "me", start: 5, end: 8, text: "second")

    let decoded = try JSONDecoder()
        .decode(
            TranscriptLine.self,
            from: try JSONEncoder().encode(line)
        )

    #expect(decoded == line)
}

@Test("merging two tracks orders lines by when they were spoken")
func mergeOrdersByStart() throws {
    let mine = [try TranscriptLine(speaker: "me", start: 5, end: 8, text: "second")]
    let theirs = [try TranscriptLine(speaker: "others", start: 0, end: 3, text: "first")]

    let merged = Transcript.merging(microphone: mine, system: theirs)

    #expect(merged.lines.map(\.text) == ["first", "second"])
}

@Test("overlapping speech keeps the microphone side first")
func mergeBreaksTiesTowardsTheMicrophone() throws {
    let mine = [try TranscriptLine(speaker: "me", start: 4, end: 6, text: "mine")]
    let theirs = [try TranscriptLine(speaker: "others", start: 4, end: 7, text: "theirs")]

    let merged = Transcript.merging(microphone: mine, system: theirs)

    #expect(merged.lines.map(\.text) == ["mine", "theirs"])
}
