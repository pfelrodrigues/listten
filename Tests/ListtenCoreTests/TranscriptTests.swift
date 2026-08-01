import Testing

@testable import ListtenCore

@Test("merging two tracks orders lines by when they were spoken")
func mergeOrdersByStart() {
    let mine = [TranscriptLine(speaker: "me", start: 5, end: 8, text: "second")]
    let theirs = [TranscriptLine(speaker: "others", start: 0, end: 3, text: "first")]

    let merged = Transcript.merging(microphone: mine, system: theirs)

    #expect(merged.lines.map(\.text) == ["first", "second"])
}

@Test("overlapping speech keeps the microphone side first")
func mergeBreaksTiesTowardsTheMicrophone() {
    let mine = [TranscriptLine(speaker: "me", start: 4, end: 6, text: "mine")]
    let theirs = [TranscriptLine(speaker: "others", start: 4, end: 7, text: "theirs")]

    let merged = Transcript.merging(microphone: mine, system: theirs)

    #expect(merged.lines.map(\.text) == ["mine", "theirs"])
}
