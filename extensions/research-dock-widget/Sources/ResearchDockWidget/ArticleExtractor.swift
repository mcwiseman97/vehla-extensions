import Foundation

enum ArticleExtractor {
    static func extract(_ data: Data, url: URL, encodingName: String? = nil) throws -> ArticleContent {
        guard data.count <= 5 * 1_024 * 1_024 else { throw ResearchError.message("Article exceeds the 5 MiB download limit.") }
        let prefix = String(decoding: data.prefix(8_192), as: UTF8.self)
        let pattern = #"(?i)charset\s*=\s*["']?([a-z0-9._-]+)"#
        let match = try NSRegularExpression(pattern: pattern).firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix))
        let detected = match.flatMap { Range($0.range(at: 1), in: prefix).map { String(prefix[$0]) } }
        let encoding = (encodingName ?? detected).flatMap { name -> String.Encoding? in
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            return cf == kCFStringEncodingInvalidId ? nil : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
        guard let html = encoding.flatMap({ String(data: data, encoding: $0) }) ?? String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            throw ResearchError.message("This page uses an unsupported text encoding.")
        }
        // Reject entity declarations before invoking the system parser (no custom/external entities).
        let declarationCheck = html.uppercased()
        guard !declarationCheck.contains("<!ENTITY") else {
            throw ResearchError.message("This page contains unsupported document declarations. Open the original website.")
        }
        // Foundation's HTML tidy path can otherwise drop undeclared non-ASCII text.
        // Numeric entities preserve decoded Unicode independently of tidy's encoding defaults.
        let normalizedHTML = "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">" + html
        let ascii = normalizedHTML.unicodeScalars.map { $0.value > 127 ? "&#\($0.value);" : String($0) }.joined()
        let doc = try XMLDocument(data: Data(ascii.utf8), options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        func first(_ xpath: String) -> String? {
            let text = (try? doc.nodes(forXPath: xpath).first?.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        let title = first("//meta[@property='og:title']/@content") ?? first("//title") ?? url.host ?? "Saved article"
        let author = first("//meta[@name='author']/@content")
        // Delete chrome and active content before scoring. Nothing is rendered as webpage HTML.
        let removed = ["script", "style", "nav", "footer", "header", "aside", "form", "iframe", "svg", "noscript", "button", "input", "select", "textarea", "canvas", "object", "embed", "template"]
        for tag in removed { for node in (try? doc.nodes(forXPath: "//\(tag)")) ?? [] { node.detach() } }
        for node in (try? doc.nodes(forXPath: "//*[@hidden or @aria-hidden='true']")) ?? [] { node.detach() }
        func text(_ node: XMLNode) -> String { collapse(node.stringValue ?? "") }
        func score(_ node: XMLNode) -> Double {
            let count = text(node).count
            let linkCount = ((try? node.nodes(forXPath: ".//a")) ?? []).reduce(0) { $0 + text($1).count }
            let paragraphs = ((try? node.nodes(forXPath: ".//p")) ?? []).filter { text($0).count > 60 }.count
            return Double(count - linkCount * 2 + paragraphs * 100)
        }
        let semantic = (try? doc.nodes(forXPath: "//article | //main | //*[@role='main']")) ?? []
        let candidates = semantic.isEmpty ? ((try? doc.nodes(forXPath: "//div | //body")) ?? []) : semantic
        guard let root = candidates.max(by: { score($0) < score($1) }) else { throw ResearchError.message("No readable article was found. Open the original website.") }
        var blocks: [ArticleBlock] = []
        var occurrences: [String: Int] = [:]
        let leafTags = Set(["p", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote", "li"])
        func visit(_ node: XMLNode, depth: Int = 0) {
            guard depth < 100, blocks.count < 20_000 else { return }
            let name = node.name?.lowercased() ?? ""
            if leafTags.contains(name) {
                let value = name == "pre" ? (node.stringValue ?? "").trimmingCharacters(in: .newlines) : text(node)
                guard !value.isEmpty else { return }
                let occurrence = occurrences[value, default: 0]; occurrences[value] = occurrence + 1
                let kind: ArticleBlock.Kind = name.hasPrefix("h") ? .heading : name == "pre" ? .code : name == "blockquote" ? .quote : name == "li" ? .listItem : .paragraph
                let links: [ArticleLink] = ((try? node.nodes(forXPath: ".//a[@href]")) ?? []).compactMap { anchor in
                    guard let element = anchor as? XMLElement, let href = element.attribute(forName: "href")?.stringValue,
                          let resolved = URL(string: href, relativeTo: url)?.absoluteURL,
                          (try? CaptureService.url(resolved.absoluteString)) != nil else { return nil }
                    return ArticleLink(label: text(anchor), url: resolved)
                }
                blocks.append(ArticleBlock(id: CaptureService.blockID(value, occurrence: occurrence), kind: kind, text: value, links: Array(links.prefix(30))))
                return
            }
            for child in node.children ?? [] { visit(child, depth: depth + 1) }
        }
        visit(root)
        guard blocks.reduce(0, { $0 + $1.text.count }) >= 180 else {
            throw ResearchError.message("This page has too little readable text. It may require a login or JavaScript. Open the original website.")
        }
        return ArticleContent(title: collapse(title), author: author.map(collapse), finalURL: url, blocks: blocks)
    }
    private static func collapse(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}
