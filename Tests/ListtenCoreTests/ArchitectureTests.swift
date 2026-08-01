import Foundation
import Testing

private let sourcesRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Sources")

/// A rule whose directory has moved would otherwise scan nothing and report
/// success, which is how a guard stops guarding without anyone noticing.
private struct DirectoryNotFound: Error {
    let path: String
}

private func swiftFiles(in directory: String) throws -> [URL] {
    let root = sourcesRoot.appending(path: directory)
    var isDirectory: ObjCBool = false
    guard
        FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
        isDirectory.boolValue,
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else {
        throw DirectoryNotFound(path: directory)
    }
    return files.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

private let importPrefixes: Set = [
    "@testable", "public", "package", "internal", "fileprivate", "private",
]

/// `InternalImportsByDefault` makes `internal import X` idiomatic, and it does
/// not start with `import`, so prefix matching alone lets anything through.
private func importedModules(in source: String) -> [String] {
    source.split(separator: "\n")
        .compactMap { line in
            var tokens = line.split(separator: " ").map(String.init)

            while let head = tokens.first, head != "import" {
                guard importPrefixes.contains(head) else { return nil }
                tokens.removeFirst()
            }
            guard tokens.first == "import" else { return nil }
            tokens.removeFirst()

            // `import struct Foundation.Date` imports Foundation.
            if let kind = tokens.first, importedKinds.contains(kind) {
                tokens.removeFirst()
            }
            return tokens.first?.split(separator: ".").first.map(String.init)
        }
}

private let importedKinds: Set = [
    "struct", "class", "enum", "protocol", "typealias", "func", "var", "let",
]

private func imports(of file: URL) throws -> [String] {
    importedModules(in: try String(contentsOf: file, encoding: .utf8))
}

@Test(
    "every spelling of an import is recognised",
    arguments: [
        ("import Foundation", ["Foundation"]),
        ("internal import AppKit", ["AppKit"]),
        ("public import SwiftUI", ["SwiftUI"]),
        ("package import ListtenCore", ["ListtenCore"]),
        ("@testable import ListtenCore", ["ListtenCore"]),
        ("import struct Foundation.Date", ["Foundation"]),
        ("  import AVFoundation", ["AVFoundation"]),
        ("// import AppKit", []),
        ("let importer = 1", []),
    ]
)
func recognisesEveryImportSpelling(source: String, expected: [String]) {
    #expect(importedModules(in: source) == expected)
}

@Test("a rule that points at nothing fails instead of reporting no violations")
func missingDirectoryIsAnError() {
    #expect(throws: (any Error).self) {
        try swiftFiles(in: "ListtenCore/NotADirectory")
    }
}

@Test("the scanner reads real files, so an empty result means there was nothing to read")
func scannerReadsSourceFiles() throws {
    #expect(try !swiftFiles(in: "ListtenCore/Domain").isEmpty)
}

@Test("Domain depends on Foundation only")
func domainImportsOnlyFoundation() throws {
    for file in try swiftFiles(in: "ListtenCore/Domain") {
        let unexpected = try imports(of: file).filter { $0 != "Foundation" }
        #expect(unexpected.isEmpty, "\(file.lastPathComponent) imports \(unexpected)")
    }
}

/// Scoped to the whole core rather than to the directories where losing a
/// recording is unrecoverable: naming those explicitly meant the rule stopped
/// covering anything the moment a file landed somewhere else.
@Test("the core never discards an error with try?")
func noSilentErrorsInTheCore() throws {
    for file in try swiftFiles(in: "ListtenCore") {
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(!source.contains("try?"), "\(file.lastPathComponent) uses try?")
    }
}

@Test("the CLI target reaches the domain only through ListtenCore")
func cliDependsOnCoreOnly() throws {
    let allowed: Set = ["Foundation", "AppKit", "SwiftUI", "UserNotifications", "ListtenCore"]
    for file in try swiftFiles(in: "listten") {
        let unexpected = try imports(of: file).filter { !allowed.contains($0) }
        #expect(unexpected.isEmpty, "\(file.lastPathComponent) imports \(unexpected)")
    }
}
