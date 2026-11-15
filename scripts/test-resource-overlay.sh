#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$TEST_DIR"
mkdir -p Sources/VoiceApp Resources
ditto "$ROOT/scripts" scripts
cp "$ROOT/Resources/Info.plist" "$ROOT/Resources/AppIcon-1024.png" Resources/
cat > Package.swift <<'SWIFT'
// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "Probe", targets: [
    .executableTarget(name: "VoiceApp", resources: [.copy("sample.txt")])
])
SWIFT
echo 'relocated resource' > Sources/VoiceApp/sample.txt
cat > Sources/VoiceApp/main.swift <<'SWIFT'
import Foundation
let bundle = Bundle.module
let expected = Bundle.main.resourceURL!.appendingPathComponent("Probe_VoiceApp.bundle")
    .resolvingSymlinksInPath().path
guard bundle.bundleURL.resolvingSymlinksInPath().path == expected else {
    print("Expected \(expected), resolved \(bundle.bundleURL.path)")
    exit(1)
}
let sample = bundle.url(forResource: "sample", withExtension: "txt")!
let contents = try String(contentsOf: sample, encoding: .utf8)
precondition(contents == "relocated resource\n")
print("Resolved resource in relocated app: \(sample.path)")
SWIFT

# Exercise the packaging pipeline twice without an environment change that could hide a stale plan.
scripts/build-app.sh
scripts/build-app.sh
mkdir relocated
mv build/VoiceApp.app relocated/Probe.app
mv .build hidden-build
# This executable is the resource-only CLI fixture above, never the real application.
relocated/Probe.app/Contents/MacOS/VoiceApp
