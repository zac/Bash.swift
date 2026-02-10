import ArgumentParser
import Foundation

struct HtmlToMarkdownCommand: BuiltinCommand {
    enum HeadingStyle: String, ExpressibleByArgument {
        case atx
        case setext
    }

    struct Options: ParsableArguments {
        @Option(name: [.short, .customLong("bullet")], help: "Bullet marker for unordered lists")
        var bullet = "-"

        @Option(name: [.short, .customLong("code")], help: "Fence marker for code blocks")
        var code = "```"

        @Option(name: [.customShort("r"), .customLong("hr")], help: "Horizontal rule marker")
        var hr = "---"

        @Option(name: [.customLong("heading-style")], help: "Heading style: atx or setext")
        var headingStyle: HeadingStyle = .atx

        @Argument(help: "Input file path (defaults to stdin)")
        var file: String?
    }

    static let name = "html-to-markdown"
    static let overview = "Convert HTML content to Markdown"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let input: String
        if options.file == nil || options.file == "-" {
            input = CommandIO.decodeString(context.stdin)
        } else {
            let path = options.file ?? ""
            do {
                let data = try await context.filesystem.readFile(path: context.resolvePath(path))
                input = CommandIO.decodeString(data)
            } catch {
                context.writeStderr("html-to-markdown: \(path): No such file or directory\n")
                return 1
            }
        }

        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return 0
        }

        let converter = HTMLToMarkdownConverter(
            bullet: options.bullet.isEmpty ? "-" : options.bullet,
            codeFence: options.code.isEmpty ? "```" : options.code,
            horizontalRule: options.hr.isEmpty ? "---" : options.hr,
            headingStyle: options.headingStyle
        )

        do {
            let output = try converter.convert(input)
            if output.isEmpty {
                return 0
            }
            context.writeStdout(output)
            if !output.hasSuffix("\n") {
                context.writeStdout("\n")
            }
            return 0
        } catch {
            context.writeStderr("html-to-markdown: conversion error: \(error.localizedDescription)\n")
            return 1
        }
    }
}

private struct HTMLToMarkdownConverter {
    let bullet: String
    let codeFence: String
    let horizontalRule: String
    let headingStyle: HtmlToMarkdownCommand.HeadingStyle

