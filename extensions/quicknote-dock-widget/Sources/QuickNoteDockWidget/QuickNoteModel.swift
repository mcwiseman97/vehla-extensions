import AppKit
import Foundation
import UniformTypeIdentifiers
import VehlaDockWidgetSDK

@MainActor
final class QuickNoteModel: ObservableObject {
    @Published private(set) var library = ScratchLibrary()
    @Published private(set) var loading = true
    @Published private(set) var ready = false
    @Published var draft = ""
    @Published var query = "" { didSet { search() } }
    @Published var scope = "stack" { didSet { search() } }
    @Published private(set) var visible: [ScratchNote] = []
    @Published var status: String?
    @Published var statusIsError = false
    @Published var theme: VehlaDockWidgetTheme?
    @Published var importPresented = false
    @Published var importPreview: ImportPreview?
    @Published var importSelection: Set<String> = []
    @Published var importing = false
    @Published var sidebar = false
    @Published var deletePresented = false
    @Published var recoverPresented = false
    @Published var findPresented = false
    @Published var findText = ""
    @Published var replacement = ""
    @Published var caseSensitive = false
    @Published var analysis = ScratchAnalysis()
    @Published var autoPaste = false
    @Published var stopwatchStart: Date?
    @Published var stopwatchElapsed: TimeInterval = 0
    @Published var stopwatchPaused = false
    @Published var focusToken = UUID()
    private(set) var context: VehlaDockWidgetContext?
    private var repository: ScratchRepository?
    private let importer = ScratchImporter()
    private let tools = ScratchTools()
    private var loadTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var ocrTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var active = false
    private var closed = false
    private var lastClipboardIDs: Set<String> = []
    private var pasteboardChange = 0
    private var pasteDelimiter = "\n"
    private var captureNoteID: String?
    private var savedRevision: UInt64 = 0

    var notes: [ScratchNote] { library.notes.filter { $0.deleted == nil } }
    var selectedID: String? { library.selectedID }
    var selected: ScratchNote? { library.notes.first { $0.id == selectedID } }
    var tileTextColor: NSColor { theme?.tileTextColor ?? .labelColor }
    var editorTextColor: NSColor { theme?.primaryTextColor ?? .labelColor }
    var isDirty: Bool { library.revision > savedRevision }

    func configure(_ context: VehlaDockWidgetContext) {
        self.context = context; theme = context.theme; closed = false
        if repository == nil { repository = ScratchRepository(root: context.dataDirectory, legacyRoot: ScratchRepository.legacyDirectory(for: context.dataDirectory)) }
        start()
    }

    func start() {
        active = true
        if ready {
            let previous = library
            library.expire()
            if library != previous { changed() }
            ensureSelection(); search(); analyze(); return
        }
        guard loadTask == nil, let repository else { return }
        loading = true
        loadTask = Task { [weak self] in
            do {
                let state = try await repository.load()
                guard let self, !Task.isCancelled, !self.closed else { return }
                self.library = state; self.savedRevision = state.revision; self.ready = true
                let previous = self.library
                self.library.expire()
                if self.library != previous { self.changed() }
                self.ensureSelection(); self.search(); self.analyze()
            } catch { self?.fail("Could not load notes: \(error.localizedDescription)") }
            self?.loading = false; self?.loadTask = nil
        }
    }

    func stop() {
        active = false
        stopCapture()
        searchTask?.cancel(); analysisTask?.cancel(); importTask?.cancel(); ocrTask?.cancel()
        importing = false; importPreview = nil; importPresented = false
        // Accepted writes must drain even when the surface disappears.
        debounceTask?.cancel()
        if ready, isDirty { persist() }
    }

    func close() {
        stop(); closed = true; loadTask?.cancel(); loadTask = nil
        context = nil
    }

