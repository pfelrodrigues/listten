import Foundation
import Testing

@testable import ListtenCore

@Test("a live line keeps the track it was heard on")
func aLiveLineKeepsItsTrack() throws {
    let line = try LiveLine(track: .system, start: 5, end: 7, text: "the room is booked")

    #expect(line.track == .system)
    #expect(line.start == 5)
    #expect(line.end == 7)
    #expect(line.text == "the room is booked")
}

/// The instants are on the session clock, which starts at zero and runs
/// forwards. A negative one would place a line before the meeting began.
@Test("a line starting before the session is refused")
func aLineBeforeTheSessionIsRefused() {
    #expect(throws: LiveLine.Impossible.negativeStart(-1)) {
        try LiveLine(track: .microphone, start: -1, end: 2, text: "before the anchor")
    }
}

@Test("a line that ends before it starts is refused")
func aLineEndingBeforeItStartsIsRefused() {
    #expect(throws: LiveLine.Impossible.endBeforeStart(start: 4, end: 3)) {
        try LiveLine(track: .microphone, start: 4, end: 3, text: "backwards")
    }
}

@Test("a line with no length at all is a line, since a word can be an instant")
func aLineOfNoLengthIsAllowed() throws {
    let line = try LiveLine(track: .microphone, start: 2, end: 2, text: "sim")

    #expect(line.start == line.end)
}

@Test("what is written is what comes back")
func aLiveLineSurvivesTheRoundTrip() throws {
    let line = try LiveLine(track: .microphone, start: 1.5, end: 3.25, text: "bom dia")

    let read = try JSONDecoder().decode(LiveLine.self, from: try JSONEncoder().encode(line))

    #expect(read == line)
}

/// Decoding is the other way in, and the file is read and written by programs
/// this project does not own. A line that could not have been produced must not
/// be decodable either.
@Test("a stored line that could never have been produced is refused on the way back in")
func aStoredLineThatCouldNeverBeProducedIsRefused() {
    let stored = Data(
        #"{"track":"microphone","start":9,"end":4,"text":"backwards"}"#.utf8
    )

    #expect(throws: LiveLine.Impossible.endBeforeStart(start: 9, end: 4)) {
        try JSONDecoder().decode(LiveLine.self, from: stored)
    }
}

/// The four keys #90 names, spelled the way the issue spells them: another
/// program reads this file, so renaming a key is a breaking change rather than
/// a refactor.
@Test("a line is written as the four fields the issue names")
func aLineIsWrittenAsTheFieldsTheIssueNames() throws {
    let line = try LiveLine(track: .system, start: 0, end: 1, text: "hi")

    let encoded = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(line))
    let fields = try #require(encoded as? [String: Any])

    #expect(Set(fields.keys) == ["track", "start", "end", "text"])
    #expect(fields["track"] as? String == "system")
}
