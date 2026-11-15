# VoiceApp

On-device dictation for macOS. Hold a shortcut, speak, and release to paste the transcript into the focused app. VoiceApp lives in the menu bar and supports Whisper and NVIDIA Parakeet models running locally through Core ML.

- Push-to-talk and toggle-to-talk, with configurable key combinations and single modifier keys.
- Download, switch, and delete speech models from Settings.
- Multilingual transcription with automatic language detection or a Whisper language hint.
- Clipboard restoration after automatic paste, with a manual-paste fallback.
- No VoiceApp account or cloud transcription service.

## Requirements

- **macOS 14 Sonoma or later**, on an **Apple Silicon Mac**. The packaging script builds for `arm64`.
- **Xcode with a Swift 6.2+ toolchain** for building from source. Select it with `xcode-select` if needed; check with `swift --version`. The local build toolchain is Swift 6.2.3.
- Internet access to fetch build dependencies, download a speech model, and populate its tokenizer cache on first load.
- Space for the build and downloaded models; sizes below are approximate and exclude additional caches.

## Build and launch

```sh
git clone https://github.com/stifamajstor/voiceApp.git
cd voiceApp
scripts/build-app.sh --run
```

This builds a release executable, assembles `build/VoiceApp.app` with its icon and dependency resource bundles, signs it locally, verifies the signature, and launches it. Look for the microphone icon in the menu bar; there is no Dock icon.

Other build options:

```sh
scripts/build-app.sh                 # Build build/VoiceApp.app
scripts/build-app.sh --install --run # Replace /Applications/VoiceApp.app and launch it
scripts/make-dmg.sh                  # Build and create build/VoiceApp-<version>.dmg
scripts/make-dmg.sh --skip-build      # Package the existing build/VoiceApp.app
```

The default signing identity is the **VoiceApp Local Signing** certificate, if present in your keychain; otherwise the script uses ad-hoc signing. To choose an identity explicitly:

```sh
SIGN_IDENTITY="Your Code Signing Identity" scripts/build-app.sh
```

These scripts do not notarize the app. A locally signed DMG shared with another Mac may need approval through **System Settings → Privacy & Security → Open Anyway**.

## First use

1. Click VoiceApp's menu bar icon and open **Settings…**.
2. Download a model. The default selection is **Whisper Large v3 Turbo**; smaller models are also available.
3. Click **Use** for the model you want, if it is not already selected. Wait for **Active** in Settings and **Ready to dictate** in the menu.
4. Grant **Microphone** and **Accessibility** in the Permissions section. Accessibility enables automatic paste and modifier-only shortcuts.
5. Focus a text field in another app, hold **right Option (⌥)**, speak, then release. VoiceApp transcribes and sends **⌘V** to the app that has focus when pasting.

The first model load can take longer while Core ML prepares it for your Mac. If the microphone prompt appears on your first shortcut press, answer it and press the shortcut again to record.

## Shortcuts

| Action | Default | Behavior |
|---|---|---|
| Push-to-talk, modifier key | Right ⌥ Option | Hold to record; release to transcribe |
| Push-to-talk, key combination | ⌥Space | Hold to record; release to transcribe |
| Toggle-to-talk, key combination | ⌥⇧Space | Press once to start; press again to transcribe |
| Toggle-to-talk, modifier key | None | Choose a key in Settings if desired |

Both the key combinations and modifier keys are configurable in Settings. If ⌥Space conflicts with a launcher, record another combination. Key combinations work without Accessibility permission; single modifier keys require it when used outside VoiceApp.

Modifier push-to-talk has a short hold delay. Combining that modifier with another key cancels the recording so ordinary Option-character typing does not produce a transcript. If both modifier actions use the same key, push-to-talk takes precedence.

Recordings shorter than **0.3 seconds** are discarded. Recording stops automatically after **5 minutes**. Additional shortcuts are ignored while transcription is running.

## Models and languages

