# VoiceApp — spec

A local macOS menu-bar app (Apple Silicon, tested target: MacBook Pro M1 Pro, macOS 14+).
Its whole job:

1. List a handful of open-source speech-to-text models that run well on an M1 Pro.
2. Let the user pick one; download it on demand (with progress), delete it, switch between them.
3. Let the user set two global shortcuts:
   - **Push-to-talk**: record while held, transcribe on release.
   - **Toggle-to-talk**: press once to start, press again to stop and transcribe.
4. Capture the target app after transcription and paste only if it remains frontmost; otherwise copy to clipboard.
5. Save dictations locally by default, with a history window for search, copy, and deletion.
6. Apply a local custom dictionary (`Settings → Dictionary`) to correct terms and aliases before pasting.
7. Optionally pass dictionary-corrected transcripts once through the user's Anthropic or OpenAI model (`Settings → Correction`) before pasting, without ever blocking dictation on the network.

Speech recognition runs entirely on-device with no VoiceApp account. Optional cloud post-correction uses only the user's own API key when enabled.

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
  Audio is not retained. A dictation delivered while saving is enabled remains queued when the setting
  is turned off; dictations delivered from then on are not saved. Existing history is kept.
- The menu's latest three dictations survive relaunch with history enabled. **Clear recent** only hides
  the menu list for the current launch; new dictations still appear. The menu explains whether new
  dictations are saved on this Mac and points to Settings → Behavior. Only the history window deletes records.
- **History…** opens a window on demand, styled with `Theme.swift`. Search is debounced by 250 ms and uses
  the store's last-token prefix matching. Results are newest first, initially 100 with **Load more**, showing
  date, app name, and up to three lines of final text. Copy copies the full transcript. Every delete,
  including the Delete key, requires confirmation with a count; selected records use one batch delete.
  **Delete all…** removes saved or queued dictations before confirmation, irrespective of search or
  pagination. Later deliveries survive. Deletes join the save queue and run off the main thread with
  busy/error states. Application termination, including menu Quit, logout, and updater relaunch, waits
  for an in-flight transcription, pending cloud corrections and their saves, and queued saves/deletes within one 30-second deadline,
  then proceeds even if work remains. While waiting,
  the menu shows that it is finishing history work, disables Quit, and ignores a second menu Quit request.
  A delete unfinished at the deadline is not applied, and nothing reports it on the next launch. A delete
  that fails during the wait cancels quitting and brings History forward with the error. Dictation and paste
  remain responsive after cancellation. While quitting, new recordings are ignored and paste may be
  skipped, but the completed dictation still joins the save queue. Force quit, crashes, and forced shutdown
  cannot wait. Copy is supported; re-paste is outside this slice.
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
`addTerm` and `updateTerm` trim leading and trailing whitespace on term text and aliases, drop blank
or self-matching aliases, collapse duplicate aliases within a term, and enforce `DictionaryTerm.maximumLength`
(`100` characters and `100` Unicode scalars per value) before validating and saving. Edits advance the per-term clock and record the current `deviceID`;
deletion clears text and aliases and retains a terminal tombstone for future last-writer-wins sync.
Listing returns live terms in UUID order. Empty or whitespace-only text is rejected. Two live terms
cannot share a canonical spelling or alias under Unicode case folding and whitespace normalization;
conflicts identify the value and owning term.

`CorrectionMatcher` prebuilds the trie (stripping edge whitespace on terms and aliases, skipping any term text
or alias exceeding `DictionaryTerm.maximumLength`) and exposes
`correct(_:)` so `UserDictionary` can reuse the in-memory matcher across dictations without store I/O,
rebuilding off the main actor only when terms load or change. `correctText(_:terms:)` constructs a
matcher and runs `correct(_:)`. Matching is case-insensitive on canonical spellings and literal aliases,
with any whitespace run between words. Unicode letters, marks, numbers and connector punctuation are
word characters; apostrophes and hyphens joining word characters prevent a boundary, while surrounding
quotes and punctuation allow one. Longer input matches win globally; ties use input position, term UUID,
then canonical UTF-8 spelling. Exact canonical matches make no replacement entry.

