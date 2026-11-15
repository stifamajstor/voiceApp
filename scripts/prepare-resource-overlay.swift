import Foundation

let binDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let overlayDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let fileManager = FileManager.default
try fileManager.createDirectory(at: overlayDirectory, withIntermediateDirectories: true)

func writeIfChanged(_ data: Data, to url: URL) throws {
    if (try? Data(contentsOf: url)) != data {
        try data.write(to: url, options: .atomic)
    }
}

var roots: [[String: String]] = []
for target in try fileManager.contentsOfDirectory(at: binDirectory, includingPropertiesForKeys: nil)
    .filter({ $0.pathExtension == "build" }).sorted(by: { $0.path < $1.path }) {
    let accessor = target.appendingPathComponent("DerivedSources/resource_bundle_accessor.swift")
    guard fileManager.fileExists(atPath: accessor.path) else { continue }

    let original = try String(contentsOf: accessor, encoding: .utf8)
    let search = "Bundle.main.bundleURL.appendingPathComponent"
    let replacement = "(Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent"
    guard original.contains(search) else {
        throw NSError(domain: "VoiceAppPackaging", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Unrecognized SwiftPM resource accessor: \(accessor.path)"
        ])
    }

    let copy = overlayDirectory.appendingPathComponent(target.lastPathComponent + ".swift")
    try writeIfChanged(Data(original.replacingOccurrences(of: search, with: replacement).utf8), to: copy)
    roots.append(["type": "file", "name": accessor.path, "external-contents": copy.path])
}

// Keep SwiftPM's source paths in dependency records so warm builds still track the originals.
let overlay: [String: Any] = ["version": 0, "use-external-names": false, "roots": roots]
try writeIfChanged(
    JSONSerialization.data(withJSONObject: overlay, options: [.prettyPrinted, .sortedKeys]),
    to: overlayDirectory.appendingPathComponent("overlay.json")
)
