import AppKit
import Darwin
import Foundation
import VehlaDockWidgetSDK

@MainActor
final class AntinoteModel: ObservableObject {
    @Published private(set) var notes: [AntinoteNote] = []
    @Published private(set) var canEdit = false
    @Published private(set) var editBlock: String?
    @Published private(set) var loading = true
    @Published var selectedID: String?
    @Published var draft = ""
    @Published var query = ""
    @Published var composing = false
    @Published var newNoteText = ""
    @Published var status: String?
    @Published var statusIsError = false
    @Published var conflictText: String?
    @Published var theme: VehlaDockWidgetTheme?
    nonisolated static func storedContent(_ url: URL, _ noteID: String) async -> String? {
        await Task.detached {
            try? AntinoteDatabase.load(url).notes.first { $0.id == noteID }?.content
        }.value
    }

    private(set) var context: VehlaDockWidgetContext?
    private var databaseURL: URL?
    private var baseline = ""
    private var pending: [String: PendingEdit] = [:]
    private var active = false
    private var saving = false
    private var didRestore = false
    private var loadToken = UUID()
    private var reloadTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var queuedSave: (id: String, content: String, expected: String)?
    /// Text confirmed in Antinote that its database has not caught up with yet.
    private var pushed: [String: String] = [:]
    private let watcher = AntinoteWatcher()

    var selected: AntinoteNote? {
        notes.first { $0.id == selectedID }
    }

