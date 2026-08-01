import Testing

@testable import ListtenCore

@Test("version is semver with three numeric components")
func versionIsSemver() {
    let parts = Listten.version.split(separator: ".")
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { Int($0) != nil })
}
