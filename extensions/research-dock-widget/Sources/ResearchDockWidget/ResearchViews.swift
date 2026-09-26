import SwiftUI
import AppKit
import VehlaDockWidgetSDK

// Explicitly use the property wrapper; some beta SDKs also export a State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

extension ResearchModel {
    var primaryColor: Color { Color(nsColor: theme?.primaryTextColor ?? .labelColor) }
    var secondaryColor: Color { Color(nsColor: theme?.secondaryTextColor ?? .secondaryLabelColor) }
    var accentColor: Color { .white }
}

private struct ResearchActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.white.opacity(configuration.isPressed ? 0.7 : 0.95), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Plain native editing with a shared, translucent field surface.
private struct ResearchTextField: View {
    let label: String
    let placeholder: String
    let icon: String
    @Binding var text: String
    var submit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).frame(width: 16)
                TextField(label, text: $text, prompt: Text(placeholder).foregroundStyle(.white.opacity(0.45)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .tint(.white)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit(submit)
                    .accessibilityLabel(label)
                if !text.isEmpty {
                    Button { text = ""; focused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5))
                    }.buttonStyle(.plain).accessibilityLabel("Clear " + label.lowercased())
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color.white.opacity(focused ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(focused ? 0.65 : 0.16), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { focused = true }
        }
    }
}

struct ResearchRootView: View {
    let surface: VehlaDockWidgetSurface
    @ObservedObject var model: ResearchModel
    var body: some View {
        Group {
            switch surface {
            case .compact:
                VStack(spacing: 4) {
                    Image(systemName: "books.vertical.fill").font(.system(size: 20))
                    Text(model.unreadCount == 0 ? "Research" : "\(model.unreadCount) unread").font(.system(size: 9, weight: .semibold))
                }.foregroundStyle(Color(nsColor: model.theme?.tileTextColor ?? .labelColor))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
            case .inline:
                HStack(spacing: 8) {
                    Image(systemName: "books.vertical.fill")
                    VStack(alignment: .leading) {
                        Text(model.library.articles.first { $0.id == model.library.lastArticle }?.title ?? "Your reading queue").font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text("\(model.unreadCount) unread").font(.system(size: 9)).opacity(0.7)
                    }
                    Spacer(minLength: 0)
                    // The host owns popup expansion; selecting Resume prepares its reader.
                    Button(action: model.resume) { Image(systemName: "book") }.buttonStyle(.plain).help("Resume in the popup")
                }.padding(10).foregroundStyle(Color(nsColor: model.theme?.tileTextColor ?? .labelColor))
            case .popup: ResearchPopup(model: model)
            @unknown default: EmptyView()
            }
        }
    }
}

private struct ResearchPopup: View {
    @ObservedObject var model: ResearchModel
    var body: some View {
        VStack(spacing: 0) {
            if model.capturePresented { ScrollView { CaptureForm(model: model) } }
            else if model.settingsPresented { ScrollView { LibrarySettings(model: model) } }
            else if let item = model.current { ReaderPage(model: model, article: item) }
            else { QueuePage(model: model) }
            if let error = model.error {
                HStack { Text(error).font(.caption); Spacer(); Button("Dismiss") { model.error = nil } }.padding(12)
            }
            if let incoming = model.pendingImport {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Restore \(incoming.articles.count) articles and \(incoming.collections.count) collections?").font(.headline)
                    Text("Replace overwrites the current library. The previous local snapshot remains available for recovery.").font(.caption)
                    HStack {
                        Button("Merge") { model.restore(merge: true) }
                        Button("Replace Library", role: .destructive) { model.restore(merge: false) }
                        Button("Cancel") { model.pendingImport = nil }
                    }
                }.padding(12)
            }
            if let notice = model.notice {
                HStack {
                    Text(notice).font(.caption).lineLimit(3)
                    Spacer()
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
                }.padding(10).background(model.primaryColor.opacity(0.08))
            }
            if model.deleted != nil {
                HStack { Text("Article removed.").font(.caption); Spacer(); Button("Undo", action: model.undoRemove) }.padding(10)
            }
        }
        .background(Color.clear)
        .foregroundStyle(model.primaryColor)
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity, alignment: .top)
        .tint(.white)
        .preferredColorScheme(model.theme?.isDark == true ? .dark : .light)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.showCapture(url.absoluteString); return true
        }
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: String.self) { value, _ in
                guard let value else { return }
                Task { @MainActor in model.showCapture(value) }
            }
            return true
        }
    }
}

