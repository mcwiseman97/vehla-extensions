import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VehlaDockWidgetSDK

@MainActor
final class ResearchModel: ObservableObject {
    @Published private(set) var library = ResearchLibrary()
    @Published private(set) var ready = false
    @Published var error: String?
    @Published var notice: String? {
        didSet {
            noticeDismissal?.cancel()
            guard notice != nil else { return }
            let delay = noticeLifetime
            noticeDismissal = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                self?.notice = nil
            }
        }
    }
    @Published var selected: UUID?
    @Published var collection = "all"
    @Published var filter: QueueFilter = .all
    @Published var sort: QueueSort = .newest
    @Published var query = ""
    @Published var capturePresented = false
    @Published var settingsPresented = false
    @Published var draftURL = ""
    @Published var draftCollection = "inbox"
    @Published var theme: VehlaDockWidgetTheme?
    @Published private(set) var fetching = Set<UUID>()
    @Published private(set) var deleted: (Article, ArticleContent?)? {
        didSet {
            undoDismissal?.cancel()
            guard deleted != nil else { return }
            let delay = undoLifetime
            undoDismissal = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                self?.deleted = nil
            }
        }
    }
    @Published var pendingImport: ResearchLibrary?
    private(set) var context: VehlaDockWidgetContext?
    private var repository: ResearchRepository?
    private var active = true
    private var loading = false
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var tokens: [UUID: UUID] = [:]
    private var queue: [UUID] = []
    private var progressJobs: [UUID: Task<Void, Never>] = [:]
    private var noticeDismissal: Task<Void, Never>?
    private var undoDismissal: Task<Void, Never>?
    private let noticeLifetime: Duration
    private let undoLifetime: Duration
    private let fetchArticle: @Sendable (URL) async throws -> ArticleContent

    init(noticeLifetime: Duration = .seconds(4), undoLifetime: Duration = .seconds(8), fetchArticle: @escaping @Sendable (URL) async throws -> ArticleContent = { try await ArticleFetcher().fetch($0) }) {
        self.noticeLifetime = noticeLifetime
        self.undoLifetime = undoLifetime
        self.fetchArticle = fetchArticle
    }

    var current: Article? { library.articles.first { $0.id == selected } }
    var unreadCount: Int { library.articles.filter { !$0.archived && $0.state == .unread }.count }
    var visible: [Article] {
        library.articles.filter { item in
            let inGroup = collection == "all" || (collection == "inbox" ? item.collectionID == nil : item.collectionID?.uuidString == collection)
            let inFilter: Bool
            switch filter {
            case .all: inFilter = !item.archived
            case .unread: inFilter = !item.archived && item.state == .unread
            case .reading: inFilter = !item.archived && item.state == .reading
            case .finished: inFilter = !item.archived && item.state == .finished
            case .favorites: inFilter = !item.archived && item.favorite
            case .archived: inFilter = item.archived
            }
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let match = needle.isEmpty || [item.title, item.domain, library.contents[item.id]?.plainText ?? ""].contains { $0.localizedCaseInsensitiveContains(needle) }
            return inGroup && inFilter && match
        }.sorted {
            switch sort {
            case .newest: return $0.addedAt > $1.addedAt
            case .oldest: return $0.addedAt < $1.addedAt
            case .recent: return ($0.lastOpened ?? $0.addedAt) > ($1.lastOpened ?? $1.addedAt)
            }
        }
    }
    func configure(_ context: VehlaDockWidgetContext) {
        self.context = context; theme = context.theme
        if repository == nil { repository = ResearchRepository(root: context.dataDirectory) }
        start()
    }
    func start() {
        active = true
        guard !ready, !loading, let repository else { pump(); return }
        loading = true
        Task {
            do { accept(try await repository.load()); ready = true }
            catch { self.error = "Could not load your library: \(error.localizedDescription)" }
            loading = false
        }
    }
    func stop() {
        active = false
        for task in jobs.values { task.cancel() }
        jobs.removeAll(); tokens.removeAll(); queue.removeAll(); fetching.removeAll()
        // Accepted edits and debounced progress saves are intentionally not cancelled.
        context?.clipboard?.setActiveViewer(false)
    }
    func accept(_ state: ResearchLibrary) {
        guard state.revision >= library.revision || !ready else { return }
        library = state
        if let selected, !state.articles.contains(where: { $0.id == selected }) { self.selected = nil }
        context?.invalidate()
    }
    func mutate(_ body: @escaping @Sendable (inout ResearchLibrary) throws -> Void, then: (@MainActor () -> Void)? = nil) {
        guard ready, let repository else { error = "The library is not ready. Use Settings to recover or restore it."; return }
        Task {
            do { accept(try await repository.update(body)); then?() }
            catch { self.error = "Could not save: \(error.localizedDescription)" }
        }
    }
    func edit(_ id: UUID, _ body: @escaping @Sendable (inout Article) -> Void) {
        mutate { state in if let i = state.articles.firstIndex(where: { $0.id == id }) { body(&state.articles[i]) } }
    }
    func showCapture(_ url: String = "") {
        draftURL = url; draftCollection = collection == "all" ? "inbox" : collection; capturePresented = true
    }
    func saveCapture() {
        do {
            let url = try CaptureService.url(draftURL), key = try CaptureService.key(url)
            if let existing = library.articles.first(where: { (try? CaptureService.key($0.url)) == key }) {
                capturePresented = false; open(existing.id); notice = "Already saved. You can move it or restore it from the article menu."; return
            }
            let id = UUID(), group = UUID(uuidString: draftCollection)
            let article = Article(id: id, collectionID: group, url: url, title: url.host ?? url.absoluteString)
            mutate({ state in
                guard !state.articles.contains(where: { (try? CaptureService.key($0.url)) == key }) else { return }
                var item = article
                if !state.collections.contains(where: { $0.id == group }) { item.collectionID = nil }
                state.articles.insert(item, at: 0)
            }, then: { [weak self] in
                guard let self else { return }; self.capturePresented = false; self.notice = "Saved to your reading queue."
                self.refresh(id)
            })
        } catch { self.error = error.localizedDescription }
    }
    func open(_ id: UUID) {
        selected = id
        mutate { state in
            guard let i = state.articles.firstIndex(where: { $0.id == id }) else { return }
            state.lastArticle = id; state.articles[i].lastOpened = Date()
            if state.articles[i].state == .unread { state.articles[i].state = .reading }
        }
    }
    func resume() { if let id = library.lastArticle { open(id) } }
    func refresh(_ id: UUID) {
        guard library.articles.contains(where: { $0.id == id }), !fetching.contains(id) else { return }
        guard active else { notice = "Saved. Open the widget and choose Download to read offline."; return }
        fetching.insert(id); queue.append(id); pump()
    }
    private func pump() {
        while active, jobs.count < 2, !queue.isEmpty {
            let id = queue.removeFirst()
            guard let item = library.articles.first(where: { $0.id == id }) else { fetching.remove(id); continue }
            let token = UUID(); tokens[id] = token
            let fetch = fetchArticle
            jobs[id] = Task { [weak self] in
                let work = Task.detached(priority: .utility) { try await fetch(item.url) }
                do {
                    let content = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                    guard let self, self.tokens[id] == token, !Task.isCancelled else { return }
                    self.mutate { state in
                        guard let i = state.articles.firstIndex(where: { $0.id == id }) else { return }
                        state.contents[id] = content; state.articles[i].contentRevision = content.revision
                        state.articles[i].fetchError = nil
                        if !state.articles[i].customTitle { state.articles[i].title = content.title }
                        if !content.blocks.contains(where: { $0.id == state.articles[i].position }) {
                            state.articles[i].position = nil; state.articles[i].positionOffset = 0
                        }
                    }
                } catch {
                    guard let self, self.tokens[id] == token, !Task.isCancelled else { return }
                    let message = error.localizedDescription
                    self.edit(id) { $0.fetchError = message }
                }
                guard let self, self.tokens[id] == token else { return }
                self.jobs[id] = nil; self.tokens[id] = nil; self.fetching.remove(id); self.pump()
            }
        }
    }
    func progress(_ id: UUID, revision: UUID, block: String, offset: Double) {
        progressJobs[id]?.cancel()
        guard let repository else { return }
        progressJobs[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                let state = try await repository.update { state in
                    guard let i = state.articles.firstIndex(where: { $0.id == id }), state.articles[i].contentRevision == revision else { return }
                    state.articles[i].position = block; state.articles[i].positionOffset = min(1, max(0, offset))
                }
                self?.accept(state)
            } catch is CancellationError {} catch { self?.error = "Could not save reading position: \(error.localizedDescription)" }
        }
    }
    func remove(_ item: Article) {
        jobs[item.id]?.cancel(); jobs[item.id] = nil; tokens[item.id] = nil
        queue.removeAll { $0 == item.id }; fetching.remove(item.id)
        let content = library.contents[item.id]
        mutate({ state in
            state.articles.removeAll { $0.id == item.id }; state.contents[item.id] = nil
            if state.lastArticle == item.id { state.lastArticle = nil }
        }, then: { [weak self] in self?.deleted = (item, content); self?.pump() })
    }
    func undoRemove() {
        guard let (article, content) = deleted else { return }
        mutate({ state in
            guard !state.articles.contains(where: { (try? CaptureService.key($0.url)) == (try? CaptureService.key(article.url)) }) else { return }
            var item = article
            if !state.collections.contains(where: { $0.id == item.collectionID }) { item.collectionID = nil }
            state.articles.append(item); state.contents[item.id] = content
        }, then: { [weak self] in
            if self?.deleted?.0.id == article.id { self?.deleted = nil }
        })
    }
    func saveCollection(name: String, id: UUID? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { error = "Use a collection name of 1–120 characters."; return }
        mutate { state in
            if let id, let i = state.collections.firstIndex(where: { $0.id == id }) { state.collections[i].name = name }
            else { state.collections.append(ReadingCollection(name: name)) }
        }
    }
    func removeCollection(_ id: UUID) {
        mutate { state in
            state.collections.removeAll { $0.id == id }
            for i in state.articles.indices where state.articles[i].collectionID == id { state.articles[i].collectionID = nil }
        }
        if collection == id.uuidString { collection = "inbox" }
    }
    private func fileURL(_ path: String) throws -> URL {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw ResearchError.message("Enter an absolute file path, such as ~/Downloads/Research.json.") }
        return URL(fileURLWithPath: expanded)
    }
    func export(backup: Bool, path: String) {
        let url: URL
        do { url = try fileURL(path) } catch { self.error = error.localizedDescription; return }
        let snapshot = library, articles = visible
        Task {
            do {
                try await Task.detached {
                    let data = try backup ? ResearchExporter.backup(snapshot) : Data(ResearchExporter.markdown(articles, title: "Reading list").utf8)
                    try data.write(to: url, options: .withoutOverwriting)
                }.value
                notice = "Export saved to \(url.path)."
            } catch { self.error = error.localizedDescription }
        }
    }
    func importBackup(path: String) {
        let url: URL
        do { url = try fileURL(path) } catch { self.error = error.localizedDescription; return }
        Task {
            do {
                pendingImport = try await Task.detached {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 100 * 1_024 * 1_024 else { throw ResearchError.message("Backup exceeds 100 MiB.") }
                    return try ResearchExporter.decode(Data(contentsOf: url))
                }.value
            } catch { self.error = error.localizedDescription }
        }
    }
    func restore(merge: Bool) {
        guard let incoming = pendingImport, let repository else { return }
        pendingImport = nil; stop()
        Task {
            do { accept(try await repository.restore(incoming, merge: merge)); ready = true; notice = "Library restored."; selected = nil }
            catch { self.error = error.localizedDescription }
            start()
        }
    }
    func recover() {
        guard let repository else { return }
        Task {
            do { accept(try await repository.recoverPrevious()); ready = true; notice = "Recovered the previous saved library." }
            catch { self.error = "Recovery failed: \(error.localizedDescription)" }
        }
    }
    func recentLinks() -> [(String, String)] {
        context?.clipboard?.setActiveViewer(true)
        return (context?.clipboard?.items(offset: 0, limit: 60) ?? []).compactMap { item in
            guard let url = try? CaptureService.url(item.text) else { return nil }
            return (url.absoluteString, item.sourceAppName ?? url.host ?? "Clipboard")
        }
    }
}
