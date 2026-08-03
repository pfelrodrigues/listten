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

/// Substring matching would flag `retry?` in a comment and `entry?` in an
/// optional pattern, so the keyword has to start on a boundary.
private func discardsErrors(in source: String) -> Bool {
    var index = source.startIndex
    while let found = source.range(of: "try?", range: index..<source.endIndex) {
        let precedes = found.lowerBound == source.startIndex
        if precedes || !isIdentifierCharacter(source[source.index(before: found.lowerBound)]) {
            return true
        }
        index = found.upperBound
    }
    return false
}

private func isIdentifierCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_"
}

@Test(
    "try? is recognised as a keyword rather than as four characters",
    arguments: [
        ("try? load()", true),
        ("let session = try? load()", true),
        ("// should a failed lookup retry? not for now", false),
        ("if case let entry? = stored { }", false),
        ("try await load()", false),
    ]
)
func recognisesDiscardedErrors(source: String, discards: Bool) {
    #expect(discardsErrors(in: source) == discards)
}

/// A port whose only implementation is a fake is a contract production never
/// agreed to. That has cost this project three separate defects, so the rule is
/// a test rather than a habit: every port names something real.
@Test("every port has an implementation outside the tests")
func everyPortIsImplementedInProduction() throws {
    let ports = try swiftFiles(in: "ListtenCore/Ports")
        .flatMap { try declaredProtocols(in: String(contentsOf: $0, encoding: .utf8)) }
    #expect(!ports.isEmpty, "no ports found, so this rule measured nothing")

    let sources = try (swiftFiles(in: "ListtenCore") + swiftFiles(in: "listten"))
        .filter { !$0.path.contains("/Ports/") }
        .map { try String(contentsOf: $0, encoding: .utf8) }

    for port in ports {
        let implemented = sources.contains { conforms(to: port, in: $0) }
        #expect(implemented, "\(port) is a port nothing implements outside the tests")
    }
}

private func declaredProtocols(in source: String) throws -> [String] {
    source.split(separator: "\n")
        .compactMap { line in
            guard line.hasPrefix("public protocol ") else { return nil }
            return
                line
                .dropFirst("public protocol ".count)
                .prefix { $0.isLetter || $0.isNumber }
                .description
        }
}

private let declarationPrefixes = [
    "public ", "private ", "internal ", "fileprivate ", "package ",
    "final ", "actor ", "struct ", "class ", "enum ", "extension ",
]

/// A declaration that adopts it, not a mention of it: `any Port` as a parameter
/// is a use, and a use is what a fake already provides.
private func conforms(to port: String, in source: String) -> Bool {
    source.split(separator: "\n")
        .contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard
                declarationPrefixes.contains(where: { trimmed.hasPrefix($0) })
            else { return false }
            guard let inheritance = trimmed.split(separator: ":").dropFirst().first else {
                return false
            }
            return inheritance.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .contains(Substring(port))
        }
}

/// The coverage gate targets Domain and Application by name and exempts
/// Adapters, so a directory outside all three would carry no target at all.
/// A file at the root of the core is fine: it is visible in any listing, while
/// a whole directory is what slips past unnoticed.
@Test("every directory in the core is a layer the rules know about")
func coreDirectoriesAreKnownLayers() throws {
    let layers = ["Domain", "Application", "Ports", "Adapters"]
    for file in try swiftFiles(in: "ListtenCore") {
        let relative = file.path.components(separatedBy: "/ListtenCore/").last ?? ""
        guard relative.contains("/") else { continue }
        let directory = String(relative.prefix(while: { $0 != "/" }))
        #expect(layers.contains(directory), "\(directory) is not one of \(layers)")
    }
}

/// Scoped to the whole core rather than to the directories where losing a
/// recording is unrecoverable: naming those explicitly meant the rule stopped
/// covering anything the moment a file landed somewhere else.
@Test("the core never discards an error with try?")
func noSilentErrorsInTheCore() throws {
    for file in try swiftFiles(in: "ListtenCore") {
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(!discardsErrors(in: source), "\(file.lastPathComponent) uses try?")
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
