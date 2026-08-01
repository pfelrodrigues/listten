import Foundation
import Testing

private let sourcesRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Sources")

private func swiftFiles(in directory: String) -> [URL] {
    let root = sourcesRoot.appending(path: directory)
    guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else { return [] }
    return files.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

private func imports(of file: URL) throws -> [String] {
    try String(contentsOf: file, encoding: .utf8)
        .split(separator: "\n")
        .filter { $0.hasPrefix("import ") }
        .map { String($0.dropFirst("import ".count)).trimmingCharacters(in: .whitespaces) }
}

@Test("Domain depends on Foundation only")
func domainImportsOnlyFoundation() throws {
    for file in swiftFiles(in: "ListtenCore/Domain") {
        let unexpected = try imports(of: file).filter { $0 != "Foundation" }
        #expect(unexpected.isEmpty, "\(file.lastPathComponent) imports \(unexpected)")
    }
}

@Test("capture and persistence never discard errors with try?")
func noSilentErrorsWhereRecordingsAreLost() throws {
    for directory in ["ListtenCore/Adapters/Capture", "ListtenCore/Adapters/Persistence"] {
        for file in swiftFiles(in: directory) {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains("try?"), "\(file.lastPathComponent) uses try?")
        }
    }
}

@Test("the CLI target reaches the domain only through ListtenCore")
func cliDependsOnCoreOnly() throws {
    let allowed: Set = ["Foundation", "AppKit", "SwiftUI", "UserNotifications", "ListtenCore"]
    for file in swiftFiles(in: "listten") {
        let unexpected = try imports(of: file).filter { !allowed.contains($0) }
        #expect(unexpected.isEmpty, "\(file.lastPathComponent) imports \(unexpected)")
    }
}
