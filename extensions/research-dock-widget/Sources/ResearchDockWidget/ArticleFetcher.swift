import Foundation
import Darwin

// DNS preflight is defense in depth, not an OS firewall. URLSession may resolve again.
enum PublicDestination {
    static func permitsIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let a = bytes[0], b = bytes[1], c = bytes[2]
        return !(a == 0 || a == 10 || a == 127 || a >= 224 ||
                 (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254) ||
                 (a == 172 && (16...31).contains(b)) || (a == 192 && (b == 168 || b == 0 || (b == 88 && c == 99))) ||
                 (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) || (a == 203 && b == 0 && c == 113))
    }
    static func permitsAddress(_ address: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            return withUnsafeBytes(of: ipv4) { permitsIPv4(Array($0)) }
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, address, &ipv6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 255 && bytes[11] == 255 {
            return permitsIPv4(Array(bytes.suffix(4)))
        }
        // Only globally routable unicast, excluding documentation and transition ranges.
        return bytes[0] & 0xe0 == 0x20 && !(bytes[0] == 0x20 && bytes[1] == 0x02) &&
            !(bytes[0] == 0x20 && bytes[1] == 0x01 && (bytes[2] == 0 || (bytes[2] == 0x0d && bytes[3] == 0xb8)))
    }
    static func check(_ url: URL) throws {
        _ = try CaptureService.url(url.absoluteString)
        guard var host = url.host?.lowercased(), url.port == nil || [80, 443].contains(url.port!) else {
            throw ResearchError.message("Automatic reading supports public websites on standard web ports only.")
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"), !host.hasSuffix(".internal") else {
            throw ResearchError.message("Local-network pages can be bookmarked but are not fetched.")
        }
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { throw ResearchError.message("The website could not be resolved.") }
        defer { freeaddrinfo(first) }
        var pointer: UnsafeMutablePointer<addrinfo>? = first
        var found = false
        while let item = pointer {
            let info = item.pointee
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.ai_addr, info.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                found = true
                guard permitsAddress(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) else { throw ResearchError.message("Local/private-network destinations are not fetched.") }
            }
            pointer = info.ai_next
        }
        guard found else { throw ResearchError.message("The website has no supported address.") }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

struct ArticleFetcher: Sendable {
    static let maximumBytes = 5 * 1_024 * 1_024
    var configuration: @Sendable () -> URLSessionConfiguration = { .ephemeral }
    var validateDestination: @Sendable (URL) throws -> Void = PublicDestination.check
    func fetch(_ initialURL: URL) async throws -> ArticleContent {
        let config = configuration()
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var url = initialURL
        for hop in 0...5 {
            try Task.checkCancellation()
            // The whole fetch is run from a worker task; DNS never blocks the UI actor.
            try validateDestination(url)
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("VehlaResearch/1.0 (saved-article reader)", forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw ResearchError.message("The website returned an unsupported response.") }
            if [301, 302, 303, 307, 308].contains(response.statusCode) {
                bytes.task.cancel()
                guard hop < 5, let location = response.value(forHTTPHeaderField: "Location"), let next = URL(string: location, relativeTo: url)?.absoluteURL else { throw ResearchError.message("Too many or invalid redirects.") }
                url = next; continue
            }
            guard (200...299).contains(response.statusCode) else { bytes.task.cancel(); throw ResearchError.message("Website returned HTTP \(response.statusCode). Open the original or retry later.") }
            guard ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "") else {
                bytes.task.cancel(); throw ResearchError.message("This format is not supported by the article reader. Open the original.")
            }
            guard response.expectedContentLength <= Int64(Self.maximumBytes) else { bytes.task.cancel(); throw ResearchError.message("Article exceeds the 5 MiB download limit.") }
            var data = Data()
            for try await byte in bytes {
                if data.count % 4096 == 0 { try Task.checkCancellation() }
                guard data.count < Self.maximumBytes else { bytes.task.cancel(); throw ResearchError.message("Article exceeds the 5 MiB download limit.") }
                data.append(byte)
            }
            try Task.checkCancellation()
            return try ArticleExtractor.extract(data, url: url, encodingName: response.textEncodingName)
        }
        throw ResearchError.message("Too many redirects.")
    }
}
