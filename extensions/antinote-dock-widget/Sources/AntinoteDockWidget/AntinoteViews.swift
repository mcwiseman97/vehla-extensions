import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VehlaDockWidgetSDK

struct AntinoteRootView: View {
    let surface: VehlaDockWidgetSurface
    @ObservedObject var model: AntinoteModel
    var body: some View {
        switch surface {
        case .compact:
            VStack(spacing: 3) {
                Image(systemName: "note.text").font(.system(size: 18, weight: .semibold))
                Text(model.notes.isEmpty ? "Notes" : "\(model.notes.count)").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color(nsColor: model.tileTextColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .help(model.selected?.title ?? "Your scratchpad")
        case .inline:
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selected?.title ?? "Scratchpad").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(model.selected?.preview ?? "A little room to think").font(.system(size: 9)).opacity(0.7).lineLimit(1)
                }
                Spacer(minLength: 0)
                if model.autoPaste { Image(systemName: "clipboard.fill").help("AutoPaste is on") }
            }
            .foregroundStyle(Color(nsColor: model.tileTextColor)).padding(.horizontal, 10)
        case .popup: PopupNoteView(model: model)
        @unknown default: EmptyView()
        }
    }
}

private struct PopupNoteView: View {
    @ObservedObject var model: AntinoteModel
    @FocusState private var searchFocused: Bool
    private var primary: Color { Color(nsColor: model.editorTextColor) }
    private var secondary: Color { Color(nsColor: model.theme?.secondaryTextColor ?? .secondaryLabelColor) }
    private var accent: Color { Color(nsColor: model.theme?.accentColor ?? .controlAccentColor) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                if model.sidebar || model.scope == "void" {
                    noteList.frame(width: 230)
                    Divider()
                }
                paper
            }
            Divider()
            footer
            if let status = model.status {
                HStack(alignment: .top) {
                    Text(status).font(.system(size: 11)).foregroundStyle(model.statusIsError ? .orange : secondary)
                    Spacer(minLength: 4)
                    Button { model.status = nil } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain)
                }.padding(.horizontal, 14).padding(.vertical, 7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(primary)
        .background(Color.clear)
        .sheet(isPresented: $model.importPresented) { ImportNotesView(model: model) }
        .confirmationDialog("Move this note to The Void?", isPresented: $model.deletePresented) {
            Button("Move to The Void") { model.trash() }
        } message: { Text("You can restore it from the Void tab.") }
        .confirmationDialog("Recover the previous saved library?", isPresented: $model.recoverPresented) {
            Button("Recover Previous Save") { model.recover() }
        } message: { Text("The previous library replaces the current one. Export a backup first if you want to keep both.") }
        .onDisappear { model.stopCapture() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.sidebar.toggle(); if model.sidebar { searchFocused = true }
            } label: { Image(systemName: "magnifyingglass") }
            .help("Search notes (⌘F)").keyboardShortcut("f", modifiers: .command)
            Text("Antinote").font(.system(size: 13, weight: .semibold))
            Text("SCRATCHPAD").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(secondary)
            Spacer()
            Button { model.navigate(1) } label: { Image(systemName: "chevron.left") }.help("Older note (⌘[)")
                .keyboardShortcut("[", modifiers: .command).disabled(!model.ready)
            Button { model.navigate(-1) } label: { Image(systemName: "chevron.right") }.help("Newer note (⌘])")
                .keyboardShortcut("]", modifiers: .command).disabled(!model.ready)
            Button { model.startNewNote() } label: { Image(systemName: "square.and.pencil") }.help("New note (⌘N)")
                .keyboardShortcut("n", modifiers: .command).disabled(!model.ready)
            Menu {
                Button("Import Notes…") { model.beginImport() }.disabled(!model.ready)
                Button("Export Text…") { model.export() }.keyboardShortcut("s", modifiers: .command).disabled(!model.ready)
                Button("Export Markdown…") { model.export(markdown: true) }.disabled(!model.ready)
                Button("Export Library Backup…") { model.export(backup: true) }.disabled(!model.ready)
                Button("Send to Vehla Notes") { model.sendToNotes() }.disabled(model.context?.app == nil || model.selected == nil)
                Divider()
                Button("Swap Stack / Slots") {
                    model.scope = model.scope == "slots" ? "stack" : "slots"
                    model.sidebar = true
                }.keyboardShortcut("t", modifiers: .command)
                Button("Find and Replace") { model.findPresented.toggle() }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Promote to Front") { model.promote() }.keyboardShortcut("1", modifiers: [.command, .shift]).disabled(model.selected?.slot != nil)
                Button("Move to The Void…") { model.deletePresented = true }.keyboardShortcut("d", modifiers: .command).disabled(model.selected == nil || model.selected?.slot != nil || model.selected?.deleted != nil)
                Divider()
                Toggle("Lined Paper", isOn: Binding(get: { model.library.linedPaper }, set: { model.settings(lined: $0) }))
                Menu("Expire Unmodified Scratch Notes") {
                    ForEach([0, 1, 7, 30, 365], id: \.self) { days in
                        Button(days == 0 ? "Never" : "After \(days) days") { model.settings(expiry: days) }
                    }
                }
                Button("Larger Text") { model.settings(fontSize: model.library.fontSize + 1) }.keyboardShortcut("+", modifiers: .command)
                Button("Smaller Text") { model.settings(fontSize: model.library.fontSize - 1) }.keyboardShortcut("-", modifiers: .command)
                Divider()
                Button("Recover Previous Save…") { model.recoverPresented = true }
                Button("Save Now") { model.saveCurrent() }.disabled(!model.ready)
            } label: { Image(systemName: "ellipsis.circle") }.help("Import, export and settings")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var noteList: some View {
        VStack(spacing: 10) {
            TextField("Search your notes", text: $model.query)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .onSubmit {
                    if let first = model.visible.first { model.select(first.id) }
                    else if !model.query.isEmpty { model.startNewNote(content: model.query) }
                }
            Picker("Notes", selection: $model.scope) {
                Text("Stack").tag("stack"); Text("Slots").tag("slots"); Text("Void").tag("void")
            }.pickerStyle(.segmented)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.visible) { note in
                        Button {
                            model.select(note.id); searchFocused = false
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(note.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Spacer(minLength: 2)
                                    if let slot = note.slot { Text("\(slot)").font(.system(size: 9, design: .monospaced)).foregroundStyle(accent) }
                                }
                                Text(note.preview).font(.system(size: 10)).foregroundStyle(secondary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10).background(note.id == model.selectedID ? accent.opacity(0.12) : secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                            .contextMenu {
                                if note.deleted != nil { Button("Restore") { model.restore(note.id) } }
                                else if note.slot == nil {
                                    Button("Promote to Front") { model.promote(note.id) }
                                    Button("Move to The Void") { model.trash(note.id) }
                                }
                            }
                    }
                    if model.visible.isEmpty {
                        VStack(spacing: 10) {
                            Text(model.scope == "void" ? "The Void is quiet." : "No matching notes.").foregroundStyle(secondary)
                            if !model.query.isEmpty && model.scope != "void" {
                                Button("Create a note from search") { model.startNewNote(content: model.query) }
                            }
                        }.font(.system(size: 11)).padding(.top, 30)
                    }
                }
            }
            Text("\(model.visible.count) notes").font(.system(size: 10)).foregroundStyle(secondary)
        }.padding(10)
    }

