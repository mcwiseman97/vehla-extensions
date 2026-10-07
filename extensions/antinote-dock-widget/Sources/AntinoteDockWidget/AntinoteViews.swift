import AppKit
import SwiftUI
import VehlaDockWidgetSDK

struct AntinoteRootView: View {
    let surface: VehlaDockWidgetSurface
    @ObservedObject var model: AntinoteModel

    var body: some View {
        switch surface {
        case .compact:
            CompactNoteView(model: model)
        case .inline:
            InlineNoteView(model: model)
        case .popup:
            PopupNoteView(model: model)
        @unknown default:
            EmptyView()
        }
    }
}

private struct CompactNoteView: View {
    @ObservedObject var model: AntinoteModel

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: "note.text")
                .font(.system(size: 18, weight: .semibold))
            Text(model.notes.isEmpty ? "Notes" : "\(model.notes.count)")
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Color(nsColor: model.tileTextColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(model.selected?.title ?? "Antinote notes")
    }
}

private struct InlineNoteView: View {
    @ObservedObject var model: AntinoteModel

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.selected?.title ?? (model.loading ? "Loading notes" : "Antinote"))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .opacity(0.72)
            }
            Spacer(minLength: 4)
            if model.selected != nil {
                Button(action: model.openSelected) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Open in Antinote")
            }
        }
        .foregroundStyle(Color(nsColor: model.tileTextColor))
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var subtitle: String {
        if let status = model.status, model.statusIsError { return status }
        if let preview = model.selected?.preview, !preview.isEmpty { return preview }
        if model.notes.isEmpty { return "No notes yet" }
        return "\(model.notes.count) notes"
    }
}

private struct PopupNoteView: View {
    @ObservedObject var model: AntinoteModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                noteList
                    .frame(width: 250)
                Divider()
                editor
            }
            if let status = model.status {
                Divider()
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(model.statusIsError ? Color.orange : secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .foregroundStyle(primary)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Antinote")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button("Open") { model.openSelected() }
                .disabled(model.selected == nil || model.composing)
            Button("New") { model.startNewNote() }
            Button("Save") { model.saveCurrent() }
                .disabled(model.composing
                    ? model.newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    : model.selected == nil || (!model.isDirty && model.conflictText == nil))
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var noteList: some View {
        VStack(spacing: 0) {
            TextField("Search notes", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            if model.loading && model.notes.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visible.isEmpty {
                Text(model.notes.isEmpty ? "No notes yet" : "No matching notes")
                    .font(.system(size: 12))
                    .foregroundStyle(secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if model.composing {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.newNoteTitle)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Text("Not in Antinote yet")
                                    .font(.system(size: 10))
                                    .foregroundStyle(secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                        }
                        ForEach(model.visible) { note in
                            Button {
                                model.select(note.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(note.title)
                                            .font(.system(size: 12, weight: .semibold))
                                            .lineLimit(1)
                                        if model.isUnsaved(note.id) {
                                            Circle().fill(accent).frame(width: 5, height: 5)
                                        }
                                    }
                                    Text(note.slot.map { "Slot \($0)" } ?? note.preview)
                                        .font(.system(size: 10))
                                        .foregroundStyle(secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    note.id == model.selectedID && !model.composing ? accent.opacity(0.16) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.composing {
                Text("New note. Type, then ⌘S (or close the popup) to add it to Antinote.")
                    .font(.system(size: 11))
                    .foregroundStyle(secondary)
                InlineNoteEditor(
                    text: model.newNoteText,
                    textColor: model.editorTextColor,
                    autoFocus: true,
                    onEdit: { model.newNoteEdited($0) },
                    onSave: { model.saveCurrent() }
                )
                .id("new-note")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.5)))
            } else if let conflict = model.conflictText {
                conflictBanner(conflict)
            }
            if model.composing {
                EmptyView()
            } else if model.selected == nil {
                Text("Select a note, or create one in Antinote.")
                    .font(.system(size: 12))
                    .foregroundStyle(secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Click the note and type. ⌘S (or closing the popup) sends it to Antinote.")
                    .font(.system(size: 11))
                    .foregroundStyle(secondary)
                InlineNoteEditor(
                    text: model.draft,
                    textColor: model.editorTextColor,
                    autoFocus: false,
                    onEdit: { model.inlineEdited($0) },
                    onSave: { model.saveCurrent() }
                )
                .id("existing-note")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(secondary.opacity(0.3)))
                HStack {
                    if let modified = model.selected?.modified {
                        Text(relativeDate(modified))
                            .font(.system(size: 10))
                            .foregroundStyle(secondary)
                    }
                    Spacer()
                    Button("Copy") { model.copyDraft() }
                        .disabled(model.draft.isEmpty)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func conflictBanner(_ remote: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Antinote changed this note.")
                .font(.system(size: 11, weight: .semibold))
            Text(remote.split(whereSeparator: \.isNewline).prefix(2).joined(separator: " "))
                .font(.system(size: 11))
                .foregroundStyle(secondary)
                .lineLimit(2)
            HStack {
                Button("Keep mine") { model.keepDraft() }
                Button("Use Antinote’s") { model.takeRemote() }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var primary: Color { Color(nsColor: model.theme?.primaryTextColor ?? .labelColor) }
    private var secondary: Color { Color(nsColor: model.theme?.secondaryTextColor ?? .secondaryLabelColor) }
    private var accent: Color { Color(nsColor: model.theme?.accentColor ?? .controlAccentColor) }
}