    func convert(_ input: String) throws -> String {
        let rendered = convertFragment(input)
        return collapseSpacing(rendered).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func convertFragment(_ source: String) -> String {
        var text = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for tag in ["script", "style", "footer"] {
            text = replacePattern(
                pattern: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>",
                in: text
            ) { _, _ in "" }
        }

        text = replacePattern(
            pattern: "(?is)<pre\\b[^>]*>\\s*(?:<code\\b[^>]*>)?(.*?)(?:</code\\s*>)?\\s*</pre\\s*>",
            in: text
        ) { match, original in
            let raw = decodeEntities(group(match, in: original, at: 1))
            let stripped = stripAllTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else {
                return ""
            }
            return "\n\n\(codeFence)\n\(stripped)\n\(codeFence)\n\n"
        }

        text = replacePattern(pattern: "(?is)<hr\\b[^>]*?/?>", in: text) { _, _ in
            "\n\n\(horizontalRule)\n\n"
        }

        text = replacePattern(
            pattern: "(?is)<blockquote\\b[^>]*>(.*?)</blockquote\\s*>",
            in: text
        ) { match, original in
            let content = convertFragment(group(match, in: original, at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                return ""
            }
            let quoted = content
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? ">" : "> \($0)" }
                .joined(separator: "\n")
            return "\n\n\(quoted)\n\n"
        }

        text = convertTables(text)
        text = convertLists(text)

        for level in 1...6 {
            text = replacePattern(
                pattern: "(?is)<h\(level)\\b[^>]*>(.*?)</h\(level)\\s*>",
                in: text
            ) { match, original in
                let content = convertInline(group(match, in: original, at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else {
                    return ""
                }
                return "\n\n\(renderHeading(level: level, text: content))\n\n"
            }
        }

        text = replacePattern(
            pattern: "(?is)<p\\b[^>]*>(.*?)</p\\s*>",
            in: text
        ) { match, original in
            let content = convertInline(group(match, in: original, at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                return "\n\n"
            }
            return "\n\n\(content)\n\n"
        }

        text = replacePattern(pattern: "(?is)<br\\b[^>]*?/?>", in: text) { _, _ in "\n" }

        text = replacePattern(
            pattern: "(?is)</?(?:div|section|article|main|header|body|html)\\b[^>]*>",
            in: text
        ) { _, _ in "\n" }

        text = convertInline(text)
        text = stripAllTags(text)
        text = decodeEntities(text)
        return text
    }

    private func convertInline(_ source: String) -> String {
        var text = source

        text = replacePattern(
            pattern: "(?is)<img\\b([^>]*?)/?>",
            in: text
        ) { match, original in
            let attributes = group(match, in: original, at: 1)
            let src = extractAttribute(named: "src", from: attributes) ?? ""
            let alt = extractAttribute(named: "alt", from: attributes) ?? ""
            return "![\(decodeEntities(alt))](\(decodeEntities(src)))"
        }

        text = replacePattern(
            pattern: "(?is)<a\\b([^>]*)>(.*?)</a\\s*>",
            in: text
        ) { match, original in
            let attributes = group(match, in: original, at: 1)
            let href = extractAttribute(named: "href", from: attributes) ?? ""
            let label = convertInline(group(match, in: original, at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if href.isEmpty {
                return label
            }
            return "[\(label.isEmpty ? href : label)](\(decodeEntities(href)))"
        }

        text = replacePattern(
            pattern: "(?is)<(?:strong|b)\\b[^>]*>(.*?)</(?:strong|b)\\s*>",
            in: text
        ) { match, original in
            let value = convertInline(group(match, in: original, at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "" : "**\(value)**"
        }

        text = replacePattern(
            pattern: "(?is)<(?:em|i)\\b[^>]*>(.*?)</(?:em|i)\\s*>",
            in: text
        ) { match, original in
            let value = convertInline(group(match, in: original, at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "" : "_\(value)_"
        }

        text = replacePattern(
            pattern: "(?is)<code\\b[^>]*>(.*?)</code\\s*>",
            in: text
        ) { match, original in
            let value = decodeEntities(group(match, in: original, at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                return ""
            }
            let escaped = value.replacingOccurrences(of: "`", with: "\\`")
            return "`\(escaped)`"
        }

        return text
    }

    private func renderHeading(level: Int, text: String) -> String {
        if headingStyle == .setext, level <= 2 {
            let marker = level == 1 ? "=" : "-"
            let underline = String(repeating: marker, count: max(3, text.count))
            return "\(text)\n\(underline)"
        }
        return "\(String(repeating: "#", count: level)) \(text)"
    }

    private func convertLists(_ source: String) -> String {
        var output = source
        while let block = firstBalancedBlock(in: output, tags: ["ul", "ol"]) {
            let content = String(output[block.innerRange])
            let rendered = renderList(
                items: extractListItems(from: content),
                ordered: block.tag == "ol"
            )
            let replacement = rendered.isEmpty ? "" : "\n\n\(rendered)\n\n"
            output.replaceSubrange(block.range, with: replacement)
        }
        return output
    }

    private func renderList(items: [String], ordered: Bool) -> String {
        var lines: [String] = []
        var displayIndex = 1

        for item in items {
            let renderedLines = renderListItemLines(item)
            guard let first = renderedLines.first else {
                continue
            }

            let marker = ordered ? "\(displayIndex)." : bullet
            lines.append("\(marker) \(first)")
            for line in renderedLines.dropFirst() where !line.isEmpty {
                lines.append("  \(line)")
            }
            displayIndex += 1
        }

        return lines.joined(separator: "\n")
    }

    private func renderListItemLines(_ itemHTML: String) -> [String] {
        let rendered = convertFragment(itemHTML)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if rendered.isEmpty {
            return []
        }

        var lines = collapseSpacing(rendered)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        while lines.first == "" {
            lines.removeFirst()
        }
        while lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    private func extractListItems(from content: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "(?is)</?li\\b[^>]*>") else {
            return []
        }

        let matches = regex.matches(
            in: content,
            range: NSRange(content.startIndex..<content.endIndex, in: content)
        )
        guard !matches.isEmpty else {
            return []
        }

        var items: [String] = []
        var depth = 0
        var startIndex: String.Index?

        for match in matches {
            guard let range = Range(match.range, in: content) else {
                continue
            }
            let tagText = String(content[range]).lowercased()
            let isClosing = tagText.hasPrefix("</")

            if !isClosing {
                if depth == 0 {
                    startIndex = range.upperBound
                }
                depth += 1
                continue
            }

            if depth > 0 {
                depth -= 1
                if depth == 0, let start = startIndex {
                    items.append(String(content[start..<range.lowerBound]))
                    startIndex = nil
                }
            }
        }

        return items
    }

    private func convertTables(_ source: String) -> String {
        var output = source
        while let block = firstBalancedBlock(in: output, tags: ["table"]) {
            let content = String(output[block.innerRange])
            let rendered = renderTable(from: content)
            let replacement = rendered.isEmpty ? "" : "\n\n\(rendered)\n\n"
            output.replaceSubrange(block.range, with: replacement)
        }
        return output
    }

    private func renderTable(from content: String) -> String {
        let rows = parseTableRows(from: content)
        guard !rows.isEmpty else {
            return ""
        }

        let headerIndex = rows.firstIndex { row in
            row.contains { $0.isHeader }
        }

        let header: [String]
        let body: [[String]]
        if let headerIndex {
            header = rows[headerIndex].map(\.text)
            body = rows.enumerated().compactMap { index, row in
                index == headerIndex ? nil : row.map(\.text)
            }
        } else {
            header = rows[0].map(\.text)
            body = rows.dropFirst().map { $0.map(\.text) }
        }

        let columnCount = max(
            1,
            max(header.count, body.map(\.count).max() ?? 0)
        )
        let paddedHeader = padCells(header, to: columnCount)
        let paddedBody = body.map { padCells($0, to: columnCount) }

        var lines: [String] = []
        lines.append(renderTableRow(paddedHeader))
        lines.append("| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |")
        for row in paddedBody {
            lines.append(renderTableRow(row))
        }
        return lines.joined(separator: "\n")
    }

    private func parseTableRows(from content: String) -> [[TableCell]] {
        guard let rowRegex = try? NSRegularExpression(pattern: "(?is)<tr\\b[^>]*>(.*?)</tr\\s*>") else {
            return []
        }

        let rowMatches = rowRegex.matches(
            in: content,
            range: NSRange(content.startIndex..<content.endIndex, in: content)
        )

        return rowMatches.compactMap { match in
            let rowContent = group(match, in: content, at: 1)
            let cells = parseTableCells(from: rowContent)
            return cells.isEmpty ? nil : cells
        }
    }

    private func parseTableCells(from rowContent: String) -> [TableCell] {
        guard let cellRegex = try? NSRegularExpression(pattern: "(?is)<(th|td)\\b[^>]*>(.*?)</(?:th|td)\\s*>") else {
            return []
        }

        let matches = cellRegex.matches(
            in: rowContent,
            range: NSRange(rowContent.startIndex..<rowContent.endIndex, in: rowContent)
        )

        return matches.compactMap { match in
            let tag = group(match, in: rowContent, at: 1).lowercased()
            let text = renderTableCell(group(match, in: rowContent, at: 2))
            return TableCell(text: text, isHeader: tag == "th")
        }
    }

    private func renderTableCell(_ cellHTML: String) -> String {
        var text = replacePattern(pattern: "(?is)<br\\b[^>]*?/?>", in: cellHTML) { _, _ in "\n" }
        text = convertInline(text)
        text = stripAllTags(text)
        text = decodeEntities(text)
        text = replacePattern(pattern: "\\s+", in: text) { _, _ in " " }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func padCells(_ cells: [String], to count: Int) -> [String] {
        if cells.count >= count {
            return cells
        }
        return cells + Array(repeating: "", count: count - cells.count)
    }

    private func renderTableRow(_ cells: [String]) -> String {
        let escaped = cells.map { value in
            value.replacingOccurrences(of: "|", with: "\\|")
        }
        return "| " + escaped.joined(separator: " | ") + " |"
    }

    private func firstBalancedBlock(in source: String, tags: [String]) -> HTMLBlock? {
        guard !tags.isEmpty else {
            return nil
        }

        let pattern = tags.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "(?is)</?(\(pattern))\\b[^>]*>") else {
            return nil
        }

        let matches = regex.matches(
            in: source,
            range: NSRange(source.startIndex..<source.endIndex, in: source)
        )
        guard !matches.isEmpty else {
            return nil
        }

        var stack: [HTMLBlockOpen] = []

        for match in matches {
            guard let range = Range(match.range, in: source) else {
                continue
            }
            let tagName = group(match, in: source, at: 1).lowercased()
            let literal = String(source[range]).lowercased()
            let isClosing = literal.hasPrefix("</")

            if !isClosing {
                stack.append(HTMLBlockOpen(tag: tagName, range: range, contentStart: range.upperBound))
                continue
            }

            guard let openIndex = stack.lastIndex(where: { $0.tag == tagName }) else {
                continue
            }
            let open = stack[openIndex]
            stack.removeSubrange(openIndex...)

            return HTMLBlock(
                tag: tagName,
                range: open.range.lowerBound..<range.upperBound,
                innerRange: open.contentStart..<range.lowerBound
            )
        }

        return nil
    }

    private func extractAttribute(named name: String, from attributes: String) -> String? {
        let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsRange = NSRange(attributes.startIndex..<attributes.endIndex, in: attributes)
        guard let match = regex.firstMatch(in: attributes, range: nsRange) else {
            return nil
        }
        for index in 1...3 {
            let value = group(match, in: attributes, at: index)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func replaceRepeated(
        pattern: String,
        in source: String,
        transform: (NSTextCheckingResult, String) -> String
    ) -> String {
        var output = source
        for _ in 0..<16 {
            let next = replacePattern(pattern: pattern, in: output, transform: transform)
            if next == output {
                break
            }
            output = next
        }
        return output
    }

    private func replacePattern(
        pattern: String,
        in source: String,
        transform: (NSTextCheckingResult, String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }

        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = regex.matches(in: source, range: nsRange)
        guard !matches.isEmpty else {
            return source
        }

        var output = ""
        var lastIndex = source.startIndex
        for match in matches {
            guard let range = Range(match.range, in: source) else {
                continue
            }
            output += String(source[lastIndex..<range.lowerBound])
            output += transform(match, source)
            lastIndex = range.upperBound
        }
        output += String(source[lastIndex...])
        return output
    }

    private func group(_ match: NSTextCheckingResult, in source: String, at index: Int) -> String {
        guard index < match.numberOfRanges else {
            return ""
        }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: source) else {
            return ""
        }
        return String(source[swiftRange])
    }

    private func stripAllTags(_ source: String) -> String {
        replacePattern(pattern: "(?is)<[^>]+>", in: source) { _, _ in "" }
    }

    private func decodeEntities(_ source: String) -> String {
        var output = source
        let replacements = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
        ]
        for (entity, value) in replacements {
            output = output.replacingOccurrences(of: entity, with: value)
        }

        guard let regex = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);") else {
            return output
        }

        let nsRange = NSRange(output.startIndex..<output.endIndex, in: output)
        let matches = regex.matches(in: output, range: nsRange).reversed()
        for match in matches {
            let value = group(match, in: output, at: 1)
            let scalarValue: UInt32?
            if value.lowercased().hasPrefix("x") {
                scalarValue = UInt32(value.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(value, radix: 10)
            }

            guard let scalarValue, let unicode = UnicodeScalar(scalarValue),
                  let range = Range(match.range, in: output) else {
                continue
            }
            output.replaceSubrange(range, with: String(unicode))
        }
        return output
    }

    private func collapseSpacing(_ source: String) -> String {
        var text = source
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")

        text = replacePattern(pattern: "[ ]+\n", in: text) { _, _ in "\n" }

        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        return text
    }

    private struct HTMLBlock {
        let tag: String
        let range: Range<String.Index>
        let innerRange: Range<String.Index>
    }

    private struct HTMLBlockOpen {
        let tag: String
        let range: Range<String.Index>
        let contentStart: String.Index
    }

    private struct TableCell {
        let text: String
        let isHeader: Bool
    }
}
