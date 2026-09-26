import AppKit
import SwiftUI
import Testing
import VehlaDockWidgetSDK
@testable import ResearchDockWidget

@Test(.enabled(if: ProcessInfo.processInfo.environment["RESEARCH_RENDER_PREVIEWS"] == "1"))
@MainActor func renderReviewPreviews() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("research-preview-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = ResearchRepository(root: root)
    let group = ReadingCollection(name: "Design & craft")
    var library = ResearchLibrary(collections: [group])
    for (index, title) in ["Making room for a slower internet", "The architecture of a good reading habit", "A field guide to noticing", "Why small tools matter"].enumerated() {
        let blocks = (0..<10).map { n in ArticleBlock(id: "block-\(n)", kind: n == 0 ? .heading : .paragraph, text: n == 0 ? "A quieter kind of attention" : "A reading queue is a promise to return. It gives an interesting idea somewhere to live until there is time to follow it. The most useful tools protect that small space: a clear source, comfortable type, and a place to begin again.") }
        let url = URL(string: "https://example.com/essay-\(index)")!
        let content = ArticleContent(title: title, author: "Alex Reader", finalURL: url, blocks: blocks)
        var article = Article(collectionID: index % 2 == 0 ? group.id : nil, url: url, title: title)
        article.contentRevision = content.revision; article.favorite = index == 0; article.state = index == 1 ? .reading : .unread
        library.articles.append(article); library.contents[article.id] = content
    }
    _ = try await repo.restore(library, merge: false)
    let model = ResearchModel()
    func theme(_ dark: Bool) -> VehlaDockWidgetTheme {
        VehlaDockWidgetTheme(isDark: dark, accentColor: .systemTeal, primaryTextColor: .labelColor, secondaryTextColor: .secondaryLabelColor, surfaceColor: .windowBackgroundColor)
    }
    model.configure(VehlaDockWidgetContext(packageID: "preview", widgetID: "research", dataDirectory: root, theme: theme(false), invalidationHandler: {}, actionHandler: { _ in }))
    for _ in 0..<100 where !model.ready { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.ready)
    func render(_ name: String) async throws {
        let controller = NSHostingController(rootView: ResearchRootView(surface: .popup, model: model).background(Color(nsColor: model.theme?.surfaceColor ?? .windowBackgroundColor)))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 760, height: 800))
        window.appearance = NSAppearance(named: model.theme?.isDark == true ? .darkAqua : .aqua)
        controller.view.frame = NSRect(x: 0, y: 0, width: 760, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        #expect(controller.view.bounds.width >= 760)
        #expect(controller.view.bounds.height >= 800)
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/research-\(name).png"))
        window.contentViewController = nil
    }
    try await render("queue-light")
    model.theme = theme(true)
    try await render("queue-dark")
    model.capturePresented = true
    try await render("capture-dark")
    model.capturePresented = false
    model.settingsPresented = true
    try await render("library-dark")
    model.settingsPresented = false
    model.selected = model.library.articles.first?.id
    try await render("reader-dark")
    model.selected = nil
    model.mutate { $0.articles = []; $0.contents = [:]; $0.lastArticle = nil }
    for _ in 0..<100 where !model.library.articles.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    try await render("empty-dark")
    model.stop()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["RESEARCH_RENDER_PREVIEWS"] == "1"))
@MainActor func renderRevealedDelete() async throws {
    let view = SwipeDeleteRow(revealed: true, remove: {}) {
        HStack { Text("Saved article"); Spacer(); Image(systemName: "star") }.padding(18)
    }.foregroundStyle(.white).frame(width: 500, height: 84).background(Color.gray)
    let controller = NSHostingController(rootView: view)
    controller.sizingOptions = []
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 84), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentViewController = controller
    controller.view.frame = NSRect(x: 0, y: 0, width: 500, height: 84)
    controller.view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
    controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/research-delete.png"))
    window.contentViewController = nil
}
