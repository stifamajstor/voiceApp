# VoiceApp — spec

A local macOS menu-bar app (Apple Silicon, tested target: MacBook Pro M1 Pro, macOS 14+).
Its whole job:

1. List a handful of open-source speech-to-text models that run well on an M1 Pro.
2. Let the user pick one; download it on demand (with progress), delete it, switch between them.
3. Let the user set two global shortcuts:
   - **Push-to-talk**: record while held, transcribe on release.
   - **Toggle-to-talk**: press once to start, press again to stop and transcribe.
4. Paste the transcribed text into whatever app is focused.

Everything runs on-device. No accounts, no cloud.

## Stack

- Swift Package (`Package.swift`): executable `VoiceApp` (`Sources/VoiceApp/`), plain logic library
  `VoiceAppCore` (`Sources/VoiceAppCore/`), and `VoiceAppCoreTests` (`swift test`).
- `VoiceAppCore.MemoryStore` uses GRDB/SQLite with FTS5 under
  `~/Library/Application Support/VoiceApp/store/store.sqlite` (directory injectable for tests).
  Immutable dictation/note/prompt records carry UUIDs and a database-persisted install ID.
  The schema requires canonical uppercase, hyphenated record UUIDs and permits only a live-to-tombstone update;
  tombstones cannot be updated, rows cannot be deleted, and inserts cannot replace existing IDs or rowids.
  A future migration that backfills or purges records must drop and recreate these protective triggers.
  Kinds are open string-backed values with named dictation/note/prompt constants; unknown kinds remain readable
  and round-trip unchanged for future sync. Swift rejects negative or non-finite durations. Audio locations
  are derived from the record UUID and an optional 1–10 character ASCII alphanumeric extension,
  exposed by `audioURL(for:)`.
  Deletion clears all payload fields and audio, keeping only an ID/device ID/deletion timestamp tombstone.
  Audio symlinks are never followed; stored paths the store could not have produced and unexpected objects
  do not block tombstoning, while a file removal failure leaves the record live for retry. Connections use
  a five-second busy timeout and `PRAGMA secure_delete = ON`.
  A database-local non-blocking file lock serializes migrations, with a five-second deadline and typed
  `StoreError.migrationLockTimeout` error. Every open on SQLite 3.42+ enables FTS5 `secure-delete` after migrations,
  so an OS upgrade enables scrubbing for existing databases too. Older SQLite rebuilds FTS inside each delete
  transaction. Deleted text is removed from store files after close, excluding filesystem snapshots and backups.
  FTS5 secure deletion can make the index unreadable by SQLite older than 3.42; a rebuild on a newer runtime
  is required before downgrading.
  Named migrations use descriptive feature-qualified names, registered in dependency order; do not number them.
  Search quotes Unicode tokens across raw and final text, with only the last token treated as a prefix.
  Listing and search order by creation time descending, then insertion order descending.
  The store is not connected to dictation yet; menu history remains in memory.
- SwiftUI `MenuBarExtra` (+ a `Settings`/`Window` scene for settings). `LSUIElement = true` (no Dock icon).
- **WhisperKit 1.1.x** (`argmaxinc/WhisperKit`) for CoreML Whisper models: download from
  Hugging Face repo `argmaxinc/whisperkit-coreml`, load, transcribe. Sources are in
  `.build/checkouts/WhisperKit` — read them, don't guess the API.
- **KeyboardShortcuts 1.x** (`sindresorhus/KeyboardShortcuts`) for recordable global hotkeys with
  `onKeyDown` / `onKeyUp`, and `KeyboardShortcuts.Recorder` in the UI.
- `AVAudioEngine` for mic capture, resampled to 16 kHz mono `Float`.
- Text insertion: put the text on `NSPasteboard`, synthesize ⌘V with `CGEvent`, then restore the
  previous clipboard contents. Needs Accessibility permission.
- Packaging: `scripts/build-app.sh` runs `swift build -c release`, assembles `build/VoiceApp.app`
  with `Resources/Info.plist`, ad-hoc codesigns it (`codesign --force --deep -s -`).

## Model catalog (verified against `argmaxinc/whisperkit-coreml` on 2026-09-30)

All variant folders below exist in the HF repo; sizes are the summed file sizes of each folder.

