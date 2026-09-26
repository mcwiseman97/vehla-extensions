import Foundation
import Testing
@testable import ResearchDockWidget

private let page = """
<html><head><title>A useful article</title><meta name="author" content="Alex Reader"></head><body>
<nav><a href="/ads">Navigation that must not appear</a></nav>
<article><h1>Thoughtful reading</h1>
<p>Reading carefully means giving an idea enough time to develop. A saved reading queue makes room for longer articles and thoughtful essays, without needing to finish them in the moment they arrive.</p>
<p>Return to a source and follow its <a href="/references">references</a>. Keep the original words separate from your own interpretation, and revisit the details when you have a question.</p>
<blockquote>A memorable quotation from the article.</blockquote><ul><li>First useful point</li><li>Second useful point</li></ul><pre>let value = 42\nprint(value)</pre>
<script>window.location='https://tracker.example';</script><p hidden>Invisible tracking text</p></article><footer>Unrelated footer</footer></body></html>
"""
private func content() throws -> ArticleContent { try ArticleExtractor.extract(Data(page.utf8), url: URL(string: "https://example.com/story")!) }
private func directory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("research-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
}
private func populated() throws -> ResearchLibrary {
    let group = ReadingCollection(name: "Reading"), text = try content()
    var item = Article(collectionID: group.id, url: URL(string: "https://example.com/story")!, title: "A useful article")
    item.contentRevision = text.revision; item.position = text.blocks[1].id; item.positionOffset = 0.35; item.favorite = true
    return ResearchLibrary(collections: [group], articles: [item], contents: [item.id: text], lastArticle: item.id)
}