The pass repeats until unchanged, up to eight passes, with a final convergence check. Output growth is
limited to 1,048,576 UTF-16 units beyond the input. The default thread-CPU budget is
`CorrectionMatcher.defaultTimeBudget` (`50 ms`) plus `10 ms` per complete 1,000 input UTF-16 units;
scheduler preemption does not consume it. Explicit `timeBudget` overrides this scaling (`nil` disables
the CPU deadline). Candidate collection is capped at 32,768 per pass, retaining shorter alternatives
needed by global longest-match selection. Trie traversal, candidate collection, sort comparisons,
range selection, pass construction and merged-range reporting poll the deadline cooperatively.
Exceeding the growth budget stops before applying that pass. Reaching the candidate cap or observing
an expired CPU deadline discards all work and returns raw `text` (`timedOut == true`). This bounds
matcher work, not elapsed wall time: scheduling and individual allocation/string operations can delay return.
`converged == false` reports an unfinished correction at any limit; idempotence is guaranteed only
when converged. Chained edits merge overlapping original ranges, retaining the original substring, final
replacement and last applied term UUID. Ranges are UTF-16 offsets in the original input; adjacent chains
stay separate unless a later edit joins them. Bytes outside those ranges are preserved exactly.

`App.swift` shares one `SQLiteHistoryRepository` between `DictationHistory` and `UserDictionary`.
`DictationController` delegates non-speech filtering, synchronous `dictionary.correct(_:)` correction,
and `DictationHistory` delivery to `DictationDelivery` in `VoiceAppCore`, saving both the raw transcript
(`rawText`) and corrected text (`finalText`) in `CompletedDictation`. If the dictionary store fails to open
or load (for example due to a held lock), `UserDictionary` logs the cause, displays the status and retry state
in **Settings → Dictionary**, keeps dictation pasting raw text immediately, and retries loading automatically with
backoff as well as on the next dictation or manual Retry. **Settings → Dictionary** lists terms, flags any legacy
entries exceeding `DictionaryTerm.maximumLength` in characters or Unicode scalars. Oversized canonical text
skips the whole entry; oversized aliases alone skip only those aliases, as stated by the row badge and banner.
Settings supports adding and editing canonical text and comma-separated aliases,
reports dropped self-matching aliases, deletes with confirmation, searches when 8 or more terms exist,
and displays store validation errors in plain English. Number formatting, acoustic boosting, and sync remain
separate.

## Cloud correction

`DictationDelivery` runs `transcription → dictionary pass → cloud correction → paste` exclusively on `RecordKind.dictation` (voice notes bypass cloud correction, retain NULL cloud metadata, and save without pasting). Cloud correction is off by default and runs only when enabled in **Settings → Correction**, an API key is readable without UI interaction for the selected provider, and the frontmost app bundle ID is not in the exclusion list (empty by default). One task covers transcription, correction and paste. `DictationSessionCoordinator` stays busy until delivery finishes; no FIFO tickets or concurrent-delivery task map remain. Only when a cloud request will actually be sent does `DictationSessionCoordinator` enter `.correcting`, showing “Correcting…” in the menu and icon help and playing Basso on busy shortcut presses (when feedback sounds are enabled), including note shortcuts. When cloud correction does not send a request, delivery remains in `.transcribing` with silent busy presses. Quit drains that same task and the existing store write tail. Immediately before posting paste (after modifier release), `TextInserter` compares the captured process ID with the frontmost process ID. A changed or unknown target leaves text on the clipboard, throws the existing style of fallback notice, and stores the history destination as appName `Clipboard` with no bundle ID.

