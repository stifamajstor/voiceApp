# VoiceApp

On-device dictation for macOS. Hold a shortcut, speak, and release to paste the transcript into the focused app. VoiceApp lives in the menu bar and supports Whisper and NVIDIA Parakeet models running locally through Core ML.

- Push-to-talk and toggle-to-talk, with configurable key combinations and single modifier keys.
- Download, switch, and delete speech models from Settings.
- Multilingual transcription with automatic language detection or a Whisper language hint.
- Clipboard restoration after automatic paste, with a manual-paste fallback.
- Local dictation history with search, copy, and deletion.
- Custom dictionary in Settings to replace spoken aliases and mishearings before pasting.
- Voice notes with separate shortcuts, editing, done state, and in-app reminders.
- Optional cloud correction in Settings using your own Anthropic or OpenAI API key (off by default).
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
| Note — push to talk, key combination | None | Hold to record a note; release to save without pasting |
| Note — toggle, key combination | None | Press to start a note; press again to save without pasting |

Both the key combinations and modifier keys are configurable in Settings. A key combination already assigned to another recording action is rejected with a message and the previous value is kept. If ⌥Space conflicts with a launcher, record another combination. Key combinations work without Accessibility permission; single modifier keys require it when used outside VoiceApp.

Modifier push-to-talk has a short hold delay. Combining that modifier with another key cancels the recording so ordinary Option-character typing does not produce a transcript. If both modifier actions use the same key, push-to-talk takes precedence.

Recordings shorter than **0.3 seconds** are discarded. Recording stops automatically after **5 minutes**. Additional shortcuts are ignored while local transcription is running; once local transcription finishes, a new recording can start while cloud correction finishes in the background (pastes remain FIFO-ordered).

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

Cloud post-correction is off by default. When you enable it and add an API key, VoiceApp sends the dictionary-corrected transcript, your dictionary term names, and the target app name over HTTPS to the provider you selected (unless the focused app is excluded). OpenAI requests set `store: false` (abuse-monitoring logs may still be kept for up to 30 days); Anthropic does not retain prompts or outputs by default or train on API traffic (flagged content may be retained). API keys live in your login Keychain (`kSecClassGenericPassword`, non-synchronizable — never synced to iCloud, though file-based login keychain items ignore accessibility classes and may transfer with Migration Assistant) and are never stored in UserDefaults, the history database, or logs.

| Permission | Purpose |
|---|---|
| Microphone | Record audio while dictation is active |
| Accessibility | Send the paste keystroke and observe modifier-only shortcuts globally |
| Notifications (requested on first reminder) | Show VoiceApp reminders when due |

Automatic paste temporarily places the transcript on the system clipboard. VoiceApp restores the previous clipboard contents after about **0.5 seconds**, unless another app or you changed the clipboard in the meantime. It marks automatic-paste entries as transient for clipboard managers that honor `org.nspasteboard.TransientType`; other managers may retain them.

Without Accessibility, the transcript stays on the clipboard and the menu reports **Copied to clipboard — grant Accessibility to auto-paste**. Paste it yourself with **⌘V**.

## Dictation history

**Save dictation history** is on by default in **Settings → Behavior**. Completed transcriptions,
including clipboard-only fallback, are stored locally in
`~/Library/Application Support/VoiceApp/store/store.sqlite`. Records include the raw and final text,
date, target app, selected model, and recording duration. Recording audio is not retained.
The database contains readable text; it is not encrypted by VoiceApp.

Open **History…** from the menu to search, copy, or delete dictations. Results are newest first;
the last search word matches prefixes. **Load more** shows results beyond the first 100.
Use **⌘-click** or **⇧-click** to select several rows, then **Delete selected** or press Delete.
Every deletion asks for confirmation with the number of dictations to remove and is permanent.
**Delete all…** includes dictations outside the current search and those queued before confirmation;
dictations delivered after confirmation survive. Rows preview up to three lines; Copy copies the full text.
Search and deletion run in the background with a busy indicator; large deletes can take seconds.
Quitting from the menu or through macOS application termination (including logout and updater relaunch)
waits for an in-flight transcription, cloud corrections and their saves, plus queued saves and deletes, within one 30-second
deadline, then proceeds even if work remains. New recordings are ignored while quitting; dictation paste
may be skipped, but its history save still runs. While
waiting, the menu says it is finishing history work, disables Quit, and ignores a second menu Quit request.
A delete unfinished at the deadline is not applied, and nothing reports it on the next launch. A delete
that fails during the wait cancels quitting and brings History forward with the error; new dictations
can then run again. Force quit, a crash, or a forced system shutdown cannot wait.
Copy a transcript and paste it into the intended app yourself.

