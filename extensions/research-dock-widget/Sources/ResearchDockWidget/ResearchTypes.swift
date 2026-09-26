import Foundation
import CryptoKit

enum ResearchError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum ReadingState: String, Codable, CaseIterable, Sendable { case unread, reading, finished }
enum QueueFilter: String, CaseIterable { case all = "Queue", unread = "Unread", reading = "Reading", finished = "Finished", favorites = "Favorites", archived = "Archived" }
enum QueueSort: String, CaseIterable { case newest = "Newest first", oldest = "Oldest first", recent = "Recently opened" }

struct ReadingCollection: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
}
struct Article: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var collectionID: UUID?
    var url: URL
    var title: String
    var customTitle = false
    var addedAt = Date()
    var lastOpened: Date?
    var favorite = false
    var archived = false
    var state: ReadingState = .unread
    var contentRevision: UUID?
    var position: String?
    var positionOffset: Double = 0
    var fetchError: String?
    var domain: String { url.host ?? url.absoluteString }
}
struct ArticleBlock: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case paragraph, heading, quote, code, listItem }
    var id: String
    var kind: Kind
    var text: String
    var links: [ArticleLink] = []
}
struct ArticleLink: Codable, Equatable, Sendable { var label: String; var url: URL }
struct ArticleContent: Codable, Equatable, Sendable {
    var revision = UUID()
    var title: String
    var author: String?
    var finalURL: URL
    var fetchedAt = Date()
    var blocks: [ArticleBlock]
    var plainText: String { blocks.map(\.text).joined(separator: "\n\n") }
    var minutes: Int { max(1, Int(ceil(Double(plainText.split(whereSeparator: \.isWhitespace).count) / 220))) }
}
struct ResearchLibrary: Codable, Equatable, Sendable {
    var schema = 1
    var revision = 0
    var collections: [ReadingCollection] = []
    var articles: [Article] = []
    var contents: [UUID: ArticleContent] = [:]
    var typeSize: Double = 17
    var lastArticle: UUID?

    func validate() throws {
        guard schema == 1 else { throw ResearchError.message("This backup uses an unsupported version.") }
        guard articles.count <= 20_000, collections.count <= 1_000,
              Set(articles.map(\.id)).count == articles.count,
              Set(collections.map(\.id)).count == collections.count,
              (13...25).contains(typeSize) else { throw ResearchError.message("The library contains invalid or duplicate records.") }
        let groups = Set(collections.map(\.id))
        let ids = Set(articles.map(\.id))
        var urls = Set<String>()
        for article in articles {
            let key = try CaptureService.key(article.url)
            guard urls.insert(key).inserted, article.collectionID.map(groups.contains) ?? true,
                  article.positionOffset.isFinite, (0...1).contains(article.positionOffset),
                  article.title.count <= 10_000 else { throw ResearchError.message("Invalid article relationship or duplicate URL.") }
            if let revision = article.contentRevision {
                guard let content = contents[article.id], content.revision == revision,
                      !content.blocks.isEmpty, content.blocks.count <= 20_000,
                      Set(content.blocks.map(\.id)).count == content.blocks.count else {
                    throw ResearchError.message("Article content is missing or inconsistent.")
                }
                _ = try CaptureService.key(content.finalURL)
                for link in content.blocks.flatMap(\.links) { _ = try CaptureService.key(link.url) }
            } else if contents[article.id] != nil { throw ResearchError.message("Unexpected article content.") }
        }
        guard Set(contents.keys).isSubset(of: ids), lastArticle.map(ids.contains) ?? true else {
            throw ResearchError.message("The library references an unknown article.")
        }
        guard collections.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 120 }) else {
            throw ResearchError.message("Collection names must contain 1–120 characters.")
        }
    }
}

enum CaptureService {
    static func url(_ text: String) throws -> URL {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 8_192, let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw ResearchError.message("Enter a complete http:// or https:// article URL without embedded credentials.")
        }
        return url
    }
    static func key(_ url: URL) throws -> String {
        let valid = try self.url(url.absoluteString)
        var parts = URLComponents(url: valid, resolvingAgainstBaseURL: false)!
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        if parts.path.isEmpty { parts.path = "/" }
        return parts.string!
    }
    static func blockID(_ text: String, occurrence: Int) -> String {
        String(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)) + "-\(occurrence)"
    }
}

enum ResearchExporter {
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "\n", with: " ")
    }
    static func markdownLink(_ article: Article) -> String {
        "[\(escaped(article.title))](<\(article.url.absoluteString.replacingOccurrences(of: ">", with: "%3E"))>)"
    }
    static func markdown(_ articles: [Article], title: String) -> String {
        "# \(escaped(title))\n\n" + articles.map {
            "- [\($0.state == .finished ? "x" : " ")] \(markdownLink($0))\($0.favorite ? " ★" : "")"
        }.joined(separator: "\n") + "\n"
    }
    static func backup(_ library: ResearchLibrary) throws -> Data {
        try library.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        guard data.count <= 100 * 1_024 * 1_024 else { throw ResearchError.message("The library exceeds the 100 MiB backup format limit. Export reading lists or reduce the library before retrying.") }
        return data
    }
    static func decode(_ data: Data) throws -> ResearchLibrary {
        guard data.count <= 100 * 1_024 * 1_024 else { throw ResearchError.message("Backup exceeds 100 MiB.") }
        let result = try JSONDecoder().decode(ResearchLibrary.self, from: data)
        try result.validate(); return result
    }
}
