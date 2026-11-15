import Foundation

struct VerificationError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

func verify() throws {
    guard CommandLine.arguments.count == 3 else {
        throw VerificationError("usage: verify-resource-overlay.swift <overlay.json> <app>")
    }
    let overlayURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let app = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    struct Overlay: Decodable {
        struct Entry: Decodable {
            let name: String
            let copy: String
            enum CodingKeys: String, CodingKey {
                case name
                case copy = "external-contents"
            }
        }
        let roots: [Entry]
    }
    let overlay = try JSONDecoder().decode(Overlay.self, from: Data(contentsOf: overlayURL))
    var modules: [String: String] = [:]
    let bundlePattern = try NSRegularExpression(pattern: #"appendingPathComponent\("([^"]+\.bundle)"\)"#)
    for entry in overlay.roots {
        let source = try String(contentsOfFile: entry.copy, encoding: .utf8)
        guard source.contains("(Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent"),
              let match = bundlePattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else {
            throw VerificationError("Unrecognized adjusted accessor: \(entry.copy)")
        }
        let target = URL(fileURLWithPath: entry.name).deletingLastPathComponent().deletingLastPathComponent()
        modules[String(source[range])] = target.deletingPathExtension().lastPathComponent
    }
    let resources = app.appendingPathComponent("Contents/Resources")
    let bundles = try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "bundle" }.map(\.lastPathComponent).sorted()
    guard !bundles.isEmpty else { throw VerificationError("No resource bundles in \(resources.path)") }
    for bundle in bundles where modules[bundle] == nil {
        throw VerificationError("No overlay entry for packaged bundle: \(bundle)")
    }
    let plist = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil
    ) as? [String: Any]
    guard let executable = plist?["CFBundleExecutable"] as? String else {
        throw VerificationError("Missing CFBundleExecutable in \(app.path)")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["dyld_info", "-disassemble", app.appendingPathComponent("Contents/MacOS/\(executable)").path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let disassembly = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw VerificationError("Could not disassemble \(executable)") }

    // Check each linked initializer, not a binary-wide string that unrelated app code could supply.
    let symbols = Dictionary(uniqueKeysWithValues: bundles.map { bundle in
        let module = modules[bundle]!
        return (bundle, "_$sSo8NSBundleC\(module.utf8.count)\(module)E6moduleABvpZfiAByXEfU_:")
    })
    let expectedSymbols = Set(symbols.values)
    var selectors: [String: Set<String>] = [:]
    var current: String?
    disassembly.enumerateLines { line, _ in
        if line.hasSuffix(":") {
            current = expectedSymbols.contains(line) ? line : nil
        } else if let symbol = current {
            for selector in ["mainBundle", "resourceURL"] where line.contains("; selector \"\(selector)\"") {
                selectors[symbol, default: []].insert(selector)
            }
        }
    }
    for bundle in bundles {
        let module = modules[bundle]!
        let symbol = symbols[bundle]!
        guard selectors[symbol] == Set(["mainBundle", "resourceURL"]) else {
            throw VerificationError("Linked Bundle.module initializer for \(module) does not use Bundle.main.resourceURL; refusing to package \(bundle)")
        }
        print("Verified linked resource accessor: \(module) -> \(bundle)")
    }
}

do {
    try verify()
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
