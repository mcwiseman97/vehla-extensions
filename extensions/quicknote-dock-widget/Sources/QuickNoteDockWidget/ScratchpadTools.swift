import Foundation
import Vision

struct ScratchAnalysis: Equatable, Sendable {
    var mode = "text"
    var results: [String] = []
    var summary = ""
    var source = ""
    var mathResults: [ScratchMathResult] = []
    var checkboxes: [NoteCheckbox] = []
    var spans: [ScratchTextSpan] = []
    var prepared = false
    var cacheCost = 0
}

struct ScratchMathResult: Equatable, Sendable {
    let range: NSRange
    let answer: String
}

actor ScratchTools {
    func search(_ notes: [ScratchNote], query: String, scope: String) throws -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try notes.filter { note in
            try Task.checkCancellation()
            let included = scope == "void" ? note.deleted != nil : note.deleted == nil && (scope == "slots" ? note.slot != nil : note.slot == nil)
            return included && (needle.isEmpty || note.content.localizedCaseInsensitiveContains(needle))
        }
        return (scope == "slots" ? result.sorted { ($0.slot ?? 0) < ($1.slot ?? 0) } : result).map(\.id)
    }

    func matchingNotes(_ notes: [ScratchNote], ids: [String]) -> [ScratchNote] {
        let index = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        return ids.compactMap { index[$0] }
    }

    func analyze(_ text: String) throws -> ScratchAnalysis {
        try Task.checkCancellation()
        let lines = text.components(separatedBy: .newlines)
        let mode = lines.first?.lowercased().split(separator: ":").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        var result = ScratchAnalysis(mode: ["math", "sum", "average", "count", "list", "code"].contains(mode) ? mode : "text")
        result.source = text
        let words = text.split(whereSeparator: \.isWhitespace).count
        result.summary = "\(words) words · \(text.count) characters · \(lines.count) lines"
        if mode == "count" { result.results = [result.summary] }
        if mode == "sum" || mode == "average" {
            let regex = try NSRegularExpression(pattern: #"[-+]?\d+(?:\.\d+)?"#)
            let numbers = lines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.flatMap { line in
                regex.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)).compactMap {
                    Double((line as NSString).substring(with: $0.range))
                }
            }
            if !numbers.isEmpty {
                let value = numbers.reduce(0, +) / (mode == "average" ? Double(numbers.count) : 1)
                result.results = ["\(mode.capitalized): \(Self.format(value)) · \(numbers.count) values"]
            }
        }
        if mode == "math" {
            var variables: [String: Double] = [:]
            var offset = (lines.first ?? "").utf16.count + 1
            for (index, line) in lines.dropFirst().enumerated() {
                let range = NSRange(location: offset, length: line.utf16.count)
                defer { offset += line.utf16.count + 1 }
                try Task.checkCancellation()
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { continue }
                var expression = trimmed
                var variable: String?
                if let equals = trimmed.firstIndex(of: "="), !trimmed.hasSuffix("=") {
                    let name = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
                    if name.range(of: #"^[a-zA-Z_][a-zA-Z_0-9]*$"#, options: .regularExpression) != nil {
                        variable = name; expression = String(trimmed[trimmed.index(after: equals)...])
                    } else { continue }
                } else if trimmed.hasSuffix("=") { expression = String(trimmed.dropLast()) }
                else { continue }
                do {
                    let value: Double
                    if let converted = Self.convert(expression) { value = converted.value }
                    else { var parser = MathParser(expression, variables: variables); value = try parser.evaluate() }
                    guard value.isFinite else { throw ScratchError.message("Non-finite result") }
                    if let variable { variables[variable] = value }
                    let unit = Self.convert(expression)?.unit ?? ""
                    let answer = "\(Self.format(value))\(unit.isEmpty ? "" : " " + unit)"
                    result.results.append("Line \(index + 2)  →  \(answer)")
                    result.mathResults.append(ScratchMathResult(range: range, answer: answer))
                } catch {
                    result.results.append("Line \(index + 2)  →  Check expression")
                    result.mathResults.append(ScratchMathResult(range: range, answer: "Check expression"))
                }
            }
        }
        result.checkboxes = NoteCheckbox.find(in: text)
        result.spans = ScratchTextSpan.parse(text)
        try Task.checkCancellation()
        result.prepared = true
        result.cacheCost = text.utf8.count + result.checkboxes.count * 96 + result.spans.count * 64
            + result.mathResults.reduce(0) { $0 + $1.answer.utf8.count + 32 }
        return result
    }

    /// Bound startup work as well as retained memory. Each note is analyzed in
    /// a separate actor call so interactive work can cancel/yield between notes.
    func warmCandidates(_ notes: [ScratchNote]) throws -> [ScratchNote] {
        var cost = 0
        var result: [ScratchNote] = []
        for note in notes where note.deleted == nil {
            try Task.checkCancellation()
            let size = note.content.utf8.count
            guard result.count < ScratchPresentationStore.noteLimit else { break }
            if cost + size > ScratchPresentationStore.byteLimit / 2 { continue }
            cost += size; result.append(note)
        }
        return result
    }

    static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...6)).locale(Locale(identifier: "en_US")))
    }

    static func convert(_ expression: String) -> (value: Double, unit: String)? {
        let parts = expression.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 4, parts[2] == "to", let number = Double(parts[0]) else { return nil }
        let units: [String: (String, Double)] = ["m": ("length", 1), "cm": ("length", 0.01), "mm": ("length", 0.001), "km": ("length", 1000), "in": ("length", 0.0254), "ft": ("length", 0.3048), "yd": ("length", 0.9144), "mi": ("length", 1609.344), "g": ("mass", 1), "kg": ("mass", 1000), "lb": ("mass", 453.59237), "oz": ("mass", 28.349523125), "ml": ("volume", 1), "l": ("volume", 1000), "gal": ("volume", 3785.411784), "s": ("time", 1), "min": ("time", 60), "h": ("time", 3600)]
        if let from = units[parts[1]], let to = units[parts[3]], from.0 == to.0 { return (number * from.1 / to.1, parts[3]) }
        if parts[1] == "c", parts[3] == "f" { return (number * 9 / 5 + 32, "°F") }
        if parts[1] == "f", parts[3] == "c" { return ((number - 32) * 5 / 9, "°C") }
        return nil
    }

    func ocr(data: Data) throws -> String {
        try Task.checkCancellation()
        guard data.count <= 20 * 1_024 * 1_024 else { throw ScratchError.message("Choose an image smaller than 20 MiB.") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(data: data).perform([request])
        try Task.checkCancellation()
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        guard !text.isEmpty else { throw ScratchError.message("No text was recognized in this image.") }
        return text
    }
}

