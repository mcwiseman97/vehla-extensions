# Research — reading queue Dock widget

Save article links, organize a personal reading queue, and return to cached text beside the Dock. No AI or account is required.

## Features

- Compact unread count, inline current article, and a 760 × 800 popup.
- Paste a complete HTTP/HTTPS URL, drop a link into the popup, or explicitly choose a recent clipboard link.
- Collections, favorites, search across titles/sites/cached text, sorting, reading states, and archive.
- Clean selectable article text with headings, lists, quotations, code, and links.
- Adjustable reader type size, saved reading position, and offline reading after a successful download.
- Duplicate links open the existing record. Use its menu to restore an archived item or move it.
- Markdown reading-list export, JSON backup/merge/replace, and recovery of the preceding successful local snapshot.
- Removing a collection moves its articles to Inbox. Removing an article offers session-local Undo.

The existing News Reader discovers articles from feeds. Research keeps links you intentionally save; it does not subscribe to feeds or record clipboard activity.

## Build and install

Requires macOS 14+, Apple silicon, and Swift 6+ with a working macOS toolchain.

```sh
swift test --package-path extensions/research-dock-widget
zsh extensions/research-dock-widget/build.sh
swift run --package-path sdk/swift vehla-swift validate \
  extensions/research-dock-widget/dist/Research
```

In Vehla, choose **Settings → Store → Install Local Package**, select `dist/Research`, then enable Research in **Settings → Dock Widgets**. Local builds use an ad hoc code signature. The bundle links to Vehla's embedded SDK framework and cannot run as a standalone application.

The host owns tile/popup expansion. The inline Resume control prepares the last article for the popup; it cannot force expansion through the public SDK. Link drops are supported inside the popup, not promised on the resting Dock tile.

## Reading behavior and limits

A link is saved before downloading begins. Downloads are cancellable, with at most two active requests, a 15-second request timeout, up to five redirects, and a streaming 5 MiB response limit. Closing/hiding the widget cancels outstanding fetches; an interrupted bookmark can be retried using Download or Refresh. Durable edits and reading-position saves are separate from fetch cancellation.

The extractor uses Foundation's system HTML parser with external-entity loading disabled, followed by a conservative article/main/content selection heuristic. It converts content into plain structured blocks, never executes JavaScript, and does not render active HTML or load remote images. It respects declared character encoding and preserves Unicode through the HTML tidy path.

Extraction is best effort. Paywalls, login-required pages, JavaScript-only pages, PDFs, complex tables, images, and very short pages may need **Open Original**. No login cookies or host browser sessions are used. A failed refresh retains existing cached text. Article author metadata is shown only when present; publication-date inference is not implemented.

Automatic fetching rejects credential-bearing URLs, nonstandard ports, and destinations resolving to local/private addresses, including redirects. DNS preflight is defense in depth, not an OS network sandbox: URLSession may perform its own resolution. Native extensions already run with the host application's access; only install trusted code.

## Storage and permissions

- `persistentStorage`: the package's private library and cached article text.
- `clipboardRead` + `clipboardWrite`: optional host clipboard-history picker and explicit copy actions. The SDK requires both for its history bridge.
- `openURL`: Open Original and article links.
- `networkAccess`: fetching the explicitly saved website.

Manual paste remains available when the host history bridge is absent. Clipboard history is read only after choosing Recent Clipboard Links; Research never deletes or edits the original clips.

`library.json` holds versioned metadata. Article blocks live in immutable per-revision files under `content/`; progress changes do not rewrite cached article bytes. Atomic writes and `library.previous.json` support recovery. Damaged index bytes are retained on explicit recovery. Unsupported/corrupt libraries fail visibly rather than being overwritten as empty.

**Uninstall removes private storage.** Use Library → Back Up Library and save outside the extension folder. Backups contain article content as well as metadata and progress. Restore previews record counts and offers Merge (existing URLs win) or Replace. Files above 100 MiB are rejected; larger libraries should be exported in a future streaming format before growing beyond that limit.

AI, web research, browser extensions, sync, highlights, QuickGlass capture, and Recall integration are intentionally deferred.

## Development verification

Unit tests cover extraction/encoding, URL validation, HTTP failures/redirects/size limits/cancellation, persistence, corrupt-state recovery, duplicate/merge behavior, and library-size exercises. Optional offscreen AppKit render checks use fixture content:

```sh
RESEARCH_RENDER_PREVIEWS=1 swift test --package-path extensions/research-dock-widget
```

Previews are written to `/tmp/research-queue-light.png`, `/tmp/research-queue-dark.png`, and `/tmp/research-reader-dark.png`. They do not touch the installed host's data. Optional live-fetch validation is enabled by `RESEARCH_LIVE_FETCH=1` and contacts Swift.org.

Some Swift 6.4 Command Line Tools beta builds fail to discover `TestingMacros`. On that environment, pass the installed plugin explicitly:

```sh
swift test --package-path extensions/research-dock-widget \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

The build script uses SwiftPM's native build engine to avoid beta build-engine plugin issues. No third-party runtime dependencies are added beyond the local Vehla SDK.

### Inline controls

Add Link and Library open inside the widget. Collection and sort choices, article actions, title edits, errors, and destructive confirmations are inline; no sheets, menus, or alerts are presented. Backup/export uses an absolute file path (including `~/` paths); exports refuse to overwrite existing files. Load an existing JSON file by path, then choose Merge or Replace in the inline confirmation.

Swipe left on a queue row, then click Delete. The custom action keeps its black label visible on a white button. Undo in the widget footer restores the most recently removed article, including cached text and progress.