- **Non-blocking deadline & circuit breaker:** `CloudCorrectionService` reads the Keychain item off the main actor (`LAContext.interactionNotAllowed = true`) and runs the provider request inside a single constant wall-clock deadline (`CloudCorrectionConfig.requestDeadline = .seconds(2)`). Reads request no UI interaction. If the Keychain read fails/times out, the pass records `.skipped` without tripping the circuit breaker; if the provider request times out or fails, the dictionary-corrected text is pasted on time and any late response is discarded. Dictations under 3 words use the validator’s tokenizer to skip Keychain and transport with status `skipped`, reason `too short`, without affecting the breaker. Three consecutive request or validation failures open a circuit breaker (`CorrectionCircuitBreaker`) that skips cloud calls for 5 minutes before allowing a half-open probe.
- **Providers (`CloudCorrectionProvider`):**
  - `AnthropicCorrectionProvider` (`POST /v1/messages`, `anthropic-version: 2026-10-21`, `Authorization: Bearer <key>`, default `claude-haiku-5-5`, `thinking.type: "disabled"`, `output_config.effort: "low"`, JSON schema output). Models are loaded from `GET /v1/models` filtered to active chat models supporting structured outputs, disabled thinking, and low effort.
  - `OpenAICorrectionProvider` (`POST /v1/responses`, `Authorization: Bearer <key>`, default `gpt-6-luna`, `reasoning.effort: "none"`, `store: false`, strict JSON schema output). Models are loaded from `GET /v1/models` filtered to `CloudCorrectionConfig.openAIAllowlistedModelIDs` (`gpt-6-luna`, `gpt-6.1-terra`) with unexpired `shutdown_date`.