    private var paper: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if !model.ready {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.title2)
                    Text("Your library could not be loaded.")
                    Button("Recover Previous Save") { model.recoverPresented = true }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.selected == nil {
                VStack(spacing: 12) {
                    Text("A little room to think.").font(.system(size: 23, weight: .light))
                    Button("Start a note") { model.startNewNote() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if model.findPresented { findBar }
                HStack {
                    Text(model.selected?.deleted != nil ? "THE VOID" : model.analysis.mode.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(accent)
                    Spacer()
                    if model.selected?.deleted != nil { Button("Restore Note") { if let id = model.selectedID { model.restore(id) } } }
                    else { slotMenu }
                }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)
                if model.selected?.deleted != nil {
                    ScrollView { Text(model.draft).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(24) }
                } else {
                    InlineNoteEditor(text: model.draft, textColor: model.editorTextColor, autoFocus: true,
                                     onEdit: model.inlineEdited, onSave: model.saveCurrent,
                                     fontSize: model.library.fontSize, focusToken: model.focusToken,
                                     analysis: model.analysis,
                                     onCommand: model.command, onNavigate: model.navigate, onEscape: model.escape,
                                     onImage: model.recognizeImage, onImageFile: model.recognizeFile,
                                     onOpenURL: { model.context?.open($0) })
                    .padding(.horizontal, 18).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if model.library.linedPaper {
                            Canvas { context, size in
                                var path = Path()
                                for y in stride(from: 28.0, to: size.height, by: model.library.fontSize * 1.5) {
                                    path.move(to: CGPoint(x: 24, y: y)); path.addLine(to: CGPoint(x: size.width - 24, y: y))
                                }
                                context.stroke(path, with: .color(secondary.opacity(0.1)), lineWidth: 0.5)
                            }
                        }
                    }
                    .onDrop(of: [UTType.image.identifier, UTType.fileURL.identifier], isTargeted: nil) { providers in
                        guard let provider = providers.first else { return false }
                        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                                if let url { Task { @MainActor in model.recognizeFile(url) } }
                            }
                        } else {
                            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                                if let data { Task { @MainActor in model.recognizeImage(data) } }
                            }
                        }
                        return true
                    }
                }
                if model.analysis.mode != "math" && !model.analysis.results.isEmpty && model.selected?.deleted == nil {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(model.analysis.results.enumerated()), id: \.offset) { _, result in
                                Text(result).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.frame(maxHeight: 140).background(accent.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 24).padding(.bottom, 12)
                }
                if model.scope == "slots" {
                    HStack(spacing: 8) {
                        ForEach(1...9, id: \.self) { slot in
                            Button { model.jumpSlot(slot) } label: {
                                Text("\(slot)").font(.system(size: 11, design: .monospaced))
                                    .frame(width: 25, height: 25)
                                    .background(model.selected?.slot == slot ? accent.opacity(0.2) : secondary.opacity(0.07), in: Circle())
                            }.buttonStyle(.plain).help("Permanent slot \(slot)")
                        }
                    }.frame(maxWidth: .infinity).padding(.bottom, 12)
                }
                if model.stopwatchStart != nil || model.stopwatchPaused {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        HStack {
                            Image(systemName: "stopwatch")
                            Text(Duration.seconds(model.stopwatchElapsed + (model.stopwatchStart.map { timeline.date.timeIntervalSince($0) } ?? 0)).formatted(.time(pattern: .hourMinuteSecond)))
                                .monospacedDigit()
                            Button(model.stopwatchPaused ? "Resume" : "Pause") { model.toggleStopwatch() }
                            Button("Stop") { _ = model.command("timer s") }
                        }.font(.system(size: 12)).padding(.horizontal, 24).padding(.bottom, 10)
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var slotMenu: some View {
        Menu {
            Button("Keep in Scratch Stack") { model.setSlot(nil) }
            ForEach(1...9, id: \.self) { slot in Button("Keep in Slot \(slot)") { model.setSlot(slot) } }
        } label: {
            Label(model.selected?.slot.map { "Slot \($0)" } ?? "Keep", systemImage: model.selected?.slot == nil ? "pin" : "pin.fill")
                .font(.system(size: 11))
        }.menuStyle(.borderlessButton).fixedSize()
    }
    private var findBar: some View {
        HStack(spacing: 6) {
            TextField("Find", text: $model.findText)
            TextField("Replace", text: $model.replacement)
            Toggle("Aa", isOn: $model.caseSensitive).toggleStyle(.button)
            Button("Replace All", action: model.replaceAll).disabled(model.findText.isEmpty)
            Button { model.findPresented = false } label: { Image(systemName: "xmark") }
        }.textFieldStyle(.roundedBorder).font(.system(size: 11)).padding(10)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            Text(model.isDirty ? "Saving…" : "Saved on this Mac").font(.system(size: 10)).foregroundStyle(secondary)
            Spacer()
            if model.autoPaste {
                Button { model.stopCapture() } label: { Label("Stop AutoPaste", systemImage: "clipboard.fill") }.foregroundStyle(accent)
            } else {
                Text(model.analysis.summary).font(.system(size: 10)).foregroundStyle(secondary)
            }
            Button { model.copyDraft() } label: { Image(systemName: "doc.on.doc") }.help("Copy note").disabled(model.selected == nil)
            Button { model.beginImport() } label: { Image(systemName: "square.and.arrow.down") }.help("Import Notes").disabled(!model.ready)
        }.buttonStyle(.borderless).font(.system(size: 11)).padding(.horizontal, 16).padding(.vertical, 10)
    }
}

