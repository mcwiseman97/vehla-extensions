import AppKit
import SwiftUI

/// Editable note text inside the popup. Vehla's popup keeps itself as first
/// responder, so once clicked this view takes key events straight from
/// Vehla's event stream and draws its own caret when AppKit will not.
/// Antinote checkbox lines (`[]`, `[ ]`, `- [ ]`, `[x]`, `- [x]`) show a
/// clickable checkbox in place of the marker.
struct InlineNoteEditor: NSViewRepresentable {
    var text: String
    var textColor: NSColor
    var autoFocus: Bool
    var onEdit: (String) -> Void
    var onSave: () -> Void
    var fontSize: Double = 15
    var focusToken: UUID = UUID()
    var analysis = ScratchAnalysis()
    var onCommand: (String) -> Bool = { _ in false }
    var onNavigate: (Int) -> Void = { _ in }
    var onEscape: () -> Bool = { false }
    var onImage: (Data) -> Void = { _ in }
    var onImageFile: (URL) -> Void = { _ in }
    var onOpenURL: (URL) -> Void = { _ in }

    func makeCoordinator() -> InlineEditorCoordinator {
        InlineEditorCoordinator(onEdit: onEdit, onOpenURL: onOpenURL)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NoteScrollView()
        scroll.onNavigate = onNavigate
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.contentView.drawsBackground = false
        scroll.contentView.backgroundColor = .clear
        scroll.borderType = .noBorder
        let textView = InlineTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.baseFont = .systemFont(ofSize: fontSize)
        textView.font = textView.baseFont
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.insertionPointColor = .controlAccentColor
        textView.baseColor = textColor
        textView.string = text
        if analysis.source == textView.string { textView.mathAnalysis = analysis }
        textView.restyle()
        textView.delegate = context.coordinator
        textView.onSave = onSave
        textView.onCommand = onCommand
        textView.onNavigate = onNavigate
        textView.onEscape = onEscape
        textView.onImage = onImage
        textView.onImageFile = onImageFile
        textView.onOpenURL = onOpenURL
        textView.focusOnAttach = autoFocus
        scroll.documentView = textView
        return scroll
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: InlineEditorCoordinator) {
        (scroll.documentView as? InlineTextView)?.detach()
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll as? NoteScrollView)?.onNavigate = onNavigate
        context.coordinator.onEdit = onEdit
        context.coordinator.onOpenURL = onOpenURL
        guard let textView = scroll.documentView as? InlineTextView else { return }
        textView.onSave = onSave
        textView.onCommand = onCommand
        textView.onNavigate = onNavigate
        textView.onEscape = onEscape
        textView.onImage = onImage
        textView.onImageFile = onImageFile
        textView.onOpenURL = onOpenURL
        var changed = false
        if textView.baseFont.pointSize != CGFloat(fontSize) { textView.baseFont = .systemFont(ofSize: fontSize); changed = true }
        let selectionChanged = textView.focusToken != focusToken
        if selectionChanged {
            textView.focusToken = focusToken
            textView.mathAnalysis = ScratchAnalysis()
            textView.clearDerivedStyle()
            textView.undoManager?.removeAllActions()
            if autoFocus { textView.requestFocus() }
        }
        if textView.string != text {
            if selectionChanged { textView.string = text }
            else {
                // External capture/replace edits participate in native Undo.
                let delegate = textView.delegate
                textView.delegate = nil
                textView.insertText(text, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
                textView.delegate = delegate
            }
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            changed = true
        }
        if textView.baseColor != textColor {
            textView.baseColor = textColor
            changed = true
        }
        if changed { textView.restyle() }
        if analysis.source == textView.string && analysis != textView.mathAnalysis {
            textView.mathAnalysis = analysis
        }
    }
}

@MainActor
final class InlineEditorCoordinator: NSObject, NSTextViewDelegate {
    var onEdit: (String) -> Void

    var onOpenURL: (URL) -> Void
    init(onEdit: @escaping (String) -> Void, onOpenURL: @escaping (URL) -> Void) {
        self.onEdit = onEdit; self.onOpenURL = onOpenURL
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL { onOpenURL(url) }
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        (textView as? InlineTextView)?.restyle()
        onEdit(textView.string)
    }
}