The menu keeps the latest three transcripts across relaunches when history is enabled. **Clear recent**
hides the menu's current list for this launch; it does not delete stored history. New dictations still appear.
A dictation delivered while history is on is saved even if you turn it off while paste or storage is
waiting. Turning history off stops saving dictations delivered from then on and stops loading saved
records into the menu; existing records stay available in History. The menu explains the current saving
setting and points to Settings → Behavior. An unavailable store or a failed latest save is disclosed as
not saving; a successful save restores the saved disclosure.
If the store cannot open or a save fails, Settings → Behavior shows recovery advice,
and dictation and paste continue. Recent transcripts remain available in memory for this launch.

## Custom dictionary

Add terms and optional comma-separated aliases in **Settings → Dictionary** (for example,
`Mac` with aliases `MEC, Meg`). Before pasting, VoiceApp replaces matching whole words
case-insensitively using an in-memory matcher rebuilt only when the dictionary changes, so
correction adds no store I/O to dictation or paste. Voice notes use the same correction before saving,
keeping both the raw transcript and corrected text without pasting.

Leading and trailing whitespace is trimmed from term text and aliases, and blank aliases are
dropped. Duplicate terms or conflicting aliases are rejected with plain-English messages.
Deleting a term asks for confirmation. When the dictionary has 8 or more terms, a search
field filters by term or alias.

Terms are stored locally in the same `~/Library/Application Support/VoiceApp/store/store.sqlite`
database as dictation history. History records keep both the raw transcript and the corrected text,
and history search matches both. If the dictionary cannot be loaded, VoiceApp logs the cause,
shows a warning in **Settings → Dictionary**, and pastes the raw transcript.

## Voice notes

Use **Notes…** in the menu to find voice notes. Configure **Note — push to talk** or
**Note — toggle** in Settings → Shortcuts; both start unbound. Notes are saved locally even
when dictation history is off, and never pasted or placed on the clipboard automatically.

Notes show the app active when recording began. Search, copy, edit, mark done, or delete with
confirmation. **Remind me…** stores a date and time on the note and schedules VoiceApp's own
macOS notification. Clicking it opens that note. **Remove reminder**, marking done, and deletion
cancel the notification. Editing updates its text. Notes show due/overdue dates and can filter to
notes with reminders. No dates are detected automatically. Notes and reminders stay inside VoiceApp.

Notification permission is requested when you first set a reminder, or when you choose
**Refresh notifications** if permission has not been asked yet. Launch never asks. Notes distinguishes
unasked permission from notifications turned off. If denied, the reminder stays in Notes with a link
to VoiceApp's notification settings. After enabling notifications, use **Refresh notifications**.
Notification previews may show note text according to macOS settings.

The original transcript stays immutable. A local `noteState` side table holds current edited text,
done state, due date, successful OS handoff for that due date, and an alerted timestamp. Note deletion
scrubs both the transcript
and side state, retaining only the record tombstone. Notes share the history store actor and ordered
write queue, including quit draining. Future notifications are restored on launch using a stable ID
per note, using calendar-date triggers in the current time zone, with repeated DST hours disambiguated.
Time-zone changes reschedule future requests. Only the nearest 60 future reminders are scheduled;
all others remain in Notes. Delivery and changes refill available slots. At launch, a due reminder
successfully handed to macOS is treated as delivered, even after a click or Clear All. Only never
scheduled reminders get a catch-up alert; multiple missed reminders produce one count summary.
The alerted timestamp prevents repeated catch-ups; reminders remain overdue until removed or done.
SQLite and the notification service cannot commit atomically; launch reconciliation repairs pending
requests after interruption. A crash between notification handoff and its timestamp save can repeat
an alert. Focus and OS settings
can suppress visible delivery. The first permission dialog currently holds the ordered store queue
until answered; dictation paste remains independent of that queue.

## Cloud correction

Enable **Correct dictations with a cloud model** in **Settings → Correction** to pass each
dictionary-corrected dictation once through your own **Anthropic** (`claude-haiku-5-5` default,
Messages API with thinking disabled and low effort) or **OpenAI** (`gpt-6-luna` default,
Responses API with `reasoning.effort: "none"` and `store: false`) model before pasting.

