import AppKit
import Foundation
import Testing
import VehlaDockWidgetSDK
@testable import ResearchDockWidget

@MainActor private func awaitState(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ResearchError.message("Timed out waiting for model state")
}
@MainActor private func configure(_ model: ResearchModel, root: URL) {
    let theme = VehlaDockWidgetTheme(isDark: false, accentColor: .systemTeal, primaryTextColor: .labelColor, secondaryTextColor: .secondaryLabelColor, surfaceColor: .windowBackgroundColor)
    model.configure(VehlaDockWidgetContext(packageID: "tests", widgetID: "research", dataDirectory: root, theme: theme, invalidationHandler: {}, actionHandler: { _ in }))
}
@Test @MainActor func capturePersistsBeforeFetchAndSurvivesHiding() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("research-model-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ResearchModel(fetchArticle: { _ in throw ResearchError.message("Fixture unavailable") })
    configure(model, root: root); try await awaitState { model.ready }
    model.draftURL = "https://example.com/read"; model.saveCapture()
    try await awaitState { model.library.articles.first?.fetchError != nil }
    #expect(model.library.articles.count == 1)
    model.draftURL = "https://example.com/read"; model.saveCapture()
    #expect(model.selected == model.library.articles.first?.id)
    let id = model.library.articles[0].id
    model.edit(id) { $0.favorite = true }; model.stop()
    try await awaitState { model.library.articles.first?.favorite == true }
    let persisted = try await ResearchRepository(root: root).load()
    #expect(persisted.articles.count == 1); #expect(persisted.articles[0].favorite)
}
@Test @MainActor func removingCollectionAndUndoingArticlePreservesContent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("research-model-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let group = ReadingCollection(name: "Essays")
    var item = Article(collectionID: group.id, url: URL(string: "https://example.com/read")!, title: "Read")
    let content = ArticleContent(title: item.title, finalURL: item.url, blocks: [ArticleBlock(id: "paragraph", kind: .paragraph, text: "A saved paragraph.")])
    item.contentRevision = content.revision
    _ = try await ResearchRepository(root: root).restore(ResearchLibrary(collections: [group], articles: [item], contents: [item.id: content]), merge: false)
    let model = ResearchModel(); configure(model, root: root); try await awaitState { model.ready }
    model.removeCollection(group.id)
    try await awaitState { model.library.collections.isEmpty }
    #expect(model.library.articles[0].collectionID == nil)
    let saved = model.library.articles[0]
    model.remove(saved); try await awaitState { model.deleted != nil }
    #expect(model.library.articles.isEmpty)
    model.undoRemove(); try await awaitState { !model.library.articles.isEmpty }
    #expect(model.library.contents[saved.id]?.plainText == content.plainText)
    let revision = try #require(model.library.contents[saved.id]?.revision)
    model.progress(saved.id, revision: revision, block: "paragraph", offset: 0.4); model.stop()
    try await awaitState { model.library.articles[0].positionOffset == 0.4 }
    #expect(try await ResearchRepository(root: root).load().articles[0].positionOffset == 0.4)
}

private actor FetchGate {
    var waiting = false
    private var continuation: CheckedContinuation<ArticleContent, Never>?
    func fetch(_ url: URL) async -> ArticleContent {
        waiting = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: ArticleContent(title: "Late response", finalURL: URL(string: "https://example.com/read")!, blocks: [ArticleBlock(id: "body", kind: .paragraph, text: "Late article text.")]))
        continuation = nil
    }
}
@Test @MainActor func hiddenWidgetIgnoresLateDownload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("research-model-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = FetchGate()
    let model = ResearchModel(fetchArticle: { await gate.fetch($0) })
    configure(model, root: root); try await awaitState { model.ready }
    model.draftURL = "https://example.com/read"; model.saveCapture()
    try await awaitState { model.library.articles.count == 1 }
    for _ in 0..<100 { if await gate.waiting { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(await gate.waiting)
    model.stop(); await gate.finish()
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.library.contents.isEmpty); #expect(model.fetching.isEmpty)
    #expect(try await ResearchRepository(root: root).load().articles.count == 1)
}

@Test @MainActor func inlineBackupRoundTripNeverOverwritesFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("research-files-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ResearchModel(); configure(model, root: root)
    try await awaitState { model.ready }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("backup.json")
    model.export(backup: true, path: target.path)
    try await awaitState { model.notice != nil || model.error != nil }
    #expect(model.error == nil)
    let original = try Data(contentsOf: target)
    model.notice = nil
    model.export(backup: false, path: target.path)
    try await awaitState { model.error != nil }
    #expect(try Data(contentsOf: target) == original)
    model.error = nil
    model.importBackup(path: target.path)
    try await awaitState { model.pendingImport != nil || model.error != nil }
    #expect(model.pendingImport != nil)
    model.export(backup: true, path: "relative.json")
    #expect(model.error != nil)
    model.stop()
}

@Test @MainActor func temporaryMessagesExpireAndUndoStillRestores() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("research-notices-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let item = Article(url: URL(string: "https://example.com/undo")!, title: "Undo")
    _ = try await ResearchRepository(root: root).restore(ResearchLibrary(articles: [item]), merge: false)
    let model = ResearchModel(noticeLifetime: .milliseconds(150), undoLifetime: .milliseconds(250))
    configure(model, root: root); try await awaitState { model.ready }
    model.notice = "First"
    try await Task.sleep(for: .milliseconds(100))
    model.notice = "Second"
    try await Task.sleep(for: .milliseconds(80))
    #expect(model.notice == "Second")
    try await awaitState { model.notice == nil }
    model.remove(item)
    try await awaitState { model.deleted != nil }
    model.undoRemove()
    try await awaitState { model.deleted == nil && model.library.articles.count == 1 }
    model.remove(item)
    try await awaitState { model.deleted != nil }
    model.stop()
    try await awaitState { model.deleted == nil }
    #expect(model.library.articles.isEmpty)
}