    var visible: [AntinoteNote] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return notes }
        return notes.filter { $0.content.localizedCaseInsensitiveContains(needle) }
    }

    var isDirty: Bool { draft != baseline }

    func isUnsaved(_ id: String) -> Bool {
        if id == selectedID { return isDirty }
        return pending[id] != nil
    }

    var tileTextColor: NSColor { theme?.tileTextColor ?? .labelColor }
    var editorTextColor: NSColor { theme?.primaryTextColor ?? .labelColor }

    func configure(_ context: VehlaDockWidgetContext) {
        self.context = context
        theme = context.theme
        AntinoteDiagnostics.directory = context.dataDirectory
        if databaseURL == nil {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let found = AntinoteDatabase.discover(home: home)
            for item in found {
                AntinoteDiagnostics.note("database \(item.url.path) tables=\(item.tables) notes=\(item.noteCount.map(String.init) ?? "-") modified=\(item.modified.map { "\($0)" } ?? "-") error=\(item.error ?? "-")")
            }
            databaseURL = AntinoteDatabase.best(found)?.url
                ?? AntinoteDatabase.locate(home: home)?.url
            AntinoteDiagnostics.note("using database \(databaseURL?.path ?? "none")")
        }
        start()
    }

    func start() {
        active = true
        guard let databaseURL else {
            loading = false
            statusIsError = true
            status = AntinoteDatabaseError.missing.localizedDescription
            return
        }
        watcher.start(url: databaseURL) { [weak self] in
            self?.scheduleReload()
        }
        reload()
    }

    func stop() {
        active = false
        autosaveTask?.cancel()
        watcher.stop()
        reloadTask?.cancel()
        if composing {
            commitNewNote()
        } else if isDirty {
            save()
        }
        context?.invalidate()
    }

    /// Starts a blank note in the popup's editor. It is created in Antinote on
    /// ⌘S, Save, picking another note, pressing New again, or closing the popup.
    func startNewNote() {
        if composing {
            commitNewNote(selectWhenDone: false)
        } else if isDirty {
            save()
        }
        composing = true
        newNoteText = ""
        conflictText = nil
        statusIsError = false
        status = "New note. Type, then press ⌘S or close the popup to add it to Antinote."
    }

    func newNoteEdited(_ value: String) {
        newNoteText = value
    }

    var newNoteTitle: String {
        newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "New note"
            : AntinoteNote(id: "", content: newNoteText).title
    }

    func commitNewNote(selectWhenDone: Bool = true) {
        guard composing else { return }
        let selectionAtCommit = selectedID
        composing = false
        let text = newNoteText
        newNoteText = ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = nil
            return
        }
        guard let databaseURL else {
            statusIsError = true
            status = AntinoteDatabaseError.missing.localizedDescription
            return
        }
        let existing = Set(notes.map(\.id))
        statusIsError = false
        status = "Adding to Antinote…"
        Task {
            let result = await AntinoteBridge.create(content: text, existingIDs: existing) {
                try? await Task.detached { try AntinoteDatabase.load(databaseURL).notes }.value
            }
            switch result {
            case .created(let note):
                if !notes.contains(where: { $0.id == note.id }) {
                    notes.insert(note, at: 0)
                }
                if selectWhenDone, !composing, selectedID == selectionAtCommit {
                    rememberPendingEdit()
                    selectedID = note.id
                    draft = note.content
                    baseline = note.content
                    conflictText = nil
                    persistSelection()
                }
                statusIsError = false
                status = "Added to Antinote."
            case .sent:
                statusIsError = false
                status = "Sent to Antinote."
            case .failed(let message):
                composing = true
                newNoteText = text
                statusIsError = true
                status = message
            }
            scheduleReload(againAfter: .milliseconds(1500))
            context?.invalidate()
        }
    }

    /// Save button and ⌘S.
    func saveCurrent() {
        if composing {
            commitNewNote()
        } else {
            save()
        }
    }

    private func typed(_ value: String, noteID: String) {
        if selectedID != noteID { select(noteID) }
        guard value != draft else { return }
        draft = value
        if conflictText != nil {
            statusIsError = true
            status = "Antinote changed this note too. Choose a version in the widget."
            return
        }
        scheduleAutosave()
    }

    /// Text typed directly in the popup's editor.
    func inlineEdited(_ value: String) {
        guard let selectedID else { return }
        typed(value, noteID: selectedID)
    }

    func select(_ id: String) {
        if composing { commitNewNote(selectWhenDone: false) }
        guard id != selectedID else { return }
        if let previous = selectedID, draft != baseline {
            save(noteID: previous, content: draft, expected: baseline)
        }
        rememberPendingEdit()
        selectedID = id
        persistSelection()
        if let edit = pending[id] {
            draft = edit.draft
            baseline = edit.baseline
            conflictText = edit.conflict
        } else if let note = notes.first(where: { $0.id == id }) {
            draft = note.content
            baseline = note.content
            conflictText = nil
        }
    }

    /// Sending can bring Antinote forward, so edits are only marked here and
    /// sent on ⌘S, Save, switching notes, or closing the popup.
    func scheduleAutosave() {
        guard isDirty, conflictText == nil, !saving else { return }
        statusIsError = false
        status = "Edited. Press ⌘S or Save, or close the popup, to send this to Antinote."
    }

    func save(
        noteID explicitID: String? = nil,
        content explicitContent: String? = nil,
        expected explicitExpected: String? = nil,
        then follow: (@MainActor () -> Void)? = nil
    ) {
        let noteID = explicitID ?? selectedID
        guard let noteID else {
            follow?()
            return
        }
        let content = explicitContent ?? draft
        let expected = explicitExpected ?? baseline
        guard content != expected || conflictText != nil else {
            follow?()
            return
        }
        if saving {
            queuedSave = (noteID, content, expected)
            return
        }
        let selectionMatches = noteID == selectedID
        saving = true
        statusIsError = false
        status = "Sending to Antinote…"
        Task {
            let result = await AntinoteBridge.push(noteID: noteID, content: content, baseline: expected) { [databaseURL] in
                guard let databaseURL else { return nil }
                return await Self.storedContent(databaseURL, noteID)
            }
            saving = false
            AntinoteDiagnostics.note("save note=\(noteID) chars=\(content.count) result=\(result)")
            switch result {
            case .saved:
                pending[noteID] = nil
                pushed[noteID] = content
                if let index = notes.firstIndex(where: { $0.id == noteID }) {
                    notes[index].content = content
                }
                if selectionMatches, baseline == expected {
                    baseline = content
                    if draft == content { conflictText = nil }
                }
                statusIsError = false
                status = "Saved to Antinote."
                follow?()
                scheduleReload(againAfter: .milliseconds(1500))
            case .conflict(let current):
                if selectionMatches {
                    baseline = current
                    conflictText = current
                } else {
                    pending[noteID] = PendingEdit(draft: content, baseline: current, conflict: current)
                }
                statusIsError = true
                status = "Antinote shows different text for this note, so nothing was overwritten. Choose a version below."
            case .failed(let message):
                if !selectionMatches {
                    pending[noteID] = PendingEdit(draft: content, baseline: expected, conflict: nil)
                }
                context?.copyText(content)
                statusIsError = true
                status = message
            }
            context?.invalidate()
            if var next = queuedSave {
                queuedSave = nil
                if case .saved = result, next.id == noteID, next.expected == expected {
                    next.expected = content
                }
                save(noteID: next.id, content: next.content, expected: next.expected)
            }
        }
    }

    func keepDraft() {
        conflictText = nil
        status = nil
    }

    func takeRemote() {
        guard let conflictText else { return }
        draft = conflictText
        baseline = conflictText
        self.conflictText = nil
        if let selectedID { pending[selectedID] = nil }
        status = nil
    }

    func openSelected() {
        guard let selectedID, let url = AntinoteLinks.open(noteID: selectedID) else { return }
        save {
            Task { await self.finishLaunch(url, success: "Opened in Antinote.") }
        }
    }

    func copyDraft() {
        context?.copyText(draft)
        statusIsError = false
        status = "Copied."
    }

    private func finishLaunch(_ url: URL, success: String) async {
        let result = await AntinoteLauncher.open(url)
        statusIsError = !result.opened
        status = result.opened ? success : result.message
    }

    private func reload() {
        guard active, !saving, let databaseURL else { return }
        let token = UUID()
        loadToken = token
        let url = databaseURL
        Task {
            let result: Result<AntinoteLibrary, Error> = await Task.detached {
                Result { try AntinoteDatabase.load(url) }
            }.value
            guard active, loadToken == token else { return }
            switch result {
            case .success(let library):
                apply(library)
                loading = false
            case .failure(let error):
                loading = false
                statusIsError = true
                status = error.localizedDescription
            }
            context?.invalidate()
        }
    }

    private func apply(_ library: AntinoteLibrary) {
        var loaded = library.notes
        for (id, text) in pushed {
            guard let index = loaded.firstIndex(where: { $0.id == id }) else {
                pushed[id] = nil
                continue
            }
            if loaded[index].content == text {
                pushed[id] = nil
            } else {
                loaded[index].content = text
            }
        }
        notes = loaded
        canEdit = library.canEdit
        editBlock = library.editBlock
        reconcilePendingEdits()
        if selectedID == nil || !notes.contains(where: { $0.id == selectedID }) {
            restoreSelectionIfNeeded()
        }
        if selectedID == nil || !notes.contains(where: { $0.id == selectedID }) {
            selectedID = notes.first?.id
            seedSelectedDraft()
        } else {
            absorbRemoteChange()
        }
    }

    private func absorbRemoteChange() {
        guard let note = selected else { return }
        if draft == note.content {
            baseline = note.content
            conflictText = nil
            if let selectedID { pending[selectedID] = nil }
        } else if draft == baseline {
            draft = note.content
            baseline = note.content
            conflictText = nil
        } else if note.content != baseline {
            baseline = note.content
            conflictText = note.content
        }
    }

    private func seedSelectedDraft() {
        guard let note = selected else {
            draft = ""
            baseline = ""
            conflictText = nil
            return
        }
        draft = note.content
        baseline = note.content
        conflictText = nil
        persistSelection()
    }

    private func rememberPendingEdit() {
        guard let selectedID else { return }
        if draft != baseline || conflictText != nil {
            pending[selectedID] = PendingEdit(draft: draft, baseline: baseline, conflict: conflictText)
        } else {
            pending[selectedID] = nil
        }
    }

    private func reconcilePendingEdits() {
        for (id, edit) in pending {
            guard let note = notes.first(where: { $0.id == id }) else {
                pending[id] = nil
                continue
            }
            if edit.draft == note.content {
                pending[id] = nil
            } else if note.content != edit.baseline {
                pending[id] = PendingEdit(draft: edit.draft, baseline: note.content, conflict: note.content)
            }
        }
    }

    private func restoreSelectionIfNeeded() {
        guard !didRestore, let directory = context?.dataDirectory else { return }
        didRestore = true
        let url = directory.appendingPathComponent("selection.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONDecoder().decode([String: String].self, from: data),
              let id = object["id"],
              notes.contains(where: { $0.id == id })
        else { return }
        selectedID = id
    }

    private func persistSelection() {
        guard let directory = context?.dataDirectory, let selectedID else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("selection.json")
        let data = try? JSONEncoder().encode(["id": selectedID])
        try? data?.write(to: url, options: .atomic)
    }

    private func scheduleReload(againAfter delay: Duration? = nil) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.reload()
            guard let delay else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }
}

private struct PendingEdit {
    var draft: String
    var baseline: String
    var conflict: String?
}

@MainActor
private final class AntinoteWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []

    func start(url: URL, onChange: @escaping @MainActor () -> Void) {
        stop()
        let paths = [
            url.path,
            url.path + "-wal",
            url.deletingLastPathComponent().path,
        ]
        for path in paths {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename, .delete],
                queue: .main
            )
            source.setEventHandler {
                Task { @MainActor in onChange() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        for source in sources { source.cancel() }
        sources.removeAll()
    }
}