/// A bounded arithmetic grammar, rather than executing arbitrary expressions.
struct MathParser {
    private var tokens: [String]
    private var position = 0
    private var depth = 0
    private let variables: [String: Double]
    init(_ expression: String, variables: [String: Double] = [:]) {
        self.variables = variables
        let normalized = expression.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "**", with: "^").replacingOccurrences(of: ",", with: "")
        let regex = try! NSRegularExpression(pattern: #"\d+(?:\.\d*)?(?:[eE][+-]?\d+)?|\.\d+|[a-zA-Z_][a-zA-Z_0-9]*|[^\s]"#)
        tokens = regex.matches(in: normalized, range: NSRange(location: 0, length: (normalized as NSString).length)).map { (normalized as NSString).substring(with: $0.range) }
    }
    mutating func evaluate() throws -> Double {
        guard tokens.count <= 512 else { throw ScratchError.message("Expression too long") }
        let result = try sum()
        guard position == tokens.count, result.isFinite else { throw ScratchError.message("Invalid expression") }
        return result
    }
    private var current: String? { position < tokens.count ? tokens[position] : nil }
    private mutating func take(_ value: String) -> Bool {
        guard current == value else { return false }; position += 1; return true
    }
    private mutating func sum() throws -> Double {
        var value = try product()
        while current == "+" || current == "-" {
            let op = current!; position += 1
            let start = position
            let rhs = try product()
            // Colloquial percentages: 100 + 15% = 115.
            let percentage = position > start && tokens[position - 1] == "%"
            let operand = percentage ? value * rhs : rhs
            value = op == "+" ? value + operand : value - operand
        }
        return value
    }
    private mutating func product() throws -> Double {
        var value = try power()
        while ["*", "/", "x", "of"].contains(current ?? "") {
            let op = current!; position += 1; let rhs = try power()
            value = op == "/" ? value / rhs : value * rhs
        }
        return value
    }
    private mutating func power() throws -> Double {
        depth += 1; defer { depth -= 1 }
        guard depth < 64 else { throw ScratchError.message("Expression too deep") }
        var value = try atom()
        if take("^") { value = pow(value, try power()) }
        if take("%") { value /= 100 }
        return value
    }
    private mutating func atom() throws -> Double {
        if take("+") { return try power() }
        if take("-") { return -(try power()) }
        if take("(") { let value = try sum(); guard take(")") else { throw ScratchError.message("Missing parenthesis") }; return value }
        guard let token = current else { throw ScratchError.message("Missing number") }
        position += 1
        if let number = Double(token) { return number }
        if let value = variables[token] { return value }
        if token == "pi" { return .pi }
        if ["sqrt", "abs", "ceil", "floor", "log", "log2", "sin", "cos"].contains(token), take("(") {
            let value = try sum(); guard take(")") else { throw ScratchError.message("Missing parenthesis") }
            switch token {
            case "sqrt": return sqrt(value)
            case "abs": return abs(value)
            case "ceil": return ceil(value)
            case "floor": return floor(value)
            case "log": return log10(value)
            case "log2": return log2(value)
            case "sin": return sin(value)
            default: return cos(value)
            }
        }
        throw ScratchError.message("Unknown variable")
    }
}