private struct ImportNotesView: View {
    @ObservedObject var model: AntinoteModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Import Notes", systemImage: "square.and.arrow.down").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Done") { model.cancelImport() }.keyboardShortcut(.cancelAction)
            }
            Text("Bring your scratch notes into Vehla.").foregroundStyle(.secondary)
            if model.importing { ProgressView("Looking for notes…").frame(maxWidth: .infinity, minHeight: 180) }
            else if let preview = model.importPreview {
                Text(preview.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                if !preview.notes.isEmpty {
                    HStack {
                        Text("\(preview.notes.count) notes · \(preview.source)").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Select All") { model.importSelection = Set(preview.notes.filter { !model.library.importedKeys.contains($0.importKey ?? "") }.map(\.id)) }
                        Button("None") { model.importSelection = [] }
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(preview.notes) { note in
                                let imported = model.library.importedKeys.contains(note.importKey ?? "")
                                Toggle(isOn: Binding(get: { model.importSelection.contains(note.id) }, set: { checked in
                                    if checked { model.importSelection.insert(note.id) } else { model.importSelection.remove(note.id) }
                                })) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(note.title).lineLimit(1)
                                        Text(imported ? "Already imported — local edits are preserved" : note.preview).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }.disabled(imported)
                            }
                        }.padding(8)
                    }.frame(minHeight: 140, maxHeight: 280)
                }
            } else { Text("No import is ready. Choose a backup or exported files below.").foregroundStyle(.secondary) }
            if let status = model.status, model.statusIsError {
                Text(status).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button("Open Full Disk Access Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { model.context?.open(url) }
                }
            }
            HStack {
                Button("Choose Files…") { model.chooseImportFiles() }.disabled(model.importing)
                Button("Scan Again") { model.beginImport() }.disabled(model.importing)
                Spacer()
                Button("Import \(model.importSelection.count) Notes") { model.confirmImport() }
                    .buttonStyle(.borderedProminent).disabled(model.importing || model.importSelection.isEmpty || model.importPreview == nil)
            }
            Text("Accepts Antinote SQLite databases and backups, UTF-8 text, Markdown, and Vehla library JSON. Occupied slots import into the scratch stack.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(24).frame(width: 580)
    }
}
