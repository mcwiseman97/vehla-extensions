# QuickNote

An independent native scratchpad inside Vehla, inspired by [Antinote](https://antinote.io/). Antinote does **not** need to be installed. Your notes live in Vehla's private package directory and never write back to Antinote.

## Use

Open the Dock widget and type. Notes autosave after a short pause and flush when the widget hides or closes. The first run includes five editable tutorials for writing, checklists, calculations, capture and importing. New notes need no name: the first line becomes their title.

- **⌘N** creates a note. **⌘[ / ⌘]** and two-finger horizontal swipes over the editor navigate older/newer notes; passing the newest creates a blank note. Swipes commit once when fingers lift; short or cancelled gestures and scroll momentum do not switch notes. Vertical gestures scroll the note normally. Leaving an empty scratch note removes it.
- **⌘F** opens the search pane. Search Stack, Slots or Void. Return opens the first match, or creates a note from an unmatched query.
- **⌘⇧1** promotes the current scratch note. **⌘D** confirms moving it to **The Void**. Restore from the Void tab; no automatic permanent deletion.
- **Keep** assigns one of nine permanent slots. Occupied slots are protected. Slots never expire; set optional scratch note expiry from the menu (default: Never).
- **⌘S** exports text. The menu also exports Markdown and a complete JSON library backup, copies text, sends a note to Vehla Notes, and opens find/replace (**⌘⇧F**, literal matching with optional case sensitivity).
- The menu adjusts text size and lined paper. Colors follow Vehla's live theme; Dock tile text follows Vehla's contrast preference. Opening or editing a note never copies it or publishes it to Vehla's shared context/Notch; Copy and Send to Vehla Notes are explicit actions.

## Text tools

Type `/` at the start of a line for native command completion (arrow keys and Tab/Return select; Escape dismisses). Supported commands are `/list`, `/math`, `/sum`, `/average`, `/count`, `/code`, `/text`, `/checkbox`, `/bullet`, `/numbered`, `/date`, `/time`, `/new`, `/search`, `/copy`, `/paste`, `/timer`, `/import` and `/export`. Press Return on a completed command to execute it. Timer arguments work as `/timer 5: Tea`. Unknown commands remain literal text.

Start a note with `list`, `math`, `sum`, `average`, `count` or `code`, optionally followed by `: A title`.

Checklists accept `[]`, `[ ]`, `[x]`, `- [ ]` and `- [x]`. Click the checkbox to toggle. List notes keep their first line as the title. Plain nonempty body lines receive implicit checkboxes; numbered/bulleted rows, headings and `//` comments do not. Type `/x` at the end of an item to check or uncheck it; the trigger disappears. Item text and checkbox positions stay stable during ordinary typing. Markdown bullet and numbered markers also continue on Return; a blank item exits the list. Tab/Shift-Tab indent/outdent. Plain text stays the source of truth. Headings, bold, italic, underline, strikethrough and comments get subtle native styling. **⌘B / ⌘I / ⌘U** wrap selected text. Code notes use a monospaced font and preserve pasted indentation. HTTP(S) links are clickable; **⌘Return** opens the link under the caret through Vehla.

Math supports arithmetic, parentheses, powers, percentages (`100 + 15% =`, `50% of 200 =`), variables (`price = 4.5`, then `price * 6 =`), pi, sqrt, abs, ceil, floor, log, log2, sin and cos. End an expression with `=`; results appear inline beside each expression without modifying your text. Answers follow the last visual line when an expression wraps, and the last answers stay visible until recalculation completes. `//` comments are ignored. Supported unit conversions use `10 km to mi =`: m/cm/mm/km/in/ft/yd/mi, g/kg/lb/oz, ml/l/gal (US), s/min/h, and C/F. Currency exchange and arbitrary prose math are not implemented; unsupported expressions explicitly show “Check expression”. Sum/average extract numbers from non-comment lines. Count reports words, characters and lines.

Type `paste` on a line and press Return to start **AutoPaste**. `paste( | )` uses a custom separator. Copies append through Vehla's canonical clipboard history, with a plain-text pasteboard fallback on older hosts. Capture is opt-in and stops on Escape, changing notes, hiding or closing the widget. Paste/drop an image for local macOS Vision OCR. Image file reading and recognition run off MainActor; images are not stored or uploaded.

Type `timer 5: Tea` or `timer 3:30` on a line and press Return to start a **Vehla timer**. Vehla owns countdowns, notifications and their lifetime, including after the popup closes. `timer pomo` starts a 25-minute focus countdown; break cycles remain under Vehla's timer controls. `timer` starts an in-widget stopwatch; `timer p/r/s` pause/resume, restart and stop it. Older hosts without the app bridge show a clear unavailable message for countdowns and Send to Notes.

## Import Notes

Choose **Import Notes** from the menu or footer. The importer detects stable and Setapp installations separately from stored data, so notes left behind after uninstall can still be imported. It reuses this project's existing Antinote database discovery, modern `notes` parser and legacy Core Data `ZNOTE` parser, including UUID blob identifiers, timestamp decoding and deleted-note filtering.

The preview shows note titles, previews and already-imported identities. Select some or all, then Import. Source databases remain read-only; importing again skips existing identities, preserves local edits and keeps duplicates out even after a note moves to the Void. Dates and permanent slots are preserved. A slot collision puts the imported note in the scratch stack. The former reader's silent 1,000-note limit is removed; explicit limits are 50,000 notes, 2 MB per note and 100 MiB of imported note text.

If no app/database/notes are found, tutorials remain available and the import sheet explains the state. **Choose Files** accepts Antinote SQLite/SQLite3/DB backups, UTF-8 `.txt`/`.md` exports, and this widget's JSON backups. No Antinote launch, Accessibility, Automation permission, shell command or database mutation is used by this flow. Container access may require granting Vehla Full Disk Access and restarting Vehla. Choosing readable exported files or a backup is an alternative.

## Storage and lifecycle

`scratchpad.json` and `scratchpad.previous.json` are stored under `context.dataDirectory`. Atomic writes are serialized by a repository actor and stale revisions cannot overwrite newer ones. Corrupt data surfaces an error rather than silently replacing notes with tutorials. **Recover Previous Save** restores the prior valid library; export a backup before intentionally recovering. JSON import merges instead of overwriting.

The plugin retains one model across compact, inline and popup controllers. AppKit drawing, responder routing, pasteboard reads, native panels and brokered host actions stay on MainActor. Filesystem discovery, SQLite reading, import merging, JSON encode/decode, atomic writes, search, calculations, text-style parsing and OCR run on actors or worker tasks. Visibility work is cancelled on hide; accepted saves drain without blocking lifecycle callbacks. Keyboard monitors are removed on detachment and explicitly yield to other text fields. Undo history resets when the selected note changes.

This is a Dock widget, not Antinote binary compatibility. Vehla owns window placement, activation and shortcuts. Separate application windows, global extension hotkeys, iCloud sync, Antinote's JavaScript marketplace, Vim editing, split-screen editing, live currency rates and PDF export are outside this implementation. All exposed controls perform real operations.

## Build and install

macOS 14+, Apple silicon, Swift 6+ with the full Xcode developer tools selected:

```sh
swift test --package-path extensions/quicknote-dock-widget
zsh extensions/quicknote-dock-widget/build.sh
swift run --package-path sdk/swift vehla-swift validate extensions/quicknote-dock-widget/dist/QuickNote
```

On this machine, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` is needed for tests because the selected Command Line Tools installation lacks complete test plugins. The release build uses the native SwiftPM backend, matching the Research widget.

Install `dist/QuickNote` through **Vehla Settings → Store → Install Local Package**, then enable the widget in **Dock Widgets**. Reinstall after rebuilding: Vehla uses its installed copy. Quit and reopen Vehla after updating a previously loaded native bundle; in-process modules remain loaded until the host exits. If both Vehla and Vehla Alpha are running, restart both. A stale loaded descriptor can produce a metadata mismatch even when the installed manifest and binary match. The build produces an arm64, ad-hoc signed bundle linked to Vehla's embedded SDK framework. Historical signed 1.1.1 archives are retained; 2.1.2 is submitted for source review. Catalog publication requires an immutable 2.1.2 archive signed with the existing publisher identity; the retained 1.1.1 release is not a substitute for this build.

See [architecture and research notes](docs/ARCHITECTURE.md) for inspected sources, SDK contracts and design decisions. Tests cover database compatibility, persistence/recovery, absent Antinote, import idempotency, slot/expiry safety, math/search, native list editing, host bridge use, close-time saves and offscreen rendering. Actual popup routing and file-panel behavior still need checking in an installed Vehla build.


QuickNote uses the package identity `com.wiseman.vehla.quicknote`. On its first run, its storage actor copies the previous widget library from the sibling `com.wiseman.vehla.antinote` data directory, preserving note identities, text, slots, trash, selection, settings and import history. Existing QuickNote data takes precedence; the original files remain intact. A damaged old library reports an error rather than silently replacing notes with tutorials; its valid recovery snapshot is available through Recover Previous Save.

Automatic Apple Notes sync is intentionally absent: supported interfaces do not provide verified preservation of live math, native checklist state and QuickNote commands. See [Apple Notes compatibility research](docs/APPLE_NOTES_COMPATIBILITY.md). Text/Markdown export remains available.


Formatting, checkboxes, summaries and math results are prepared off the main actor. The selected note is prepared before the editor appears on startup; other active notes warm in the background. An in-memory LRU cache retains up to 128 notes and approximately 16 MiB of derived content. Switching back to unchanged notes or reopening the popup restores cached formatting and answers in the same editor update; saving does not invalidate them. Editing a note invalidates only that note's content match. Larger libraries warm a bounded working set and calculate other notes on demand. Derived results are never persisted as user text.

Horizontal two-finger navigation requires at least 120 points of travel, locks direction after 16 points and requires horizontal movement to exceed vertical movement by 2:1. It still commits once at the end of the gesture, ignores momentum and preserves vertical scrolling.