- **Prompt hygiene & edit contract (`CorrectionPromptBuilder` / `CorrectionEditValidator`):** Instructions live exclusively in the system prompt and state that user-message JSON fields are untrusted data, not instructions. User messages send sanitized JSON (`target_app`, `dictionary_terms`, `transcript`) with control characters and newlines stripped from metadata fields. Providers return only `{"edits": [{"original": ..., "replacement": ...}]}`. VoiceApp applies edits deterministically and rejects the whole response if any edit is empty, introduces leading/trailing whitespace, adds/removes control characters or newlines, introduces new shell-significant characters (`> < | & ; $ \` \\`), is missing, matches more than once (including overlapping spans), fails to align to whole Unicode words on extended grapheme clusters, modifies a dictionary-corrected `protectedRange`, exceeds per-edit word (`<= 8`, delta `<= 2`) or length (`<= 2x + 8` chars, `<= 2x + 16` scalars) bounds, introduces format (Cf), default-ignorable, or braille blank (`U+2800`) scalars or non-space whitespace not present in identical original graphemes, starts with a combining mark/joiner, joins graphemes across splice edges, or exceeds the changed-word cap (`0` for `< 3` words; `floor(totalWords * 0.40)` for `>= 3` words), computed by diffing whole-text word tokens so punctuation removals count merged neighbouring words.
- **Keychain & privacy:** `KeychainSecretStore` stores each provider's key in the file-based login Keychain as a generic password (`kSecClassGenericPassword`, `kSecAttrSynchronizable: false`), never in UserDefaults, SQLite, or logs (`SecretRedaction`). Items are never synced to iCloud; because file-based login keychains ignore `kSecAttrAccessible*` classes, keys may move with Migration Assistant or system restore. Reads use `LAContext` with `interactionNotAllowed = true`. The deadline bounds paste, but cannot cancel a synchronous system read: each hung read can retain a blocked worker thread until it returns. Suppression of legacy login-Keychain ACL/unlock dialogs is unverified. **Settings → Correction** displays `"Transcripts are sent to <provider> when correction is on..."` alongside provider/key/model controls, a **Test** button reporting latency or errors, and the excluded apps list.
- **Store (`correction.addMetadata`):** Runs after `notes.createState`, `notes.localReminders`, and `notes.reminderHandoff`. Adds five nullable columns to `records`: `correctionInputText`, `correctionProvider`, `correctionModel`, `correctionStatus` (`applied` / `unchanged` / `fallback` / `skipped`), and `correctionReason`. `MemoryStore.delete(ids:)` clears all five columns to `NULL` on tombstoning, enforced by `records_correction_tombstone_insert` and `records_correction_tombstone_update` triggers.

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
- `App.swift` — `@main struct VoiceApp: App`. Creates the single `ModelManager`, shared
  `SQLiteHistoryRepository`, `DictationHistory`, `UserDictionary`, and
  `DictationController(modelManager:history:dictionary:)`, calls `dictation.start()` once at launch,
  shows `MenuBarExtra` whose icon reflects `dictation.state`, and a settings window.
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
  `.toggleToTalk`, permission status rows using `Permissions`, language picker optional, and
  **Dictionary** management.

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
      enum State: Equatable { case idle, recording, transcribing, correcting, error(String) }
      @Published private(set) var state: State
      init(modelManager: ModelManager, history: DictationHistory, dictionary: UserDictionary)
      func start()          // register hotkeys; idempotent
  }
  ```
  Orchestrates hotkey → record → `modelManager.transcribe` → `TextInserter`. Ignores hotkeys
  (with a brief error state) if `!modelManager.isReady`. Very short recordings (<0.3 s) are dropped.
- `Resources/Info.plist` (bundle id `com.local.voiceapp`, `LSUIElement`, `NSMicrophoneUsageDescription`,
  min OS 14.0), `scripts/build-app.sh`.


## Voice notes and manual reminders (Part of #3)

- Separate configurable `notePushToTalk` and `noteToggle` key combinations start unbound.
  Settings rejects a key combination assigned to any other recording action in either direction,
  shows a plain message, and restores the previous value.
  A recording retains its destination until transcription finishes; other shortcuts cannot end it.
  Notes record the app active at recording start and never call text insertion or mutate the clipboard.
  Transcripts go through `DictationDelivery` filtering and dictionary correction before note delivery,
  retaining immutable raw and corrected text just like dictation history.
- The Notes window lists notes newest first, searches current edited text (last word prefix),
  paginates, copies, edits, marks done/undone, and confirms deletion.
- Original `.note` records remain immutable. `noteState` holds current text, done state,
  and the reminder (due date and state); FTS indexes current text. Deletion removes this state and its index,
  and scrubs the original record into a tombstone. Editing preserves the original transcript locally.
- Notes reuse `DictationHistory`, its ordered write tail, `SQLiteHistoryRepository`, and
  `HistoryTermination`. Note saves ignore the dictation-history opt-out. Save success flashes a
  menu-bar checkmark; failures appear in Notes and the menu. Capture never waits for store I/O.
- Remind me is manual: pick date and time, save `noteState.reminderDate`, then schedule a
  VoiceApp notification through UserNotifications. Notes and reminders live only inside VoiceApp;
  no other app receives them. No external-app integration or automatic date detection is included.
- `NoteReminderScheduler` uses a `NoteNotificationCenter` protocol. Notification IDs derive from
  the note UUID and the due time (`voice-note.<uuid>.<due in ms>`), so a notification in Notification
  Center proves only that this due time was alerted, never an earlier one the reminder was moved from.
  Changing the date makes the old ID an orphan, which reconciliation removes. Future requests replace
  rather than accumulate. Authorization is requested only when
  setting a reminder or explicitly refreshing unasked authorization, never at launch or on time-zone
  changes. The window distinguishes not asked yet from turned off. Denial keeps the due date and
  exposes notification settings.
- Every reminder has one explicit state, saved with its note as `noteState.reminderDate` (the due time)
  and `noteState.reminderPhase` (`notes.reminderState` replaces the two timestamps `reminderNotifiedAt`
  and `reminderScheduledFor` and backfills the phase from them). `ReminderStateMachine` is a pure
  function `next(state, event)`; the persisted state is the only source of "was this alerted?".
  Nothing is inferred at check time from Notification Center contents, from the authorization at that
  moment, or from comparing clocks to timestamps.

  States: `scheduled(d)` (set, no request with macOS), `handedToMacOS(d)` (a request for `d` was added),
  `missed(d)` (`d` passed with no request with macOS: one catch-up owed), `alerted(d)` (final for `d`).

  | event \ state       | idle | scheduled(d)  | handedToMacOS(d) | missed(d)     | alerted(d) |
  |---------------------|------|---------------|------------------|---------------|------------|
  | set(n)              | sch n| sch n         | sch n            | sch n         | sch n      |
  | remove, done, delete| idle | idle          | idle             | idle          | idle       |
  | edit                | idle | same          | same             | same          | same       |
  | timeReached(t)      | idle | t≥d: missed   | t≥d: alerted     | same          | same       |
  | requestAdded(x)     | idle | x=d: handed   | same             | same          | same       |
  | requestWithdrawn(x) | idle | same          | x=d: scheduled   | same          | same       |
  | delivered(x)        | idle | x=d: alerted  | x=d: alerted     | x=d: alerted  | same       |
  | catchUpPosted(x)    | idle | same          | same             | x=d: alerted  | same       |

  Events naming a due time apply only to that due time, so a late callback for a time the reminder
  moved away from changes nothing. `delivered` is the `willPresent`/click callback, matched through the
  due time in the notification ID. A state leaves `alerted` only through `set` or removal, so a clock
  set back never schedules an alerted due time again. Every `set` starts over, including a set to the
  same instant: that is a new alert. The table is covered cell by cell by `ReminderStateMachineTests`.
- Authorization decides only whether a request can be added or a catch-up posted right now. It never
  changes a state. A request that was with macOS when its due time passed is `alerted`, even if
  notifications were off at that moment: macOS showed nothing then, and a later look cannot tell that
  from "shown and cleared", which is what made earlier rules alert twice or never. The reminder stays
  overdue in Notes. A reminder that was never with macOS because notifications were off when it was set
  is `missed` and gets its catch-up when VoiceApp next looks with notifications on.
- `ReminderPlan` (pure) turns the states into work for the notification center: the nearest 60
  not-yet-alerted reminders (ordered by due time, then ID) are in the window; a `scheduled` one in the
  window gets a request, a `handedToMacOS` one only if the request went missing or its note changed;
  a handed one outside it is withdrawn; `missed` ones are owed a catch-up when authorized; `nextWake`
  is the earliest due time of a reminder that is not yet alerted. `NoteReminderScheduler` only executes
  the plan and feeds the results back as events: remove orphans, apply `timeReached`, withdraw, hand
  over, post catch-ups (one summary for several; "were due while VoiceApp was closed" only for the
  launch reconcile, "are due" otherwise). Each transition is saved with a compare-and-set on the
  state it was decided from (`transitionNoteReminder`).
- Reconciliation reads only notes that carry a reminder and re-submits a request only when it is
  missing, was never handed off, or its note changed (all of them on a time-zone or clock change, or
  Refresh notifications). Edits, done, delete and Remove reminder on a note without a reminder never
  touch the notification center.
- A single `ReminderTimer` is armed for `nextWake` plus one second after every reconcile, whether or not
  notifications are on, and cancelled only when nothing is waiting. When it fires, a reconcile applies
  `timeReached`, tops up the 60-request window and posts owed catch-ups. Delivery callbacks
  (`willPresent`, click) apply `delivered` and run the same reconcile. `NSWorkspace.didWakeNotification`
  reconciles too, so a Mac asleep over a due time catches up on wake. A catch-up owed while
  notifications are off waits for the next reconcile with notifications on (the next due time, wake,
  Refresh, launch); VoiceApp does not poll the settings.
- All reminders remain in Notes beyond the scheduling cap. Launch, changes, and delivery refill slots.
  Requests use non-repeating calendar-date triggers built from the due date in the current time zone;
  the second repeated DST hour uses its matching UTC offset to preserve the chosen instant.
  Due times round up to whole seconds (never early); one less than two seconds away uses a
  time-interval trigger so it cannot miss its second. `NSSystemTimeZoneDidChange` and
  `NSSystemClockDidChange` reschedule without asking for authorization.
- Settings shows a duplicate shortcut that an earlier build saved, on both recorders, and never
  disables either silently. It follows changes through the recorders' public `onChange` callback.
- Notes show due/overdue state live and support a reminder-only filter. Notification clicks clear
  search/filter state, load the target even outside the first page, and select/reveal it in Notes.
- Edits replace pending notification text. Remove reminder, done, and delete cancel pending and
  delivered notifications. Marking done also clears the stored reminder; marking undone does not restore it.
- Store writes precede notification effects. Notification failure leaves the reminder in Notes with
  retry advice. Launch repairs interrupted scheduling; a crash between notification handoff and saving
  its state can repeat an alert. Setting the clock back within a second after a reminder fired (before
  the timer noted it), or while VoiceApp is closed, can repeat it. OS notification settings and Focus
  can suppress visible alerts.
  The first authorization dialog currently holds the ordered store queue until answered; paste does
  not wait for this queue. This is a known tradeoff.