struct ScratchTimerCommand: Equatable, Sendable {
    var duration: TimeInterval? // nil means stopwatch
    var label: String
    static func parse(_ line: String) -> ScratchTimerCommand? {
        guard line.lowercased().hasPrefix("timer") else { return nil }
        var body = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        var label = "Scratchpad"
        if let range = body.range(of: #":(?=\s|[^0-9])"#, options: .regularExpression) {
            label = String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            body = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if body.isEmpty { return Self(duration: nil, label: label) }
        if body.lowercased() == "pomo" { return Self(duration: 25 * 60, label: "\(label) · Focus") }
        let parts = body.split(separator: ":")
        let duration: Double?
        if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]), seconds < 60 {
            duration = minutes * 60 + seconds
        } else { duration = Double(body).map { $0 * 60 } }
        guard let duration, duration > 0, duration <= 7 * 86_400 else { return nil }
        return Self(duration: duration, label: label)
    }
}


/// UI-side projection of actor-produced results. No parsing or hashing of note
/// bodies occurs here. Derived state is intentionally not written to disk.
struct ScratchPresentationStore {
    static let noteLimit = 128
    static let byteLimit = 16 * 1_024 * 1_024
    private var entries: [String: ScratchAnalysis] = [:]
    private var order: [String] = []
    private(set) var cost = 0
    var count: Int { entries.count }

    mutating func result(for id: String, text: String) -> ScratchAnalysis? {
        guard let result = entries[id], result.source == text else { return nil }
        order.removeAll { $0 == id }; order.append(id)
        return result
    }

    mutating func insert(_ result: ScratchAnalysis, for id: String) {
        if let previous = entries.removeValue(forKey: id) { cost -= previous.cacheCost }
        order.removeAll { $0 == id }
        guard result.prepared, result.cacheCost <= Self.byteLimit else { return }
        entries[id] = result; order.append(id); cost += result.cacheCost
        while entries.count > Self.noteLimit || cost > Self.byteLimit {
            let oldest = order.removeFirst()
            if let evicted = entries.removeValue(forKey: oldest) { cost -= evicted.cacheCost }
        }
    }
}