@Test func captureConservativelyNormalizesURLs() throws {
    #expect(try CaptureService.key(URL(string: "HTTPS://EXAMPLE.COM:443")!) == "https://example.com/")
    #expect(try CaptureService.key(URL(string: "https://example.com/?id=1#part")!) != CaptureService.key(URL(string: "https://example.com/?id=2#part")!))
    for bad in ["javascript:alert(1)", "file:///tmp/a", "hello", "https://user:password@example.com"] {
        #expect(throws: (any Error).self) { try CaptureService.url(bad) }
    }
}
@Test func extractorPreservesStructureAndDropsActiveContent() throws {
    let result = try content()
    #expect(result.title == "A useful article"); #expect(result.author == "Alex Reader")
    #expect(!result.plainText.contains("Navigation")); #expect(!result.plainText.contains("window.location"))
    #expect(!result.plainText.contains("Invisible")); #expect(!result.plainText.contains("Unrelated footer"))
    #expect(result.blocks.contains { $0.kind == .code && $0.text.contains("\n") })
    #expect(result.blocks.contains { $0.kind == .quote })
    #expect(result.blocks.flatMap(\.links).first?.url.absoluteString == "https://example.com/references")
    #expect(try content().blocks.map(\.id) == result.blocks.map(\.id))
}
@Test func extractorHandlesMalformedHTMLAndUnicode() throws {
    let html = "<html><title>Café &amp; science</title><body><main><p>" + String(repeating: "Résumé 日本語 &amp; café. ", count: 30) + "<p>Another paragraph."
    let result = try ArticleExtractor.extract(Data(html.utf8), url: URL(string: "https://example.com")!)
    #expect(result.title == "Café & science"); #expect(result.plainText.contains("日本語 & café"))
}
@Test func extractorRejectsEmptyAndEntityDocuments() throws {
    for html in ["<html><body><p>Log in</p></body></html>", "<!DOCTYPE html [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><html><p>&x;</p></html>"] {
        #expect(throws: (any Error).self) { try ArticleExtractor.extract(Data(html.utf8), url: URL(string: "https://example.com")!) }
    }
}
@Test func privateAddressesAreRejected() {
    for address in ["127.0.0.1", "10.1.2.3", "192.168.1.1", "169.254.169.254", "100.64.0.1", "172.16.0.1", "::1", "::", "fc00::1", "fe80::1", "::ffff:127.0.0.1", "2002:7f00:1::"] { #expect(!PublicDestination.permitsAddress(address)) }
    for address in ["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111"] { #expect(PublicDestination.permitsAddress(address)) }
}
@Test func backupRoundTripsAllRecordsAndRejectsBadRelationships() throws {
    let original = try populated()
    #expect(try ResearchExporter.decode(ResearchExporter.backup(original)) == original)
    var broken = original; broken.articles[0].collectionID = UUID()
    #expect(throws: (any Error).self) { try broken.validate() }
    broken = original; broken.articles.append(broken.articles[0])
    #expect(throws: (any Error).self) { try broken.validate() }
    broken = original; broken.schema = 99
    #expect(throws: (any Error).self) { try broken.validate() }
}
@Test func repositoryPersistsContentAndProgressSeparately() async throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    let repo = ResearchRepository(root: root), initial = try populated()
    _ = try await repo.restore(initial, merge: false)
    let saved = try await repo.load()
    let id = saved.articles[0].id
    _ = try await repo.update { $0.articles[0].positionOffset = 0.6 }
    let fresh = try await ResearchRepository(root: root).load()
    #expect(fresh.articles[0].positionOffset == 0.6); #expect(fresh.contents[id]?.plainText == initial.contents[id]?.plainText)
    let metadata = try String(contentsOf: root.appendingPathComponent("library.json"), encoding: .utf8)
    #expect(!metadata.contains("Reading carefully means"))
}
@Test func corruptIndexDoesNotOverwriteAndCanRecover() async throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    let repo = ResearchRepository(root: root)
    _ = try await repo.restore(populated(), merge: false)
    _ = try await repo.update { $0.articles[0].title = "Changed" }
    let index = root.appendingPathComponent("library.json"), corrupt = Data("broken".utf8)
    try corrupt.write(to: index)
    let reopened = ResearchRepository(root: root)
    await #expect(throws: (any Error).self) { try await reopened.load() }
    await #expect(throws: (any Error).self) { try await reopened.update { $0.articles.removeAll() } }
    #expect(try Data(contentsOf: index) == corrupt)
    let recovered = try await reopened.recoverPrevious()
    #expect(recovered.articles[0].title == "A useful article")
}
@Test func mergePreservesExistingProgressAndRemapsConflictingIDs() async throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    let repo = ResearchRepository(root: root), original = try populated()
    _ = try await repo.restore(original, merge: false)
    var incoming = original; incoming.articles[0].positionOffset = 0.9
    let merged = try await repo.restore(incoming, merge: true)
    #expect(merged.articles.count == 1); #expect(merged.articles[0].positionOffset == 0.35)
    incoming.articles[0].url = URL(string: "https://example.com/another")!
    let second = try await repo.restore(incoming, merge: true)
    #expect(second.articles.count == 2); #expect(second.articles[0].id != second.articles[1].id)
    try second.validate()
}
@Test func rejectedMutationLeavesDiskAndMemoryUnchanged() async throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    let repo = ResearchRepository(root: root)
    _ = try await repo.restore(populated(), merge: false)
    let before = try await repo.load()
    await #expect(throws: (any Error).self) { try await repo.update { $0.contents = [:] } }
    #expect(try await repo.load() == before)
    #expect(try await ResearchRepository(root: root).load() == before)
}
@Test func concurrentMutationsDoNotLoseEdits() async throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    let repo = ResearchRepository(root: root)
    _ = try await repo.restore(populated(), merge: false)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for i in 0..<20 { group.addTask { _ = try await repo.update { $0.collections.append(ReadingCollection(name: "Group \(i)")) } } }
        try await group.waitForAll()
    }
    #expect(try await repo.load().collections.count == 21)
}
@Test func thousandArticleLibraryRoundTrips() async throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    let repo = ResearchRepository(root: root)
    var library = ResearchLibrary()
    for i in 0..<1_000 { library.articles.append(Article(url: URL(string: "https://example.com/\(i)")!, title: "Article \(i)")) }
    let start = Date()
    _ = try await repo.restore(library, merge: false)
    let loaded = try await ResearchRepository(root: root).load()
    #expect(loaded.articles.count == 1_000)
    print("1,000 article metadata round-trip: \(Date().timeIntervalSince(start)) seconds")
}
@Test func markdownEscapesTitlesAndKeepsLinks() throws {
    var library = try populated(); library.articles[0].title = "A [tricky] title\nsecond line"; library.articles[0].state = .finished
    let markdown = ResearchExporter.markdown(library.articles, title: "Saved")
    #expect(markdown.contains("- [x] [A \\[tricky\\] title second line]")); #expect(markdown.contains("https://example.com/story"))
}

@Test func legacyPageEncodingIsRespected() throws {
    let html = "<html><head><meta charset='windows-1252'><title>Café</title></head><body><article><p>" + String(repeating: "A café with a thoughtful résumé. ", count: 12) + "</p></article></body></html>"
    let result = try ArticleExtractor.extract(html.data(using: .windowsCP1252)!, url: URL(string: "https://example.com")!)
    #expect(result.title == "Café"); #expect(result.plainText.contains("résumé"))
}

@Test func thousandCachedArticlesRemainEditable() async throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    let repo = ResearchRepository(root: root)
    var library = ResearchLibrary()
    let prototype = try content()
    for i in 0..<1_000 {
        var item = Article(url: URL(string: "https://example.com/\(i)")!, title: "Article \(i)")
        item.contentRevision = prototype.revision
        library.articles.append(item); library.contents[item.id] = prototype
    }
    _ = try await repo.restore(library, merge: false)
    let reopened = ResearchRepository(root: root), start = Date()
    #expect(try await reopened.load().contents.count == 1_000)
    let loaded = Date()
    _ = try await reopened.update { $0.articles[0].positionOffset = 0.3 }
    print("1,000 cached articles — load: \(loaded.timeIntervalSince(start))s; edit: \(Date().timeIntervalSince(loaded))s")
}
