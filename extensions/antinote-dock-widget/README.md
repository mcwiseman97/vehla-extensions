# Antinote Dock Widget

Read and edit [Antinote](https://antinote.io) notes beside Vehla’s Dock. The compact tile shows how many notes are stored. The inline row shows the current note and can open it in Antinote. The popup searches notes, edits the text, and creates a new note.

Antinote keeps notes in a SQLite file inside its app container. Click the note on the right and type. Vehla’s popup keeps keyboard focus for itself, so the editor takes key presses directly and draws its own caret. ⌘S, Save, switching notes or closing the popup sends the text to Antinote. New starts a blank note in the same editor; ⌘S, Save, picking another note or closing the popup creates it in Antinote in the background. Open shows the note in Antinote. Lines that start with Antinote’s checkbox markers (`[]`, `- [ ]`, `[x]`, `- [x]`) show a checkbox; clicking it checks or unchecks the item and saves right away.
Antinote keeps notes in memory and ignores outside writes to its database, so the widget never writes the database. To save, it uses Accessibility to replace the text in Antinote’s editor, then waits until Antinote has written it to its database. If Antinote is showing a different note, the widget first switches it with `promoteAndOpen`. Antinote brings itself forward whenever it handles a link, so when it was hidden or had no window open the widget hides it again the instant it appears (about one frame) and finishes the save through Accessibility while it stays hidden, then returns focus to the previous app. New works the same way. If Antinote shows text the widget does not expect, nothing is overwritten. Vehla needs Accessibility permission for this. Open and New talk to Antinote directly: macOS may ask once for permission to let Vehla control Antinote. Closing the widget asks Antinote to reload notes that changed.

Vehla needs **Full Disk Access**. macOS otherwise blocks reads of another app’s container. Grant it in System Settings → Privacy & Security → Full Disk Access, then fully quit and reopen Vehla.

If iCloud sync is on, a newer cloud copy can still merge over a local edit. If Antinote changes a note while you are editing it, the popup asks whether to keep your text or take Antinote’s.

## Build and install

Requires macOS 14+, Apple silicon, and Swift 6+.

```sh
swift test --package-path extensions/antinote-dock-widget
zsh extensions/antinote-dock-widget/build.sh
swift run --package-path sdk/swift vehla-swift validate \
  extensions/antinote-dock-widget/dist/Antinote
```

In Vehla, choose **Settings → Store → Install Local Package**, select `dist/Antinote`, then enable Antinote in **Settings → Dock Widgets**.

The widget does not copy notes into its own storage. Uninstalling it leaves Antinote’s database where it is. The only file it writes under Vehla’s package data directory is the id of the note you last selected.
