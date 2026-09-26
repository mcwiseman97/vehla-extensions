import Foundation
import Testing
@testable import ResearchDockWidget

private final class MockArticleProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var status = 200
        var headers = ["Content-Type": "text/html; charset=utf-8"]
        var body = Data(("<html><title>Downloaded</title><body><article><p>" + String(repeating: "A thoughtful article to return to later. ", count: 20) + "</p></article></body></html>").utf8)
        switch path {
        case "/redirect": status = 302; headers["Location"] = "https://reader.example/article"; body = Data()
        case "/private": status = 302; headers["Location"] = "http://127.0.0.1/admin"; body = Data()
        case "/loop": status = 302; headers["Location"] = "/loop"; body = Data()
        case "/pdf": headers["Content-Type"] = "application/pdf"
        case "/error": status = 503
        case "/declared-large": headers["Content-Length"] = "9000000"
        case "/stream-large": body = Data(repeating: 65, count: ArticleFetcher.maximumBytes + 1)
        default: break
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        // Deliver chunks to exercise byte-limited transfer rather than only Content-Length.
        for offset in stride(from: 0, to: body.count, by: 32_768) {
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<min(body.count, offset + 32_768)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func mockFetcher() -> ArticleFetcher {
    ArticleFetcher(configuration: { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockArticleProtocol.self]; return config }, validateDestination: { url in
        guard url.host == "reader.example" else { throw ResearchError.message("Blocked destination") }
    })
}
@Test func fetcherExtractsAndRevalidatesRedirects() async throws {
    let result = try await mockFetcher().fetch(URL(string: "https://reader.example/redirect")!)
    #expect(result.title == "Downloaded"); #expect(result.finalURL.path == "/article")
    await #expect(throws: (any Error).self) { try await mockFetcher().fetch(URL(string: "https://reader.example/private")!) }
}
@Test(arguments: ["pdf", "error", "loop", "declared-large", "stream-large"])
func fetcherRejectsUnsupportedResponses(_ path: String) async {
    await #expect(throws: (any Error).self) { try await mockFetcher().fetch(URL(string: "https://reader.example/\(path)")!) }
}
@Test func cancelledFetchDoesNotProduceContent() async throws {
    let task = Task { try await mockFetcher().fetch(URL(string: "https://reader.example/article")!) }
    task.cancel()
    await #expect(throws: (any Error).self) { try await task.value }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["RESEARCH_LIVE_FETCH"] == "1"))
func livePublicArticleFetch() async throws {
    let content = try await ArticleFetcher().fetch(URL(string: "https://www.swift.org/blog/announcing-swift-6/")!)
    #expect(!content.title.isEmpty)
    #expect(content.blocks.count > 1)
    print("Live article extraction: \(content.title), \(content.blocks.count) blocks")
}