private struct QueuePage: View {
    @ObservedObject var model: ResearchModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Research").font(.system(size: 20, weight: .semibold))
                    Text("Saved articles and reading queue").font(.caption).foregroundStyle(model.secondaryColor)
                }
                Spacer()
                Button { model.showCapture() } label: { Label("Add Link", systemImage: "plus") }.buttonStyle(ResearchActionStyle()).keyboardShortcut("n", modifiers: .command).disabled(!model.ready)
            }.padding(16)
            CollectionChoices(model: model, selection: $model.collection, includeAll: true).padding(.horizontal, 16)
            HStack {
                ForEach(QueueSort.allCases, id: \.self) { sort in
                    Button { model.sort = sort } label: {
                        Text(sort.rawValue).font(.caption).opacity(model.sort == sort ? 1 : 0.55)
                    }.buttonStyle(.plain).accessibilityAddTraits(model.sort == sort ? .isSelected : [])
                }
                Spacer()
            }.padding(.horizontal, 16).padding(.top, 8)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(model.secondaryColor)
                TextField("Search titles, sites, and saved text", text: $model.query).textFieldStyle(.plain)
                if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Clear search") }
            }.padding(10).background(model.primaryColor.opacity(0.08), in: Capsule()).padding(.horizontal, 16).padding(.vertical, 12)
            HStack(spacing: 3) {
                ForEach(QueueFilter.allCases, id: \.self) { filter in
                    Button { model.filter = filter } label: {
                        Text(filter.rawValue).font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .foregroundStyle(model.filter == filter ? Color.black.opacity(0.85) : Color.white.opacity(0.8))
                            .background(model.filter == filter ? Color.white.opacity(0.95) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(model.filter == filter ? .isSelected : [])
                }
            }.padding(3).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                .padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            if !model.ready {
                ContentUnavailableView("Library unavailable", systemImage: "books.vertical", description: Text("Loading your library. If a saved file needs recovery, open Library Settings below.")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visible.isEmpty {
                ContentUnavailableView(model.library.articles.isEmpty ? "Your next read starts here" : "No matching articles", systemImage: "book.closed", description: Text(model.library.articles.isEmpty ? "Save a link or drop one here. Your articles will be waiting when you have a moment." : "Try a different collection, filter, or search.")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(model.visible) { item in
                            SwipeDeleteRow(remove: { model.remove(item) }) {
                                ArticleRow(model: model, article: item)
                            }
                            .id(item.id)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onAppear { if let id = model.library.lastArticle { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            Divider()
            HStack {
                Text("\(model.visible.count) articles").font(.caption).foregroundStyle(model.secondaryColor)
                if !model.fetching.isEmpty { ProgressView().controlSize(.small); Text("Saving readable text…").font(.caption).foregroundStyle(model.secondaryColor) }
                Spacer()
                Button { model.settingsPresented = true } label: { Label("Library", systemImage: "slider.horizontal.3") }.buttonStyle(.plain)
            }.padding(14)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct ArticleRow: View {
    @ObservedObject var model: ResearchModel
    let article: Article
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 8).fill(model.primaryColor.opacity(0.08)).frame(width: 40, height: 48)
                .overlay(Image(systemName: article.state == .finished ? "checkmark" : "doc.text").foregroundStyle(model.secondaryColor))
            Button { model.open(article.id) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(article.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(model.primaryColor).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(article.domain)
                        if let content = model.library.contents[article.id] { Text("· \(content.minutes) min") }
                        if article.state == .reading { Text("· Reading") }
                        if model.fetching.contains(article.id) { ProgressView().controlSize(.mini) }
                        else if article.fetchError != nil { Image(systemName: "exclamationmark.circle").help(article.fetchError ?? "") }
                    }.font(.caption).foregroundStyle(model.secondaryColor).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { model.edit(article.id) { $0.favorite.toggle() } } label: { Image(systemName: article.favorite ? "star.fill" : "star").foregroundStyle(article.favorite ? model.accentColor : model.secondaryColor) }.buttonStyle(.plain).help(article.favorite ? "Remove favorite" : "Favorite")
        }.padding(18)

    }
}

private struct CollectionChoices: View {
    @ObservedObject var model: ResearchModel
    @Binding var selection: String
    var includeAll = false
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if includeAll { choice("All collections", "all") }
                choice("Inbox", "inbox")
                ForEach(model.library.collections) { choice($0.name, $0.id.uuidString) }
            }
        }
    }
    private func choice(_ name: String, _ id: String) -> some View {
        Button { selection = id } label: {
            Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.white.opacity(selection == id ? 0.22 : 0.06), in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selection == id ? .isSelected : [])
    }
}

private struct ArticleActions: View {
    @ObservedObject var model: ResearchModel
    let article: Article
    @ViewState<String> private var title = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                ResearchTextField(label: "Article title", placeholder: "Give this article a title", icon: "text.alignleft", text: $title)
                Button("Save Title") {
                    let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { model.edit(article.id) { $0.title = value; $0.customTitle = true } }
                }
            }
            Text("Collection").font(.caption)
            CollectionChoices(model: model, selection: Binding(get: { article.collectionID?.uuidString ?? "inbox" }, set: { value in model.edit(article.id) { $0.collectionID = UUID(uuidString: value) } }))
            HStack {
                ForEach(ReadingState.allCases, id: \.self) { state in
                    Button(state.rawValue.capitalized) { model.edit(article.id) { $0.state = state } }
                        .opacity(article.state == state ? 1 : 0.55)
                }
            }
            HStack {
                Button("Copy Link") { model.context?.copyText(article.url.absoluteString) }
                Button("Copy Markdown") { model.context?.copyText(ResearchExporter.markdownLink(article)) }
                Button(article.archived ? "Unarchive" : "Archive") { model.edit(article.id) { $0.archived.toggle() } }
                Button("Remove", role: .destructive) { model.remove(article) }
            }
        }.padding(16).onAppear { title = article.title }
    }
}

private struct ReaderPage: View {
    @ObservedObject var model: ResearchModel
    let article: Article
    @ViewState<Bool> private var showActions = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.selected = nil } label: { Label("Queue", systemImage: "chevron.left") }.buttonStyle(.plain).keyboardShortcut(.leftArrow, modifiers: .command)
                Spacer()
                Button { model.edit(article.id) { $0.favorite.toggle() } } label: { Image(systemName: article.favorite ? "star.fill" : "star") }.buttonStyle(.plain).help("Toggle favorite")
                Button("Open Original") { model.context?.open(article.url) }.buttonStyle(.bordered)
                Button { showActions.toggle() } label: { Image(systemName: showActions ? "xmark" : "slider.horizontal.3") }.buttonStyle(.plain).help("Article details")
            }.padding(16)
            if showActions { ScrollView { ArticleActions(model: model, article: article) }.frame(maxHeight: 220) }
            VStack(alignment: .leading, spacing: 7) {
                Text(article.domain.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(model.secondaryColor)
                Text(article.title).font(.system(size: 23, weight: .semibold)).lineLimit(4).textSelection(.enabled)
                if let content = model.library.contents[article.id] {
                    Text([content.author, "\(content.minutes) min read", "Saved \(content.fetchedAt.formatted(date: .abbreviated, time: .omitted))"].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(model.secondaryColor)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 16)
            if let error = article.fetchError { Text(error).font(.caption).foregroundStyle(model.secondaryColor).padding(.horizontal, 24).padding(.bottom, 10) }
            Divider()
            if let content = model.library.contents[article.id] {
                ArticleReader(article: article, content: content, typeSize: model.library.typeSize, dark: model.theme?.isDark == true, textColor: model.theme?.primaryTextColor ?? .labelColor, linkColor: model.theme?.accentColor ?? .linkColor, onProgress: { block, offset in model.progress(article.id, revision: content.revision, block: block, offset: offset) }, open: { model.context?.open($0) })
                    .id(article.id)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "book.closed").font(.system(size: 36)).foregroundStyle(model.secondaryColor)
                    Text(model.fetching.contains(article.id) ? "Preparing your article…" : "Your link is saved").font(.headline)
                    Text("Download a clean text copy for offline reading. Some websites can only be read in your browser.").font(.callout).foregroundStyle(model.secondaryColor).multilineTextAlignment(.center).frame(maxWidth: 340)
                    if model.fetching.contains(article.id) { ProgressView() }
                    else { Button("Download Article") { model.refresh(article.id) }.buttonStyle(ResearchActionStyle()) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button { model.mutate { $0.typeSize = max(13, $0.typeSize - 1) } } label: { Image(systemName: "textformat.size.smaller") }.help("Smaller text")
                Button { model.mutate { $0.typeSize = min(25, $0.typeSize + 1) } } label: { Image(systemName: "textformat.size.larger") }.help("Larger text")
                Button { model.refresh(article.id) } label: { Image(systemName: "arrow.clockwise") }.disabled(model.fetching.contains(article.id)).help("Refresh cached text")
                Spacer()
                Button(article.state == .finished ? "Mark Unread" : "Mark Finished") { model.edit(article.id) { $0.state = article.state == .finished ? .unread : .finished } }.buttonStyle(ResearchActionStyle())
            }.padding(14)
        }

    }
}

