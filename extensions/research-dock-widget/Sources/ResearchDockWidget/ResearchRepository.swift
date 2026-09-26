import Foundation

actor ResearchRepository {
    private let root: URL
    private var cached: ResearchLibrary?
    private var indexBytes: Data?
    init(root: URL) { self.root = root }
    private var index: URL { root.appendingPathComponent("library.json") }
    private var backup: URL { root.appendingPathComponent("library.previous.json") }
    private func contentURL(_ id: UUID, _ revision: UUID) -> URL {
        root.appendingPathComponent("content/\(id.uuidString)-\(revision.uuidString).json")
    }
    func load() throws -> ResearchLibrary {
        if let cached { return cached }
        guard FileManager.default.fileExists(atPath: index.path) else {
            if FileManager.default.fileExists(atPath: backup.path) { throw ResearchError.message("Library index is missing. Recover the previous library from Settings.") }
            let empty = ResearchLibrary(); cached = empty; return empty
        }
        let library = try read(index)
        indexBytes = try Data(contentsOf: index)
        cached = library; return library
    }
    private func read(_ url: URL) throws -> ResearchLibrary {
        var library = try JSONDecoder().decode(ResearchLibrary.self, from: Data(contentsOf: url))
        library.contents = [:]
        for item in library.articles {
            if let revision = item.contentRevision {
                library.contents[item.id] = try JSONDecoder().decode(ArticleContent.self, from: Data(contentsOf: contentURL(item.id, revision)))
            }
        }
        try library.validate(); return library
    }
    func update(_ mutation: @Sendable (inout ResearchLibrary) throws -> Void) throws -> ResearchLibrary {
        var next = try load()
        try mutation(&next)
        if next == cached { return next }
        next.revision += 1
        try commit(next)
        return next
    }
    private func commit(_ next: ResearchLibrary, preservePrevious: Bool = true) throws {
        try next.validate()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("content"), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for (id, content) in next.contents {
            if cached?.contents[id]?.revision == content.revision { continue }
            let target = contentURL(id, content.revision)
            if !fm.fileExists(atPath: target.path) { try encoder.encode(content).write(to: target, options: .atomic) }
        }
        if preservePrevious, fm.fileExists(atPath: index.path) {
            // Only retain a known-valid previous snapshot, never a corrupt index.
            let currentBytes = try Data(contentsOf: index)
            if currentBytes != indexBytes { _ = try read(index) }
            try currentBytes.write(to: backup, options: .atomic)
        }
        var metadata = next; metadata.contents = [:]
        let bytes = try encoder.encode(metadata)
        try bytes.write(to: index, options: .atomic)
        indexBytes = bytes
        let contentChanged = cached?.articles.map(\.contentRevision) != next.articles.map(\.contentRevision)
        cached = next
        if contentChanged { pruneContent() }
    }
    private func pruneContent() {
        // Both snapshots retain their immutable content revisions for recovery.
        var keep = Set<String>()
        for snapshot in [index, backup] {
            guard let data = try? Data(contentsOf: snapshot), let library = try? JSONDecoder().decode(ResearchLibrary.self, from: data) else { continue }
            for item in library.articles { if let revision = item.contentRevision { keep.insert(contentURL(item.id, revision).lastPathComponent) } }
        }
        let folder = root.appendingPathComponent("content")
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
    func recoverPrevious() throws -> ResearchLibrary {
        var previous = try read(backup)
        previous.revision = max(previous.revision, cached?.revision ?? 0) + 1
        if FileManager.default.fileExists(atPath: index.path) {
            try Data(contentsOf: index).write(to: root.appendingPathComponent("library.damaged-\(UUID().uuidString).json"), options: .atomic)
        }
        try commit(previous, preservePrevious: false); return previous
    }
    func restore(_ incoming: ResearchLibrary, merge: Bool) throws -> ResearchLibrary {
        try incoming.validate()
        var next: ResearchLibrary
        if merge {
            next = try load()
            var mapping: [UUID: UUID] = [:]
            for collection in incoming.collections {
                if let existing = next.collections.first(where: { $0.name == collection.name }) { mapping[collection.id] = existing.id }
                else { let added = ReadingCollection(name: collection.name); next.collections.append(added); mapping[collection.id] = added.id }
            }
            var keys = try Set(next.articles.map { try CaptureService.key($0.url) })
            for article in incoming.articles where !keys.contains(try CaptureService.key(article.url)) {
                var added = article; added.id = UUID(); added.collectionID = article.collectionID.flatMap { mapping[$0] }
                if var content = incoming.contents[article.id] { content.revision = UUID(); next.contents[added.id] = content; added.contentRevision = content.revision }
                next.articles.append(added); keys.insert(try CaptureService.key(added.url))
            }
        } else {
            next = incoming
            // Imported revision identifiers must never alias existing local content bytes.
            for id in Array(next.contents.keys) {
                next.contents[id]?.revision = UUID()
                if let i = next.articles.firstIndex(where: { $0.id == id }) { next.articles[i].contentRevision = next.contents[id]?.revision }
            }
        }
        next.revision = max((try? load().revision) ?? 0, next.revision) + 1
        // Replacement can explicitly recover an unreadable library, preserving its bytes.
        let readable = (try? read(index)) != nil
        if !readable, FileManager.default.fileExists(atPath: index.path) {
            try Data(contentsOf: index).write(to: root.appendingPathComponent("library.damaged-\(UUID().uuidString).json"), options: .atomic)
        }
        try commit(next, preservePrevious: readable); return next
    }
}