The catalog in [ModelCatalog.swift](Sources/VoiceApp/ModelCatalog.swift) currently offers:

| Model | Approximate download | Languages |
|---|---|---|
| Whisper Tiny (EN) | 150 MB | English |
| Whisper Base | 145 MB | Multilingual |
| Whisper Small | 485 MB | Multilingual |
| Distil-Whisper Large v3 Turbo | 610 MB | English |
| Whisper Large v3 Turbo | 645 MB | Multilingual; default selection |
| NVIDIA Parakeet TDT 0.6B v3 | 480 MB | 25 European languages; automatic detection |

The **Spoken language** setting supplies a hint to multilingual Whisper models, or you can leave it on **Auto-detect**. English-only models always use English. Parakeet detects the language itself and ignores this setting.

Model downloads and caches are stored under:

```text
~/Library/Application Support/VoiceApp/models
```

Use the trash button next to a downloaded model in Settings to remove it. Models are downloaded separately and are not included in the app or this repository.

## Privacy and permissions

Audio capture and speech inference run on your Mac. VoiceApp does not upload recordings for transcription. Network access is used for dependencies, model files, and tokenizer downloads; prepare the selected model and its first load before relying on offline use.

| Permission | Purpose |
|---|---|
| Microphone | Record audio while dictation is active |
| Accessibility | Send the paste keystroke and observe modifier-only shortcuts globally |

Automatic paste temporarily places the transcript on the system clipboard. VoiceApp restores the previous clipboard contents after about **0.5 seconds**, unless another app or you changed the clipboard in the meantime. It marks automatic-paste entries as transient for clipboard managers that honor `org.nspasteboard.TransientType`; other managers may retain them.

Without Accessibility, the transcript stays on the clipboard and the menu reports **Copied to clipboard — grant Accessibility to auto-paste**. Paste it yourself with **⌘V**.

## Troubleshooting

- **No Dock icon or window:** this is a menu bar app. Click its microphone icon to open Settings or quit.
- **No model ready:** download and select a model, then wait for loading to finish. If loading fails, inspect the message in Settings and use **Retry**. A Whisper model's first load may still need internet access for its tokenizer.
- **No recording:** check Microphone permission, wait for the model to become active, and try a key combination. Modifier-only shortcuts also need Accessibility.
- **Text is copied but not pasted:** enable VoiceApp under **System Settings → Privacy & Security → Accessibility**, then try again. Keep the intended text field focused until transcription finishes.
- **Paste or modifier shortcuts stop working after a rebuild:** remove VoiceApp from Accessibility and add the current `.app` again. Ad-hoc signatures can invalidate the existing grant. A stable signing identity helps preserve it across builds.
- **Shortcut conflicts with another app:** rebind it in Settings. A modifier-only trigger is canceled if you type another key while holding it.
- **Disable start/stop sounds:** turn off **Play start/stop sounds** in Settings → Behavior.

To create a local signing identity, open **Keychain Access → Certificate Assistant → Create a Certificate**, name it **VoiceApp Local Signing**, and choose **Code Signing** as its certificate type.

## Updates

