# VoiceApp — spec

A local macOS menu-bar app (Apple Silicon, tested target: MacBook Pro M1 Pro, macOS 14+).
Its whole job:

1. List a handful of open-source speech-to-text models that run well on an M1 Pro.
2. Let the user pick one; download it on demand (with progress), delete it, switch between them.
3. Let the user set two global shortcuts:
   - **Push-to-talk**: record while held, transcribe on release.
   - **Toggle-to-talk**: press once to start, press again to stop and transcribe.
4. Paste the transcribed text into whatever app is focused.
5. Save dictations locally by default, with a history window for search, copy, and deletion.

Everything runs on-device. No accounts, no cloud.

## Stack

- Swift Package (`Package.swift`): executable `VoiceApp` (`Sources/VoiceApp/`), plain logic library
  `VoiceAppCore` (`Sources/VoiceAppCore/`), and `VoiceAppCoreTests` (`swift test`).
- `VoiceAppCore.MemoryStore` uses GRDB/SQLite with FTS5 under
  `~/Library/Application Support/VoiceApp/store/store.sqlite` (directory injectable for tests).
  Immutable records carry canonical uppercase, hyphenated record/device UUIDs and a persisted install ID.
  Only live-to-tombstone updates are allowed; tombstones are terminal, rowids positive, and physical deletion
  and replacement inserts forbidden. Backfill/purge migrations must drop and recreate the protective triggers.
  Duplicate inserts fail with `SQLITE_CONSTRAINT_TRIGGER`; sync must not rely on a primary-key error code.
  Kinds are text-backed values with dictation/note/prompt constants; unknown kinds round-trip for future sync.
  Swift rejects negative or non-finite durations; SQLite requires numeric deletion timestamps.
  Audio paths derive from the UUID and an optional 1–10 character ASCII alphanumeric extension via `audioURL(for:)`.
  Deletion clears payload and audio, retaining only ID/device ID/deletion timestamp. Audio symlinks are never
  followed; malformed paths and unexpected objects do not block tombstoning. File-removal failures preserve
  live records for retry; audio removal and database commit cannot be atomic.
  Connections use a five-second busy timeout and `PRAGMA secure_delete = ON`. A database-local non-blocking
  migration lock has a five-second deadline and throws `StoreError.migrationLockTimeout` on contention.
  Every delete transaction rebuilds FTS on every SQLite version; `delete(ids:)` tombstones a batch with one rebuild.
  A delete rebuilds the index, so its cost grows linearly with the indexed words: with records of about 37 words,
  a single delete takes about 0.2 s at 10,000 records and about 1.1 s at 50,000. Deletes must therefore run off
  the main thread. `PRAGMA auto_vacuum = FULL` is set only when `PRAGMA page_count` is zero, before the first migration, so free pages are truncated on
  every commit and a crash during a delete cannot leave text behind. Deleted text is removed from
  store files after close, excluding filesystem snapshots and backups.
  Named migrations use descriptive feature-qualified names in dependency order, without numbering.
  Search quotes Unicode tokens across raw/final text; only the last token is a prefix. Listing and search
  order by creation time descending, then insertion order descending.
- One background `SQLiteHistoryRepository` opens the app's store at launch. `DictationHistory` coordinates
  delivery, the persisted **Save dictation history** preference (default on), recent items, debounced search,
  pagination, and deletion state in `VoiceAppCore`. Paste never awaits store operations. Open/save failures
  are logged and shown in Settings → Behavior. Completed transcriptions, including clipboard fallback,
  save raw/final text, timestamp, app bundle ID/name captured before paste, selected model ID, and duration.
  Audio is not retained. Turning history off stops new saves without deleting existing history.
- The menu's latest three dictations survive relaunch with history enabled. **Clear recent** only hides
  the menu list for the current launch; new dictations still appear. Only the history window deletes records.
- **History…** opens a window on demand, styled with `Theme.swift`. Search is debounced by 250 ms and uses
  the store's last-token prefix matching. Results are newest first, initially 100 with **Load more**, showing
  date, app name, and final text. Each row has Copy; selected records use one batch delete. **Delete all…**
  requires confirmation and deletes all dictations, irrespective of search or pagination. Searches and deletes
  run off the main thread with busy/error states. Copy is supported; re-paste is outside this slice.
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

## Dictionary

`VoiceAppCore.MemoryStore` stores mutable dictionary terms in `dictionaryTerms` in the same SQLite file
and connection as records, added by the named migration `dictionary.createTerms`. Each term has a UUID,
canonical `text`, `aliases`, UTC `updatedAt`, the persistent install `deviceID`, and optional `deletedAt`.
Edits advance the per-term clock; deletion clears text and aliases and retains a terminal tombstone for
future last-writer-wins sync. Listing returns live terms in UUID order. Empty or whitespace-only text is
rejected. Two live terms cannot share a canonical spelling or alias under Unicode case folding and
whitespace normalization; conflicts identify the value and owning term. Blank aliases are ignored.

`correctText(_:terms:)` is pure and matches canonical spellings and literal aliases case-insensitively,
with any whitespace run between words. Unicode letters, marks, numbers and connector punctuation are
word characters; apostrophes and hyphens joining word characters prevent a boundary, while surrounding
quotes and punctuation allow one. Longer input matches win globally; ties use input position, term UUID,
then canonical UTF-8 spelling. Exact canonical matches make no replacement entry.

The pass repeats until unchanged, up to eight passes, with a final convergence check. Output growth is
limited to 1,048,576 UTF-16 units beyond the input; a pass exceeding that budget is not applied.
`converged == false` reports an unfinished correction at either limit; idempotence is guaranteed only
when converged. Chained edits merge overlapping original ranges, retaining the original substring, final
replacement and last applied term UUID. Ranges are UTF-16 offsets in the original input; adjacent chains
stay separate unless a later edit joins them. Bytes outside those ranges are preserved exactly.
This slice provides no UI, app integration, number formatting, acoustic boosting or sync.

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
  `DictationController(modelManager:history:)`, calls `dictation.start()` once at launch, shows
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