- **Non-blocking deadline & Keychain reads:** Reading the API key from Keychain (`interactionNotAllowed`) and the network request both run off the main actor under a single 2-second wall-clock deadline (`CloudCorrectionConfig.requestDeadline`). If Keychain access would require UI, the request fails, or the deadline expires, VoiceApp pastes the dictionary-corrected text on time and discards any late response. VoiceApp lets new recordings start as soon as local transcription finishes while earlier cloud corrections finish and paste in submission order.
- **Circuit breaker:** After 3 consecutive request or validation failures, cloud correction pauses for 5 minutes and falls back to dictionary text without network calls.
- **Structured edit contract:** Models receive system instructions explicitly separating untrusted JSON user-message data (`target_app`, `dictionary_terms`, `transcript`) and return only targeted `{original, replacement}` edits via JSON schema, never a full rewrite. VoiceApp applies edits deterministically on whole Unicode words and extended grapheme clusters, protects dictionary-replaced words, rejects control characters/newlines, leading/trailing whitespace changes, or new shell characters (`> < | & ; $ \` \`), rejects ambiguous or overlapping spans, bounds per-edit length/word expansion, and requires dictations to have at least 3 words while capping changed words at `floor(totalWords * 0.40)`.
- **Models and testing:** Settings populates the model picker from each provider's `GET /v1/models` endpoint (OpenAI is filtered to a short allowlist of fast `reasoning.effort: "none"` models: `gpt-6-luna`, `gpt-6.1-terra`) and includes a **Test** button that sends a short sample and displays latency or errors in plain words.
- **App exclusions and history:** Excluded apps (chosen from running apps or entered by bundle ID; empty by default) never send transcripts to the cloud. Voice notes (`RecordKind.note`) never run through this dictation pass; they save dictionary text with NULL cloud metadata and do not wait for pending dictation pastes. History records keep the text before and after the model along with provider, model, outcome status, and any fallback or skip reason.

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
| `Sources/VoiceAppCore/` | SQLite store, background history repository, dictation delivery, custom dictionary and text correction, cloud correction providers and Keychain wrapper, search and deletion state |
| `Tests/VoiceAppCoreTests/` | Store, history, dictionary, text correction, and cloud correction tests |
| `ModelCatalog.swift`, `ModelManager.swift`, `ParakeetEngine.swift` | Model catalog, downloads, loading, and transcription |
| `DictationController.swift`, `AudioRecorder.swift` | Dictation state and microphone capture |
| `HotkeyManager.swift`, `ModifierHotkey.swift` | Global shortcuts |
| `TextInserter.swift`, `Permissions.swift` | Clipboard insertion and macOS permissions |
| `SettingsView.swift`, `MenuBarView.swift`, `HistoryView.swift`, `Theme.swift` | Settings, menu bar, and history interface |
| `Updater.swift` | Sparkle self-updates |
| `Resources/` | App metadata and icon |
| `scripts/` | App bundle, DMG packaging, and releases |

Bare Swift filenames in this table live under `Sources/VoiceApp/`. The build script adjusts generated SwiftPM resource accessors and copies dependency bundles into `Contents/Resources`, so the packaged app does not depend on the source checkout's `.build` directory.

`MemoryStore` defaults to `~/Library/Application Support/VoiceApp/store/store.sqlite`; tests inject temporary directories. It stores immutable records with string-backed kinds (including dictation, note, and prompt), indexes raw/final text with FTS5, and preserves payload-free deletion tombstones. Unknown kinds round-trip unchanged. SQLite rejects noncanonical record/device UUIDs, non-text kinds, nonnumeric deletion timestamps, nonpositive rowids, replacement inserts, and physical row deletion.

Callers can supply an optional 1–10 character ASCII alphanumeric audio extension; the store derives `audio/<record UUID>.<lowercase extension>`. Use `audioURL(for:)` to get the file location and create its parent directory before writing audio. Deletion removes the file or symlink itself without following symlinks, skips stored paths the store could not have produced, tolerates unexpected filesystem objects, and leaves the record live if its audio file cannot be removed; in a batch, the other records also stay live even if some of their audio is already removed, and a retry finishes the job.

Search treats the last word as a prefix and breaks timestamp ties by insertion order. Connections wait up to five seconds for another writer; a database-local file lock serializes migrations and fails with `StoreError.migrationLockTimeout` after five seconds of contention.

Connections enable `PRAGMA secure_delete = ON`. Every delete transaction rebuilds FTS to remove deleted terms and page-index prefixes on every SQLite version. Use `delete(ids:)` to tombstone a batch with one rebuild. Rebuilding costs more as history grows; it removes deleted text from store files after close, excluding filesystem snapshots and backups.

The app opens one store on a background actor. Dictation never waits for history I/O. The history coordinator lives in `VoiceAppCore` so delivery, preferences, debounce, stale-result rejection, and delete state can be tested without launching the app. Connections set FULL auto-vacuum only on an empty database, so reopening an existing store needs no write lock.

GitHub Actions runs `swift build` and `swift test` on pull requests and pushes to `main`, using macOS 26 and Xcode 26.2 (Swift 6.2). Before shipping a change, also check the packaged app's model download/load, both dictation modes, permissions, actual transcription, paste into another app, and clipboard restoration. Core tests and signature verification alone do not prove those flows.

[SPEC.md](SPEC.md) contains the original design and implementation contracts. For current shortcuts, dependencies, and packaging behavior, follow this README and the source.