private struct CaptureForm: View {
    @ObservedObject var model: ResearchModel
    @ViewState<[(String, String)]> private var clips: [(String, String)] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save something worth reading").font(.title2.weight(.semibold))
            ResearchTextField(label: "Article link", placeholder: "https://example.com/article", icon: "link", text: $model.draftURL, submit: model.saveCapture)
            HStack {
                Button("Paste Link") { model.draftURL = NSPasteboard.general.string(forType: .string) ?? "" }
                Button("Recent Clipboard Links") { clips = model.recentLinks() }.disabled(model.context?.clipboard == nil)
            }
            if !clips.isEmpty {
                ScrollView { VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(clips.enumerated()), id: \.offset) { _, clip in
                        Button { model.draftURL = clip.0 } label: { VStack(alignment: .leading) { Text(clip.0).lineLimit(1); Text(clip.1).font(.caption).foregroundStyle(model.secondaryColor) } }.buttonStyle(.plain)
                    }
                } }.frame(maxHeight: 150)
            }
            Text("Collection").font(.caption)
            CollectionChoices(model: model, selection: $model.draftCollection)
            Text("The link saves immediately. Research then downloads readable text from the public website; no browser login or AI is used.").font(.caption).foregroundStyle(model.secondaryColor)
            HStack { Spacer(); Button("Cancel") { model.capturePresented = false }.keyboardShortcut(.cancelAction); Button("Save Link", action: model.saveCapture).buttonStyle(ResearchActionStyle()).keyboardShortcut(.defaultAction).disabled((try? CaptureService.url(model.draftURL)) == nil || !model.ready) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(model.primaryColor)
            .tint(.white)
            .onDisappear { model.context?.clipboard?.setActiveViewer(false) }
    }
}