| Display name                  | WhisperKit variant (folder name)                   | ~Size   | Notes                     |
|-------------------------------|----------------------------------------------------|---------|---------------------------|
| Whisper Tiny (EN)             | `openai_whisper-tiny.en`                           | ~150 MB | fastest, English only     |
| Whisper Base                  | `openai_whisper-base`                              | ~145 MB | fast, multilingual        |
| Whisper Small                 | `openai_whisper-small`                             | ~485 MB | good balance              |
| Distil-Whisper Large v3 Turbo | `distil-whisper_distil-large-v3_turbo_600MB`       | ~610 MB | English, fast + accurate  |
| Whisper Large v3 Turbo        | `openai_whisper-large-v3-v20240930_turbo_632MB`    | ~645 MB | best quality, multilingual (recommended default) |
| NVIDIA Parakeet TDT 0.6B v3  | `parakeet-tdt-0.6b-v3` (FluidAudio, `FluidInference/parakeet-tdt-0.6b-v3-coreml`) | ~470 MB | 25 European languages, auto-detected; very fast |

Models download to `~/Library/Application Support/VoiceApp/models/models/argmaxinc/whisperkit-coreml/<variant>`
(WhisperKit `downloadBase` = `.../VoiceApp/models`). A `.voiceapp-complete` marker marks finished downloads.
The tokenizer is not bundled with the CoreML models; WhisperKit fetches it from the Hub on the first
load of each model (needs network once) and caches it under the same `downloadBase`.

## Module ownership & contracts

Files are split between two implementers. Do **not** create or edit files you don't own; code
against these contracts exactly.

### Core (models, transcription, UI)
- `App.swift` — `@main struct VoiceApp: App`. Creates the single `ModelManager` and
  `DictationController(modelManager:)`, calls `dictation.start()` once at launch, shows
  `MenuBarExtra` whose icon reflects `dictation.state`, and a settings window.
- `ModelCatalog.swift` — `struct TranscriptionModel: Identifiable, Hashable` + `static let all`.
- `ModelManager.swift`:
  ```swift
  @MainActor final class ModelManager: ObservableObject {
      @Published private(set) var isReady: Bool            // selected model loaded & usable
      @Published var selectedModelID: String               // persisted (UserDefaults)
      // download / delete / load, per-model status + progress (your design)
      func transcribe(_ samples: [Float]) async throws -> String   // 16 kHz mono, returns trimmed text
  }
  ```
- `SettingsView.swift`, `MenuBarView.swift` — model list (download/progress/delete/select),
  shortcut recorders `KeyboardShortcuts.Recorder("Push to talk", name: .pushToTalk)` and
  `.toggleToTalk`, permission status rows using `Permissions`, language picker optional.

### Input/Output (audio, hotkeys, insertion, permissions, packaging)
- `HotkeyManager.swift` — defines
  ```swift
  extension KeyboardShortcuts.Name {
      static let pushToTalk: Self    // default: none or ⌥Space-ish, your call
      static let toggleToTalk: Self
  }
  ```
  and wires onKeyDown/onKeyUp to callbacks.
- `AudioRecorder.swift` — start/stop capture, returns `[Float]` at 16 kHz mono.
- `TextInserter.swift` — paste text into the frontmost app, restore clipboard.
- `Permissions.swift`:
  ```swift
  enum Permissions {
      static var microphoneGranted: Bool { get }
      static func requestMicrophone() async -> Bool
      static var accessibilityGranted: Bool { get }
      static func promptAccessibility()          // AXIsProcessTrustedWithOptions prompt
      static func openAccessibilitySettings()
      static func openMicrophoneSettings()
  }
  ```
- `DictationController.swift`:
  ```swift
  @MainActor final class DictationController: ObservableObject {
      enum State: Equatable { case idle, recording, transcribing, error(String) }
      @Published private(set) var state: State
      init(modelManager: ModelManager)
      func start()          // register hotkeys; idempotent
  }
  ```
  Orchestrates hotkey → record → `modelManager.transcribe` → `TextInserter`. Ignores hotkeys
  (with a brief error state) if `!modelManager.isReady`. Very short recordings (<0.3 s) are dropped.
- `Resources/Info.plist` (bundle id `com.local.voiceapp`, `LSUIElement`, `NSMicrophoneUsageDescription`,
  min OS 14.0), `scripts/build-app.sh`.