struct NoteCheckbox: Equatable, Sendable {
    /// The whole marker, e.g. `- [ ]` or `[]`.
    var marker: NSRange
    /// Everything between the brackets (empty, a space, or `x`).
    var inner: NSRange
    var dashed: Bool
    var checked: Bool
    /// The rest of the line after the marker.
    var body: NSRange
    var implicit = false

    private static let pattern = try! NSRegularExpression(
        pattern: #"^[ \t]*((- )?\[([ xX]?)\])(?=[ \t]|$)(.*)$"#,
        options: [.anchorsMatchLines]
    )

    static func find(in text: String) -> [NoteCheckbox] {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        var boxes = pattern.matches(in: text, range: whole).map { match in
            let inner = match.range(at: 3)
            let mark = (text as NSString).substring(with: inner)
            return NoteCheckbox(
                marker: match.range(at: 1),
                inner: inner,
                dashed: match.range(at: 2).location != NSNotFound,
                checked: mark.lowercased() == "x",
                body: match.range(at: 4)
            )
        }
        let source = text as NSString
        let explicitLines = Set(boxes.map { source.lineRange(for: $0.marker).location })
        let header = text.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if header == "list" || header.hasPrefix("list:") {
            var offset = 0
            while offset < source.length {
                let line = source.lineRange(for: NSRange(location: offset, length: 0))
                defer { offset = NSMaxRange(line) }
                guard offset > 0 else { continue }
                let content = source.substring(with: line).trimmingCharacters(in: .newlines)
                let trimmed = content.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("//"), !trimmed.hasPrefix("#"), !trimmed.hasPrefix("/"),
                      trimmed.range(of: #"^(?:[-*]\s|\d+\.\s)"#, options: .regularExpression) == nil,
                      !explicitLines.contains(line.location) else { continue }
                let indent = content.prefix(while: { $0 == " " || $0 == "\t" }).utf16.count
                let start = line.location + indent
                boxes.append(NoteCheckbox(marker: NSRange(location: start, length: 0), inner: NSRange(location: start, length: 0),
                                          dashed: false, checked: false, body: NSRange(location: start, length: content.utf16.count - indent), implicit: true))
            }
        }
        return boxes.sorted { $0.marker.location < $1.marker.location }
    }

    /// The edit that flips this checkbox, keeping Antinote's marker style.
    var toggle: (range: NSRange, replacement: String) {
        if implicit { return (inner, "[x] ") }
        if checked {
            return (inner, dashed ? " " : "")
        }
        return (inner, "x")
    }

    func adjusted(for edit: NSRange, replacement: String) -> Self? {
        let delta = replacement.utf16.count - edit.length
        if implicit, edit.location == marker.location, edit.length == 0 {
            guard !replacement.contains(where: \.isNewline) else { return nil }
            var box = self; box.body.length += delta; return box
        }
        if NSMaxRange(edit) <= marker.location {
            var box = self
            box.marker.location += delta; box.inner.location += delta; box.body.location += delta
            return box
        }
        if edit.location < NSMaxRange(marker) { return nil }
        if edit.location <= NSMaxRange(body) {
            guard NSMaxRange(edit) <= NSMaxRange(body), !replacement.contains(where: \.isNewline) else { return nil }
            var box = self
            box.body.length = max(0, body.length + delta)
            if implicit && box.body.length == 0 { return nil }
            return box
        }
        return self
    }
}

final class InlineTextView: NSTextView {
    var onSave: (() -> Void)?
    var onCommand: (String) -> Bool = { _ in false }
    var onNavigate: (Int) -> Void = { _ in }
    var onEscape: () -> Bool = { false }
    var onImage: (Data) -> Void = { _ in }
    var onImageFile: (URL) -> Void = { _ in }
    var onOpenURL: (URL) -> Void = { _ in }
    var focusToken: UUID?
    private var spans: [ScratchTextSpan] = []
    private var styleTask: Task<Void, Never>?
    func detach() { armed = false; removeMonitor(); styleTask?.cancel() }
    func requestFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }; self.arm()
        }
    }
    var focusOnAttach = false
    var baseFont: NSFont = .systemFont(ofSize: 15)
    var baseColor: NSColor = .labelColor
    var mathAnalysis = ScratchAnalysis() {
        didSet {
            if oldValue.mode != mathAnalysis.mode { updateMathWidth() }
            needsDisplay = true
            setAccessibilityHelp(mathAnalysis.mode == "math" ? mathAnalysis.results.joined(separator: ". ") : nil)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateMathWidth()
    }

    private func updateMathWidth() {
        guard let container = textContainer else { return }
        let math = mathAnalysis.mode == "math"
        container.widthTracksTextView = !math
        if math {
            container.containerSize = NSSize(width: max(80, bounds.width - textContainerInset.width * 2 - 180),
                                             height: .greatestFiniteMagnitude)
        }
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        if let replacementString {
            checkboxes = checkboxes.compactMap { $0.adjusted(for: affectedCharRange, replacement: replacementString) }
        }
        if mathAnalysis.mode == "math", let replacementString {
            let delta = replacementString.utf16.count - affectedCharRange.length
            var updated = mathAnalysis
            updated.source = ""
            updated.mathResults = updated.mathResults.compactMap { result in
                var range = result.range
                if affectedCharRange.location > NSMaxRange(range) { return result }
                if NSMaxRange(affectedCharRange) <= range.location {
                    range.location += delta
                } else {
                    // A changed line keeps its last answer while recalculating.
                    // Split/merged lines wait for fresh ranges from the worker.
                    if replacementString.contains(where: \.isNewline) ||
                        (string as NSString).substring(with: affectedCharRange).contains(where: \.isNewline) { return nil }
                    range.length = max(0, range.length + delta)
                }
                return ScratchMathResult(range: range, answer: result.answer)
            }
            mathAnalysis = updated
        }
        return true
    }
    private(set) var checkboxes: [NoteCheckbox] = []
    private var monitor: Any?
    private var armed = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let box = checkboxes.first(where: { hitRect(for: $0).contains(point) }) {
            arm()
            toggle(box)
            return
        }
        arm()
        super.mouseDown(with: event)
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for box in checkboxes {
            addCursorRect(hitRect(for: box), cursor: .pointingHand)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            armed = false
            removeMonitor()
            styleTask?.cancel()
        } else if focusOnAttach {
            focusOnAttach = false
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.window != nil else { return }
                    self.arm()
                    self.needsDisplay = true
                }
            }
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawCheckboxes()
        drawMathResults(in: dirtyRect)
        drawFallbackCaret()
    }

    private func drawMathResults(in dirtyRect: NSRect) {
        guard mathAnalysis.mode == "math",
              let manager = layoutManager, let container = textContainer else { return }
        let visible = manager.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y), in: container)
        let visibleCharacters = manager.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
        let results = mathAnalysis.mathResults
        var lower = 0
        var upper = results.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if NSMaxRange(results[middle].range) <= visibleCharacters.location { lower = middle + 1 }
            else { upper = middle }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: baseFont.pointSize, weight: .medium),
            .foregroundColor: baseColor.withAlphaComponent(0.75), .paragraphStyle: paragraph,
        ]
        let textLength = (string as NSString).length
        for result in results.dropFirst(lower) {
            if result.range.location >= NSMaxRange(visibleCharacters) { break }
            guard result.range.length > 0, NSMaxRange(result.range) <= textLength else { continue }
            let glyph = manager.glyphIndexForCharacter(at: NSMaxRange(result.range) - 1)
            guard NSLocationInRange(glyph, visible) else { continue }
            let end = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let rect = NSRect(x: end.maxX + textContainerOrigin.x + 12, y: line.minY + textContainerOrigin.y,
                              width: 168, height: line.height)
            ("→ " + result.answer as NSString).draw(in: rect, withAttributes: attributes)
        }
    }

    // MARK: Checkboxes

    func restyle() {
        styleTask?.cancel()
        let snapshot = string
        styleTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(70)) } catch { return }
            let work = Task.detached(priority: .userInitiated) { (NoteCheckbox.find(in: snapshot), ScratchTextSpan.parse(snapshot)) }
            let boxes = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard let self, !Task.isCancelled, self.string == snapshot else { return }
            self.checkboxes = boxes.0
            self.spans = boxes.1
            self.applyStyle()
        }
    }

    func clearDerivedStyle() {
        styleTask?.cancel()
        checkboxes = []; spans = []
    }

    private func applyStyle() {
        guard let storage = textStorage else { return }
        let font = baseFont
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: baseColor], range: whole)
        let isCode = string.components(separatedBy: .newlines).first?.lowercased().hasPrefix("code") == true
        if isCode { storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular), range: whole) }
        else {
            for span in spans {
                guard NSMaxRange(span.range) <= storage.length else { continue }
                switch span.kind {
                case "heading": storage.addAttribute(.font, value: NSFont.systemFont(ofSize: font.pointSize + 4, weight: .semibold), range: span.range)
                case "bold": storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: font.pointSize), range: span.range)
                case "italic": storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: span.range)
                case "underline": storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: span.range)
                case "strike": storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.range)
                case "comment": storage.addAttribute(.foregroundColor, value: baseColor.withAlphaComponent(0.5), range: span.range)
                case "link": if let url = span.url { storage.addAttribute(.link, value: url, range: span.range) }
                default: break
                }
            }
        }
        for box in checkboxes {
            guard NSMaxRange(box.marker) <= storage.length, NSMaxRange(box.body) <= storage.length else { continue }
            if box.implicit {
                let paragraph = NSMutableParagraphStyle()
                paragraph.firstLineHeadIndent = font.pointSize + 7
                paragraph.headIndent = font.pointSize + 7
                storage.addAttribute(.paragraphStyle, value: paragraph, range: box.body)
            } else { storage.addAttribute(.foregroundColor, value: NSColor.clear, range: box.marker) }
            // Reserve enough width for the drawn box so it cannot cover the
            // first letter of the item at larger editor font sizes.
            if box.marker.length > 0 {
                let markerWidth = (storage.string as NSString).substring(with: box.marker).size(withAttributes: [.font: font]).width
                storage.addAttribute(.kern, value: max(0, font.pointSize + 7 - markerWidth),
                                     range: NSRange(location: NSMaxRange(box.marker) - 1, length: 1))
            }
            if box.checked, box.body.length > 0 {
                storage.addAttributes([
                    .foregroundColor: baseColor.withAlphaComponent(0.45),
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ], range: box.body)
            }
        }
        storage.endEditing()
        typingAttributes = [.font: font, .foregroundColor: baseColor]
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func toggle(_ box: NoteCheckbox) {
        let edit = box.toggle
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        onSave?()
    }

    private func markerRect(for box: NoteCheckbox) -> NSRect {
        guard let layoutManager, let textContainer, NSMaxRange(box.marker) <= (string as NSString).length else { return .zero }
        if box.implicit, box.body.length > 0 {
            let glyph = layoutManager.glyphIndexForCharacter(at: box.body.location)
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            return NSRect(x: rect.minX + textContainerOrigin.x - baseFont.pointSize - 7,
                          y: rect.minY + textContainerOrigin.y, width: baseFont.pointSize + 1, height: rect.height)
        }
        let glyphs = layoutManager.glyphRange(forCharacterRange: box.marker, actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    private func boxRect(for box: NoteCheckbox) -> NSRect {
        let marker = markerRect(for: box)
        let side = min(max((font?.pointSize ?? 13) + 1, 12), marker.height)
        return NSRect(x: marker.minX, y: marker.midY - side / 2, width: side, height: side)
    }

    private func hitRect(for box: NoteCheckbox) -> NSRect {
        markerRect(for: box).union(boxRect(for: box)).insetBy(dx: -2, dy: -1)
    }

    private func drawCheckboxes() {
        for box in checkboxes {
            let rect = boxRect(for: box)
            guard rect.width > 0 else { continue }
            let color = box.checked ? NSColor.controlAccentColor : baseColor.withAlphaComponent(0.7)
            let name = box.checked ? "checkmark.square.fill" : "square"
            let config = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: box.checked ? "Checked" : "Unchecked")?
                .withSymbolConfiguration(config)
            else { continue }
            let size = image.size
            let target = NSRect(
                x: rect.minX,
                y: rect.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    // MARK: Keyboard

    private func drawFallbackCaret() {
        guard armed, let window, window.firstResponder !== self, selectedRange().length == 0 else { return }
        let screenRect = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        guard screenRect != .zero else { return }
        let local = convert(window.convertFromScreen(screenRect), from: nil)
        let height = max(local.height, font?.boundingRectForFont.height ?? 16)
        insertionPointColor.setFill()
        NSRect(x: local.minX, y: local.minY, width: 2, height: height).fill()
    }

    private func arm() {
        window?.makeFirstResponder(self)
        armed = true
        installMonitor()
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.route(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func route(_ event: NSEvent) -> Bool {
        guard armed, let window, window.isKeyWindow, event.window === window || event.window == nil else { return false }
        if let responder = window.firstResponder as? NSTextView, responder !== self {
            armed = false
            return false
        }
        if event.keyCode == 53 {
            if onEscape() { return true }
            armed = false
            needsDisplay = true
            return false
        }
        if event.modifierFlags.contains(.command) {
            return shortcut(event)
        }
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
        keyDown(with: event)
        needsDisplay = true
        return true
    }

    /// Vehla has no Edit menu, so the editor handles its own shortcuts.
    private func shortcut(_ event: NSEvent) -> Bool {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "\r":
            if let span = spans.first(where: { $0.kind == "link" && NSLocationInRange(selectedRange().location, $0.range) }), let url = span.url { onOpenURL(url) }
        case "s": onSave?()
        case "[": onNavigate(1)
        case "]": onNavigate(-1)
        case "b": wrapSelection("**")
        case "i": wrapSelection("*")
        case "u": wrapSelection("__")
        case "v": paste(nil)
        case "c": copy(nil)
        case "x": cut(nil)
        case "a": selectAll(nil)
        case "z":
            if event.modifierFlags.contains(.shift) {
                undoManager?.redo()
            } else {
                undoManager?.undo()
            }
        default: return false
        }
        return true
    }
}


extension InlineTextView {
    private var listMode: Bool {
        let first = string.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return first == "list" || first.hasPrefix("list:")
    }

    private static let slashCommands = ["/list", "/math", "/sum", "/average", "/count", "/code", "/text",
                                        "/checkbox", "/bullet", "/numbered", "/x", "/date", "/time",
                                        "/new", "/search", "/copy", "/paste", "/timer", "/import", "/export"]

    override var rangeForUserCompletion: NSRange {
        let source = string as NSString
        let cursor = selectedRange().location
        guard cursor <= source.length else { return super.rangeForUserCompletion }
        let line = source.lineRange(for: NSRange(location: cursor, length: 0))
        let prefix = source.substring(with: NSRange(location: line.location, length: cursor - line.location))
        if prefix.range(of: #"^\s*/[a-z]*$"#, options: .regularExpression) != nil,
           let slash = prefix.firstIndex(of: "/") {
            let offset = prefix[..<slash].utf16.count
            return NSRange(location: line.location + offset, length: cursor - line.location - offset)
        }
        return super.rangeForUserCompletion
    }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        let source = string as NSString
        guard NSMaxRange(charRange) <= source.length else { return nil }
        let prefix = source.substring(with: charRange).lowercased()
        guard prefix.hasPrefix("/"), !prefix.hasPrefix("//") else {
            return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
        }
        index.pointee = 0
        return Self.slashCommands.filter { $0.hasPrefix(prefix) }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        if let text = insertString as? String, text == "x" || text == "X" {
            checkTrigger()
        }
        if let text = insertString as? String, text == "/", window != nil {
            let range = rangeForUserCompletion
            if range.location != NSNotFound, (string as NSString).substring(with: range) == "/" {
                DispatchQueue.main.async { [weak self] in self?.complete(nil) }
            }
        }
    }

    private func checkTrigger() {
        let source = string as NSString, cursor = selectedRange().location
        guard cursor >= 2, cursor <= source.length,
              source.substring(with: NSRange(location: cursor - 2, length: 2)).lowercased() == "/x" else { return }
        let range = source.lineRange(for: NSRange(location: cursor - 2, length: 0))
        let prefix = source.substring(with: NSRange(location: range.location, length: cursor - 2 - range.location))
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("//"), !trimmed.hasPrefix("#"),
              range.location != 0 || !listMode else { return }
        let box = NoteCheckbox.find(in: prefix).first
        guard box != nil || (listMode && range.location > 0) else { return }
        super.insertText("", replacementRange: NSRange(location: cursor - 2, length: 2))
        if let box {
            let edit = box.toggle
            super.insertText(edit.replacement, replacementRange: NSRange(location: range.location + edit.range.location, length: edit.range.length))
        } else {
            super.insertText("[x] ", replacementRange: NSRange(location: range.location, length: 0))
        }
        let newLine = (string as NSString).lineRange(for: NSRange(location: range.location, length: 0))
        setSelectedRange(NSRange(location: NSMaxRange(newLine) - ((string as NSString).substring(with: newLine).hasSuffix("\n") ? 1 : 0), length: 0))
    }

    private func executeSlash(_ line: String, range: NSRange) -> Bool {
        let command = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard command.hasPrefix("/"), !command.hasPrefix("//") else { return false }
        let modes = ["list", "math", "sum", "average", "count", "code", "text"]
        if command.hasPrefix("/"), modes.contains(String(command.dropFirst())) {
            let mode = String(command.dropFirst())
            insertText("", replacementRange: NSRange(location: range.location, length: (line as NSString).length))
            let source = string as NSString
            let first = source.lineRange(for: NSRange(location: 0, length: 0))
            let header = source.substring(with: first).trimmingCharacters(in: .newlines)
            let existingMode = header.lowercased().split(separator: ":").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if modes.contains(existingMode) || header.isEmpty {
                let title = header.firstIndex(of: ":").map { String(header[header.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
                insertText(mode + (title.isEmpty ? "" : ": " + title) + "\n", replacementRange: first)
            } else { insertText(mode + "\n", replacementRange: NSRange(location: 0, length: 0)) }
            setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
            return true
        }
        let replacements = ["/checkbox": "[] ", "/bullet": "- ", "/numbered": "1. ",
                            "/date": Date().formatted(date: .numeric, time: .omitted),
                            "/time": Date().formatted(date: .omitted, time: .shortened)]
        if let replacement = replacements[command] {
            insertText(replacement, replacementRange: NSRange(location: range.location, length: (line as NSString).length))
            return true
        }
        let name = command.split(separator: " ").first.map(String.init) ?? ""
        if ["/new", "/search", "/copy", "/paste", "/timer", "/import", "/export"].contains(name) {
            if name == "/timer", ScratchTimerCommand.parse(String(command.dropFirst())) == nil,
               !["/timer p", "/timer r", "/timer s", "/timer 0"].contains(command) { return false }
            insertText("", replacementRange: NSRange(location: range.location, length: (line as NSString).length))
            return onCommand(command)
        }
        return false
    }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let text = board.string(forType: .string) {
            let isCode = string.components(separatedBy: .newlines).first?.lowercased().hasPrefix("code") == true
            let plain = isCode ? text : text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            insertText(plain, replacementRange: selectedRange())
        } else if let data = board.data(forType: .png) ?? board.data(forType: .tiff) { onImage(data) }
        else if let url = NSURL(from: board) as URL?, url.isFileURL { onImageFile(url) }
    }

    override func insertNewline(_ sender: Any?) {
        let source = string as NSString
        let selection = selectedRange()
        let lineRange = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let line = source.substring(with: lineRange).trimmingCharacters(in: .newlines)
        if executeSlash(line, range: lineRange) { return }
        if onCommand(line) { super.insertNewline(sender); return }
        let prefixRegex = try! NSRegularExpression(pattern: #"^(\s*)(- \[ \]|- \[x\]|\[ \]|\[x\]|\[\]|[-*]|\d+\.)\s+"#)
        if let match = prefixRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
            let indent = (line as NSString).substring(with: match.range(at: 1))
            var marker = (line as NSString).substring(with: match.range(at: 2)).replacingOccurrences(of: "[x]", with: "[ ]")
            if let number = Int(marker.dropLast()), marker.hasSuffix(".") { marker = "\(number + 1)." }
            if (line as NSString).length == match.range.length {
                insertText("", replacementRange: NSRange(location: lineRange.location, length: match.range.length))
            } else { insertText("\n" + indent + marker + " ", replacementRange: selection) }
        } else if listMode && lineRange.location == 0 {
            super.insertNewline(sender)
        } else if listMode && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            super.insertNewline(sender)
        } else { super.insertNewline(sender) }
    }

    override func insertTab(_ sender: Any?) { insertText("    ", replacementRange: selectedRange()) }
    override func insertBacktab(_ sender: Any?) {
        let source = string as NSString
        let line = source.lineRange(for: selectedRange())
        let prefix = source.substring(with: line).prefix(4)
        let count = prefix.prefix(while: { $0 == " " }).count
        if count > 0 { insertText("", replacementRange: NSRange(location: line.location, length: count)) }
    }

    func wrapSelection(_ marker: String) {
        let range = selectedRange(), source = string as NSString
        let value = source.substring(with: range)
        insertText(marker + value + marker, replacementRange: range)
        setSelectedRange(NSRange(location: range.location + marker.count, length: range.length))
    }
}

/// Trackpad scrolling is delivered to the scroll view before the text view.
/// Keep its vertical behavior and reserve deliberate horizontal gestures for
/// note navigation, committing only after fingers lift (never on momentum).
@MainActor
final class NoteScrollView: NSScrollView {
    var onNavigate: (Int) -> Void = { _ in }
    private var swipeTracker = NoteSwipeTracker()

    override func scrollWheel(with event: NSEvent) {
        switch swipeTracker.step(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                                phase: event.phase, momentum: event.momentumPhase,
                                precise: event.hasPreciseScrollingDeltas) {
        case .passThrough: super.scrollWheel(with: event)
        case .consume: break
        case .navigate(let direction): onNavigate(direction)
        }
    }

    override func swipe(with event: NSEvent) {
        if abs(event.deltaX) > abs(event.deltaY), event.deltaX != 0 {
            onNavigate(event.deltaX > 0 ? 1 : -1)
        } else { super.swipe(with: event) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { swipeTracker = NoteSwipeTracker() }
    }
}

struct NoteSwipeTracker {
    enum Action: Equatable { case passThrough, consume, navigate(Int) }
    private enum Axis { case undecided, horizontal, vertical }
    private var axis = Axis.undecided
    private var distanceX: CGFloat = 0
    private var distanceY: CGFloat = 0
    private var tracking = false

    mutating func step(x: CGFloat, y: CGFloat, phase: NSEvent.Phase,
                       momentum: NSEvent.Phase = [], precise: Bool = true) -> Action {
        if phase.contains(.began) || phase.contains(.mayBegin) {
            self = NoteSwipeTracker()
            tracking = true
        }
        if !momentum.isEmpty { return axis == .horizontal ? .consume : .passThrough }
        guard precise, tracking, !phase.isEmpty else { return .passThrough }
        if phase.contains(.cancelled) {
            let handled = axis == .horizontal
            self = NoteSwipeTracker()
            return handled ? .consume : .passThrough
        }
        distanceX += x
        distanceY += y
        if axis == .undecided, max(abs(distanceX), abs(distanceY)) >= 8 {
            axis = abs(distanceX) > abs(distanceY) * 1.5 ? .horizontal : .vertical
        }
        if phase.contains(.ended) {
            tracking = false
            if axis == .horizontal, abs(distanceX) >= 60 {
                return .navigate(distanceX > 0 ? 1 : -1)
            }
        }
        return axis == .horizontal ? .consume : .passThrough
    }
}


struct ScratchTextSpan: Sendable {
    var range: NSRange
    var kind: String
    var url: URL?
    static func parse(_ text: String) -> [Self] {
        var result: [Self] = []
        let range = NSRange(location: 0, length: (text as NSString).length)
        let patterns = [("heading", #"^#{1,3} .*$"#), ("bold", #"\*\*[^\n*]+\*\*"#), ("italic", #"(?<!\*)\*[^\n*]+\*(?!\*)"#), ("underline", #"__[^\n_]+__"#), ("strike", #"~~[^\n~]+~~"#), ("comment", #"^\s*//.*$"#)]
        for (kind, pattern) in patterns {
            guard !Task.isCancelled else { return [] }
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) {
                result += regex.matches(in: text, range: range).map { Self(range: $0.range, kind: kind) }
            }
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            result += detector.matches(in: text, range: range).compactMap { match in
                guard let url = match.url, ["http", "https"].contains(url.scheme ?? "") else { return nil }
                return Self(range: match.range, kind: "link", url: url)
            }
        }
        return result
    }
}