private struct LibrarySettings: View {
    @ObservedObject var model: ResearchModel
    @ViewState<String> private var name = ""
    @ViewState<UUID?> private var renameID: UUID?
    @ViewState<ReadingCollection?> private var deleteGroup: ReadingCollection?
    @ViewState<Bool> private var confirmRecovery = false
    @ViewState<String> private var filePath = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Your library").font(.title2.weight(.semibold)); Spacer(); Button("Done") { model.settingsPresented = false }.keyboardShortcut(.cancelAction) }
            Text("Collections").font(.headline)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.library.collections) { group in
                        HStack {
                            Image(systemName: "folder"); Text(group.name); Spacer()
                            Button("Rename") { renameID = group.id; name = group.name }
                            Button { deleteGroup = group } label: { Image(systemName: "trash") }.help("Delete collection; keep articles in Inbox")
                        }
                    }
                }
            }.frame(maxHeight: 160)
            HStack(alignment: .bottom) {
                ResearchTextField(label: renameID == nil ? "New collection" : "Collection name", placeholder: "e.g. Design & inspiration", icon: "folder", text: $name)
                Button(renameID == nil ? "Create" : "Rename") { model.saveCollection(name: name, id: renameID); name = ""; renameID = nil }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.ready)
                if renameID != nil { Button("Cancel") { renameID = nil; name = "" } }
            }
            if let group = deleteGroup {
                Text("Delete \(group.name)? Its articles will move to Inbox.").font(.caption)
                HStack {
                    Button("Delete Collection", role: .destructive) { model.removeCollection(group.id); deleteGroup = nil }
                    Button("Cancel") { deleteGroup = nil }
                }
            }
            Divider()
            Text("Backup & export").font(.headline)
            ResearchTextField(label: "Backup file location", placeholder: "~/Downloads/Research.json", icon: "doc", text: $filePath)
            Text("Enter a new file path to export, or an existing JSON backup path to restore. Existing files are never overwritten.").font(.caption)
            HStack { Button("Export Reading List") { model.export(backup: false, path: filePath) }; Button("Back Up Library") { model.export(backup: true, path: filePath) } }.disabled(!model.ready || filePath.isEmpty)
            Button("Load Backup") { model.importBackup(path: filePath) }.disabled(filePath.isEmpty)
            Text("Backups include cached article text and reading progress. Save them outside the extension folder: uninstalling removes the private library.").font(.caption).foregroundStyle(model.secondaryColor)
            Divider()
            Button("Recover Previous Local Snapshot…") { confirmRecovery = true }
            Text("Use recovery only after an unwanted change or a damaged library. It restores the preceding successful save.").font(.caption).foregroundStyle(model.secondaryColor)
            if confirmRecovery {
                Text("Restore the previous saved snapshot? This replaces the current library.").font(.caption)
                HStack {
                    Button("Recover Previous Snapshot", role: .destructive) { model.recover(); confirmRecovery = false }
                    Button("Cancel") { confirmRecovery = false }
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(model.primaryColor)
            .tint(.white)
    }
}