Installed copies update themselves with [Sparkle](https://sparkle-project.org) from this repository's GitHub releases. VoiceApp checks every 6 hours and installs a downloaded update when it next quits; **Check for Updates…** is in the menu bar popover and in Settings → Updates.

To publish a release, run this on the Mac that holds the signing keys, from a clean `main`:

```sh
scripts/release.sh 0.3.0 --notes "First change
Second change"              # Prepare build/release/ and tag v0.3.0 locally
scripts/release.sh 0.3.0 --notes "..." --publish   # Also push and create the GitHub release
```

The script bumps the version in `Resources/Info.plist`, builds and signs the app, makes the DMG and update zip, signs the update with the Sparkle EdDSA key, and generates `appcast.xml`. The first run asks for keychain access twice (the code-signing certificate and the Sparkle key); choose **Always Allow**.

Two keys must stay on this Mac and be backed up together:

- **VoiceApp Local Signing** certificate: macOS ties the Accessibility grant to it, and Sparkle rejects updates signed differently.
- Sparkle EdDSA private key, keychain account `voiceapp` (public half in `SUPublicEDKey`). Export with `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account voiceapp -x key-backup`.

Losing either means installed copies can no longer update and need one manual reinstall.

## Development

VoiceApp is a Swift package with a `VoiceApp` executable and a `VoiceAppCore` logic library. Its main dependencies are [WhisperKit](https://github.com/argmaxinc/WhisperKit), [FluidAudio](https://github.com/FluidInference/FluidAudio), [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts), [Sparkle](https://github.com/sparkle-project/Sparkle), and [GRDB](https://github.com/groue/GRDB.swift). `Package.resolved` records the resolved versions.

```sh
swift build                         # Compile for development
swift test                          # Run VoiceAppCore behavior tests
scripts/build-app.sh                 # Validate the packaged release app
codesign --verify --deep --strict build/VoiceApp.app
```

Use the packaged `.app` for permission and dictation checks. `swift run` does not provide the same app bundle, usage-description metadata, or permission identity.

| Path | Responsibility |
|---|---|
| `Sources/VoiceApp/App.swift` | App lifecycle and menu bar scene |
| `Sources/VoiceAppCore/` | Thread-safe SQLite record store, named migrations, and full-text search |
| `Tests/VoiceAppCoreTests/` | Store persistence, deletion, search, and concurrency tests |
| `ModelCatalog.swift`, `ModelManager.swift`, `ParakeetEngine.swift` | Model catalog, downloads, loading, and transcription |
| `DictationController.swift`, `AudioRecorder.swift` | Dictation state and microphone capture |
| `HotkeyManager.swift`, `ModifierHotkey.swift` | Global shortcuts |
| `TextInserter.swift`, `Permissions.swift` | Clipboard insertion and macOS permissions |
| `SettingsView.swift`, `MenuBarView.swift`, `Theme.swift` | Settings and menu bar interface |
| `Updater.swift` | Sparkle self-updates |
| `Resources/` | App metadata and icon |
| `scripts/` | App bundle, DMG packaging, and releases |

Bare Swift filenames in this table live under `Sources/VoiceApp/`. The build script adjusts generated SwiftPM resource accessors and copies dependency bundles into `Contents/Resources`, so the packaged app does not depend on the source checkout's `.build` directory.

`MemoryStore` defaults to `~/Library/Application Support/VoiceApp/store/store.sqlite`; tests inject temporary directories. It stores immutable dictation, note, and prompt records, indexes raw/final text with FTS5, and preserves payload-free deletion tombstones.

Callers can supply an optional 1–10 character ASCII alphanumeric audio extension; the store derives `audio/<record UUID>.<lowercase extension>`. Use `audioURL(for:)` to get the file location and create its parent directory before writing audio. Deletion removes the file or symlink itself without following symlinks, tolerates unexpected filesystem objects, and leaves the record live if its audio file cannot be removed.

Search treats the last word as a prefix and breaks timestamp ties by insertion order. Connections wait up to five seconds for another writer; a database-local file lock serializes first-open migrations. Deletion explicitly enables SQLite secure deletion and optimizes the FTS index to scrub deleted text on older SQLite versions too.

The store is not wired into dictation yet, so the menu's last three transcripts remain in memory only.

GitHub Actions runs `swift build` and `swift test` on pull requests and pushes to `main`, using macOS 26 and Xcode 26.2 (Swift 6.2). Before shipping a change, also check the packaged app's model download/load, both dictation modes, permissions, actual transcription, paste into another app, and clipboard restoration. Core tests and signature verification alone do not prove those flows.

[SPEC.md](SPEC.md) contains the original design and implementation contracts. For current shortcuts, dependencies, and packaging behavior, follow this README and the source.
