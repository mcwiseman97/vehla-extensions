import AppKit
import SwiftUI

struct ArticleReader: NSViewRepresentable {
    let article: Article
    let content: ArticleContent
    let typeSize: Double
    let dark: Bool
    let textColor: NSColor
    let linkColor: NSColor
    let onProgress: (String, Double) -> Void
    let open: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let text = NSTextView()
        text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
        text.isRichText = true; text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainerInset = NSSize(width: 24, height: 20)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 560, height: CGFloat.greatestFiniteMagnitude)
        text.setAccessibilityLabel("Article text")
        scroll.documentView = text; text.delegate = context.coordinator
        context.coordinator.scroll = scroll; context.coordinator.text = text
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onProgress = onProgress; coordinator.open = open
        let key = "\(article.id)-\(content.revision)-\(typeSize)-\(dark)-\(textColor)-\(linkColor)"
        guard coordinator.key != key, let text = coordinator.text else { return }
        coordinator.key = key; coordinator.restoring = true
        let string = NSMutableAttributedString(string: "")
        var ranges: [(String, NSRange)] = []
        for block in content.blocks {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5; paragraph.paragraphSpacing = 16
            if block.kind == .quote { paragraph.headIndent = 16; paragraph.firstLineHeadIndent = 16 }
            let font: NSFont
            switch block.kind {
            case .heading: font = .systemFont(ofSize: typeSize + 5, weight: .semibold)
            case .code: font = .monospacedSystemFont(ofSize: typeSize - 2, weight: .regular)
            default: font = .systemFont(ofSize: typeSize)
            }
            let prefix = block.kind == .listItem ? "• " : ""
            let value = prefix + block.text + "\n"
            let range = NSRange(location: string.length, length: (value as NSString).length)
            let attributed = NSMutableAttributedString(string: value, attributes: [.font: font, .foregroundColor: textColor, .paragraphStyle: paragraph])
            for link in block.links where !link.label.isEmpty {
                let found = (value as NSString).range(of: link.label)
                if found.location != NSNotFound { attributed.addAttribute(.link, value: link.url, range: found) }
            }
            string.append(attributed); ranges.append((block.id, range))
        }
        coordinator.ranges = ranges
        text.textStorage?.setAttributedString(string)
        text.linkTextAttributes = [.foregroundColor: linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        text.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let position = article.position, offset = article.positionOffset
        DispatchQueue.main.async {
            guard coordinator.key == key, let layout = text.layoutManager, let container = text.textContainer else { return }
            text.frame.size.width = scroll.contentSize.width
            layout.ensureLayout(for: container)
            text.frame.size.height = max(scroll.contentSize.height, layout.usedRect(for: container).height + 40)
            let target = ranges.first { $0.0 == position } ?? ranges.first
            if let target {
                let glyphs = layout.glyphRange(forCharacterRange: target.1, actualCharacterRange: nil)
                let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                let y = position == nil ? 0 : max(0, min(rect.minY + 20 + rect.height * offset, text.frame.height - scroll.contentSize.height))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            }
            coordinator.restoring = false
        }
    }
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.scrolled()
        NotificationCenter.default.removeObserver(coordinator)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        weak var scroll: NSScrollView?
        weak var text: NSTextView?
        var key = ""
        var ranges: [(String, NSRange)] = []
        var restoring = false
        var onProgress: ((String, Double) -> Void)?
        var open: ((URL) -> Void)?
        @objc func scrolled() {
            guard !restoring, let scroll, let text, let layout = text.layoutManager, let container = text.textContainer else { return }
            let y = max(0, scroll.contentView.bounds.minY - 20)
            for (id, range) in ranges {
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                if rect.maxY >= y { onProgress?(id, max(0, min(1, (y - rect.minY) / max(1, rect.height)))); return }
            }
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { open?(url); return true }; return false
        }
    }
}
