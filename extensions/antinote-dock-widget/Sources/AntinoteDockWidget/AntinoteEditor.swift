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

    func makeCoordinator() -> InlineEditorCoordinator {
        InlineEditorCoordinator(onEdit: onEdit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
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
        textView.font = .systemFont(ofSize: 13)
        textView.drawsBackground = false
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
        textView.restyle()
        textView.delegate = context.coordinator
        textView.onSave = onSave
        textView.focusOnAttach = autoFocus
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onEdit = onEdit
        guard let textView = scroll.documentView as? InlineTextView else { return }
        textView.onSave = onSave
        var changed = false
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            changed = true
        }
        if textView.baseColor != textColor {
            textView.baseColor = textColor
            changed = true
        }
        if changed { textView.restyle() }
    }
}

@MainActor
final class InlineEditorCoordinator: NSObject, NSTextViewDelegate {
    var onEdit: (String) -> Void

    init(onEdit: @escaping (String) -> Void) {
        self.onEdit = onEdit
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        (textView as? InlineTextView)?.restyle()
        onEdit(textView.string)
    }
}

struct NoteCheckbox: Equatable {
    /// The whole marker, e.g. `- [ ]` or `[]`.
    var marker: NSRange
    /// Everything between the brackets (empty, a space, or `x`).
    var inner: NSRange
    var dashed: Bool
    var checked: Bool
    /// The rest of the line after the marker.
    var body: NSRange

    private static let pattern = try! NSRegularExpression(
        pattern: #"^[ \t]*((- )?\[([ xX]?)\])(?=[ \t]|$)(.*)$"#,
        options: [.anchorsMatchLines]
    )

    static func find(in text: String) -> [NoteCheckbox] {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        return pattern.matches(in: text, range: whole).map { match in
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
    }

    /// The edit that flips this checkbox, keeping Antinote's marker style.
    var toggle: (range: NSRange, replacement: String) {
        if checked {
            return (inner, dashed ? " " : "")
        }
        return (inner, "x")
    }
}

final class InlineTextView: NSTextView {
    var onSave: (() -> Void)?
    var focusOnAttach = false
    var baseColor: NSColor = .labelColor
    private var checkboxes: [NoteCheckbox] = []
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
        drawFallbackCaret()
    }

    // MARK: Checkboxes

    func restyle() {
        guard let storage = textStorage else { return }
        let font = self.font ?? .systemFont(ofSize: 13)
        let whole = NSRange(location: 0, length: storage.length)
        checkboxes = NoteCheckbox.find(in: string)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: baseColor], range: whole)
        for box in checkboxes {
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: box.marker)
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
        guard let layoutManager, let textContainer else { return .zero }
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
        guard armed, let window, event.window === window || event.window == nil else { return false }
        if event.keyCode == 53 {
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
        case "s": onSave?()
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
