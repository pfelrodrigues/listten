import Testing

@testable import ListtenCore

@Test("a segment knows when it ends")
func segmentEnd() {
    let segment = Segment(index: 1, track: .microphone, start: 10, duration: 45)
    #expect(segment.end == 55)
}
