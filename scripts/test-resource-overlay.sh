#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$TEST_DIR"
mkdir -p Sources/Probe
cat > Package.swift <<'SWIFT'
// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "Probe", targets: [
    .executableTarget(name: "Probe", resources: [.copy("sample.txt")])
])
SWIFT
echo 'relocated resource' > Sources/Probe/sample.txt
cat > Sources/Probe/main.swift <<'SWIFT'
import Foundation
let bundle = Bundle.module
let expected = Bundle.main.resourceURL!.appendingPathComponent("Probe_Probe.bundle")
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

swift build -c release --arch arm64 --print-manifest-job-graph >/dev/null
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
OVERLAY="$TEST_DIR/.build/resource-accessors/overlay.json"
swift "$ROOT/scripts/prepare-resource-overlay.swift" "$BIN_DIR" "$(dirname "$OVERLAY")"
swift build -c release --arch arm64 -Xswiftc -vfsoverlay -Xswiftc "$OVERLAY"

# An environment change invalidates PackageStructure even when sources are unchanged.
VOICEAPP_OVERLAY_TEST=replan swift build -c release --arch arm64 \
    -Xswiftc -vfsoverlay -Xswiftc "$OVERLAY"
grep -q 'Bundle.main.bundleURL.appendingPathComponent' \
    "$BIN_DIR/Probe.build/DerivedSources/resource_bundle_accessor.swift"

APP="$TEST_DIR/relocated/Probe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Probe" "$APP/Contents/MacOS/Probe"
ditto "$BIN_DIR/Probe_Probe.bundle" "$APP/Contents/Resources/Probe_Probe.bundle"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Probe</string>
<key>CFBundleIdentifier</key><string>local.resource-overlay-probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
mv .build hidden-build
"$APP/Contents/MacOS/Probe"