    private func changed() {
        library.revision += 1
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.persist()
        }
        search(); context?.invalidate()
    }

    private func persist() {
        guard ready, let repository, library.revision > savedRevision else { return }
        let snapshot = library
        // Chain accepted snapshots so a close flush cannot race an earlier edit.
        let previous = saveTask
        saveTask = Task { [weak self] in
            await previous?.value
            do {
                try await repository.save(snapshot)
                guard let self else { return }
                self.savedRevision = max(self.savedRevision, snapshot.revision)
            } catch { self?.fail("Save failed; your edits are still in memory. \(error.localizedDescription)") }
        }
    }

    func saveCurrent() { debounceTask?.cancel(); persist() }

    private func ensureSelection() {
        if !library.notes.contains(where: { $0.id == selectedID && $0.deleted == nil }) {
            library.selectedID = notes.first?.id
        }
        draft = selected?.content ?? ""
    }

    func select(_ id: String) {
        guard ready, let note = library.notes.first(where: { $0.id == id }) else { return }
        stopCapture()
        pruneEmpty(except: id)
        library.selectedID = id; draft = note.content; focusToken = UUID()
        changed(); analyze()
    }

    private func pruneEmpty(except id: String? = nil) {
        library.notes.removeAll { $0.id != id && $0.slot == nil && $0.deleted == nil && $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func startNewNote(content: String = "") {
        guard ready else { return }
        stopCapture(); pruneEmpty()
        let note = ScratchNote(content: content)
        library.notes.insert(note, at: 0); library.selectedID = note.id
        draft = content; scope = "stack"; query = ""; focusToken = UUID()
        changed(); analyze()
    }

    func inlineEdited(_ text: String) {
        guard ready, let index = library.notes.firstIndex(where: { $0.id == selectedID && $0.deleted == nil }) else { return }
        guard text.utf8.count <= QuickNoteDatabase.contentLimit else { fail("Notes are limited to 2 MB."); return }
        draft = text; library.notes[index].content = text; library.notes[index].modified = Date()
        changed(); analyze()
    }

    func navigate(_ direction: Int) {
        let stack = notes.filter { $0.slot == nil }
        guard let i = stack.firstIndex(where: { $0.id == selectedID }) else { if let first = stack.first { select(first.id) }; return }
        let next = i + direction
        if next < 0 { startNewNote() }
        else if next < stack.count { select(stack[next].id) }
    }

    func promote(_ id: String? = nil) {
        guard let index = library.notes.firstIndex(where: { $0.id == (id ?? selectedID) && $0.deleted == nil && $0.slot == nil }) else { return }
        let note = library.notes.remove(at: index); library.notes.insert(note, at: 0); changed()
    }

    func trash(_ id: String? = nil) {
        guard let index = library.notes.firstIndex(where: { $0.id == (id ?? selectedID) && $0.deleted == nil && $0.slot == nil }) else { return }
        stopCapture(); library.notes[index].deleted = Date()
        ensureSelection(); changed(); analyze(); notice("Moved to The Void. Restore it from the Void tab.")
    }

    func restore(_ id: String) {
        guard let index = library.notes.firstIndex(where: { $0.id == id }) else { return }
        library.notes[index].deleted = nil; library.notes[index].slot = nil
        scope = "stack"; select(id); notice("Restored.")
    }

    func setSlot(_ slot: Int?) {
        guard let index = library.notes.firstIndex(where: { $0.id == selectedID && $0.deleted == nil }) else { return }
        if let slot, library.notes.contains(where: { $0.slot == slot && $0.deleted == nil && $0.id != selectedID }) {
            fail("Slot \(slot) is occupied. Free it from that note’s slot menu first."); return
        }
        library.notes[index].slot = slot; changed()
    }

    func jumpSlot(_ slot: Int) {
        if let note = notes.first(where: { $0.slot == slot }) { select(note.id) }
        else { startNewNote(); setSlot(slot) }
        scope = "slots"
    }

    func settings(expiry: Int? = nil, fontSize: Double? = nil, lined: Bool? = nil) {
        guard ready else { return }
        if let expiry { library.expiryDays = expiry; library.expire(); ensureSelection() }
        if let fontSize { library.fontSize = min(28, max(11, fontSize)) }
        if let lined { library.linedPaper = lined }
        changed()
    }

    private func search() {
        searchTask?.cancel()
        guard ready, active else { return }
        let notes = library.notes, query = query, scope = scope, tools = tools
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
                let ids = try await tools.search(notes, query: query, scope: scope)
                guard !Task.isCancelled else { return }; let matching = await tools.matchingNotes(notes, ids: ids)
                guard !Task.isCancelled else { return }; self?.visible = matching
            } catch is CancellationError {} catch { self?.fail(error.localizedDescription) }
        }
    }

    private func analyze() {
        analysisTask?.cancel()
        guard active else { return }
        let text = draft, tools = tools
        analysisTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(140))
                let result = try await tools.analyze(text)
                guard !Task.isCancelled else { return }; self?.analysis = result
            } catch is CancellationError {} catch { self?.fail(error.localizedDescription) }
        }
    }

    func copyDraft() { context?.copyText(draft); pasteboardChange = NSPasteboard.general.changeCount; notice("Copied.") }
    private func entity() -> VehlaDockWidgetSharedContext? {
        guard let selected else { return nil }
        return VehlaDockWidgetSharedContext(id: selected.id, kind: .text, sourceID: "quicknote", title: selected.title, body: draft)
    }
    func sendToNotes() {
        guard let entity = entity(), context?.app?.perform(.addToNotes, with: entity) == true else {
            fail("This Vehla version cannot add notes through the app bridge. Use Copy or Export."); return
        }
        notice("Sent to Vehla Notes.")
    }

    func beginImport() {
        guard ready else { return }
        stopCapture()
        importPresented = true; importPreview = nil; importing = true; status = nil
        let installed = ["com.chabomakers.Antinote", "com.chabomakers.Antinote-setapp"].contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser, importer = importer
        importTask?.cancel()
        importTask = Task { [weak self] in
            do {
                let preview = try await importer.discover(home: home, installed: installed)
                guard !Task.isCancelled else { return }; self?.acceptPreview(preview)
            } catch is CancellationError {} catch { self?.fail(error.localizedDescription) }
            if !Task.isCancelled { self?.importing = false }
        }
    }

    func chooseImportFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite")!, UTType(filenameExtension: "sqlite3")!, UTType(filenameExtension: "db")!, .json, .plainText, UTType(filenameExtension: "md")!]
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            let urls = panel.urls, importer = self.importer
            self.importing = true; self.importPreview = nil
            self.importTask?.cancel()
            self.importTask = Task { [weak self] in
                do {
                    let preview = try await importer.files(urls)
                    guard !Task.isCancelled else { return }; self?.acceptPreview(preview)
                } catch is CancellationError {} catch { self?.fail(error.localizedDescription) }
                if !Task.isCancelled { self?.importing = false }
            }
        }
    }
    private func acceptPreview(_ preview: ImportPreview) {
        importPreview = preview
        importSelection = Set(preview.notes.filter { !library.importedKeys.contains($0.importKey ?? "") }.map(\.id))
    }
    func cancelImport() { importTask?.cancel(); importing = false; importPresented = false; importPreview = nil }
    func confirmImport() {
        guard let preview = importPreview, ready else { return }
        let incoming = preview.notes.filter { importSelection.contains($0.id) }
        let importer = importer
        importing = true
        importTask = Task { [weak self] in
            do {
                while let self, !Task.isCancelled {
                    let snapshot = self.library
                    let (merged, count) = try await importer.merged(incoming, library: snapshot)
                    guard !Task.isCancelled else { return }
                    guard self.library.revision == snapshot.revision else { continue }
                    self.library = merged; self.changed()
                    self.importPresented = false; self.importPreview = nil; self.importing = false
                    self.notice("Imported \(count) notes. Existing imports were skipped.")
                    return
                }
            } catch is CancellationError {} catch { self?.importing = false; self?.fail(error.localizedDescription) }
        }
    }

    func recover() {
        guard let repository else { return }
        let previous = saveTask
        loadTask = Task { [weak self] in
            await previous?.value
            do {
                let state = try await repository.recover()
                guard let self else { return }
                self.library = state; self.savedRevision = state.revision; self.ready = true
                self.loading = false; self.ensureSelection(); self.search(); self.analyze(); self.notice("Recovered the previous save.")
            } catch { self?.fail(error.localizedDescription) }
            self?.loadTask = nil
        }
    }

    func export(backup: Bool = false, markdown: Bool = false) {
        guard ready else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [backup ? .json : markdown ? UTType(filenameExtension: "md")! : .plainText]
        panel.nameFieldStringValue = backup ? "Vehla Scratchpad.json" : "\(selected?.title.prefix(60) ?? "Note").\(markdown ? "md" : "txt")"
        let snapshot = library, text = draft
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { [weak self] in
                do {
                    try await Task.detached(priority: .utility) {
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        let data = try backup ? JSONEncoder().encode(snapshot) : Data(text.utf8)
                        try data.write(to: url, options: .atomic)
                    }.value
                    self?.notice("Exported \(url.lastPathComponent).")
                } catch { self?.fail(error.localizedDescription) }
            }
        }
    }

    func replaceAll() {
        guard !findText.isEmpty else { return }
        let text = draft, find = findText, replacement = replacement, sensitive = caseSensitive
        let id = selectedID
        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            let updated = await Task.detached(priority: .utility) {
                text.replacingOccurrences(of: find, with: replacement, options: sensitive ? [] : [.caseInsensitive])
            }.value
            guard let self, !Task.isCancelled, self.selectedID == id, self.draft == text else { return }
            self.inlineEdited(updated)
        }
    }

    func command(_ line: String) -> Bool {
        switch line.trimmingCharacters(in: .whitespaces).lowercased() {
        case "/new": startNewNote(); return true
        case "/search": sidebar = true; return true
        case "/import": beginImport(); return true
        case "/export": export(); return true
        case "/copy": copyDraft(); return true
        default: break
        }
        let line = line.hasPrefix("/") ? String(line.dropFirst()) : line
        let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
        if lower == "paste" || (lower.hasPrefix("paste(") && lower.hasSuffix(")")) {
            if autoPaste { stopCapture() }
            else { pasteDelimiter = lower == "paste" ? "\n" : String(line.dropFirst(6).dropLast()); startCapture() }
            return true
        }
        if lower == "timer p" { toggleStopwatch(); return true }
        if lower == "timer s" || lower == "timer 0" { stopwatchStart = nil; stopwatchElapsed = 0; return true }
        if lower == "timer r" { stopwatchStart = Date(); stopwatchElapsed = 0; stopwatchPaused = false; return true }
        if let timer = ScratchTimerCommand.parse(line) {
            if let duration = timer.duration {
                guard context?.app?.startTimer(label: timer.label, duration: duration, context: entity()) == true else {
                    fail("This Vehla version cannot start timers through the app bridge."); return true
                }
                notice("Started \(timer.label) in Vehla Timers.")
            } else { stopwatchStart = Date(); stopwatchElapsed = 0; stopwatchPaused = false }
            return true
        }
        return false
    }
    func toggleStopwatch() {
        if stopwatchPaused { stopwatchStart = Date(); stopwatchPaused = false }
        else { stopwatchElapsed += Date().timeIntervalSince(stopwatchStart ?? Date()); stopwatchPaused = true; stopwatchStart = nil }
    }
    func escape() -> Bool {
        if autoPaste { stopCapture(); return true }
        if findPresented { findPresented = false; return true }
        return false
    }

    private func startCapture() {
        guard active, selected?.deleted == nil else { return }
        autoPaste = true; captureNoteID = selectedID
        pasteboardChange = NSPasteboard.general.changeCount
        context?.clipboard?.setActiveViewer(true)
        lastClipboardIDs = Set(context?.clipboard?.items(offset: 0, limit: 100).map(\.id) ?? [])
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, self.active, self.autoPaste else { return }
                self.captureClipboard()
            }
        }
        notice("AutoPaste is on while the widget is visible.")
    }
    func stopCapture() {
        captureTask?.cancel(); captureTask = nil; autoPaste = false; captureNoteID = nil
        context?.clipboard?.setActiveViewer(false)
    }
    private func captureClipboard() {
        guard selectedID == captureNoteID else { stopCapture(); return }
        if let bridge = context?.clipboard {
            let items = bridge.items(offset: 0, limit: 100)
            let current = Set(items.map(\.id))
            for item in items.reversed() where !lastClipboardIDs.contains(item.id) && item.kind != .image {
                append(item.text, delimiter: pasteDelimiter)
            }
            lastClipboardIDs = current
        } else {
            let board = NSPasteboard.general
            guard board.changeCount != pasteboardChange else { return }
            pasteboardChange = board.changeCount
            if let text = board.string(forType: .string) { append(text, delimiter: pasteDelimiter) }
        }
    }
    private func append(_ text: String, delimiter: String = "\n") {
        guard !text.isEmpty else { return }
        inlineEdited(draft + (draft.isEmpty ? "" : delimiter) + text)
    }
    func recognizeImage(_ data: Data) {
        let id = selectedID, tools = tools
        ocrTask?.cancel(); notice("Recognizing text locally…")
        ocrTask = Task { [weak self] in
            do {
                let text = try await tools.ocr(data: data)
                guard let self, !Task.isCancelled, self.active, self.selectedID == id else { return }
                self.append(text); self.notice("Image text added.")
            } catch is CancellationError {} catch { self?.fail(error.localizedDescription) }
        }
    }
    func recognizeFile(_ url: URL) {
        let id = selectedID, tools = tools
        ocrTask?.cancel()
        ocrTask = Task { [weak self] in
            do {
                let data = try await Task.detached(priority: .utility) {
                    let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 20 * 1_024 * 1_024 else { throw ScratchError.message("Image exceeds 20 MiB.") }
                    return try Data(contentsOf: url)
                }.value
                try Task.checkCancellation()
                let text = try await tools.ocr(data: data)
                guard let self, !Task.isCancelled, self.active, self.selectedID == id else { return }
                self.append(text); self.notice("Image text added.")
            } catch is CancellationError {} catch { self?.fail(error.localizedDescription) }
        }
    }
    private func notice(_ text: String) { statusIsError = false; status = text }
    private func fail(_ text: String) { statusIsError = true; status = text }
}
