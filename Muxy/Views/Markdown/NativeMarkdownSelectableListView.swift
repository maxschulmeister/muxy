import AppKit
import SwiftUI

enum NativeMarkdownSelectableListRenderer {
    private struct ParsedListLine {
        let level: Int
        let marker: String
        let content: String
    }

    static func attributedList(from markdown: String, baseURL: URL?, palette: MarkdownRenderer.Palette) -> NSAttributedString? {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }

        let result = NSMutableAttributedString()
        let fontSize = max(10, 14 * palette.fontScale)
        let bodyFont = palette.fontFamilyName.flatMap { NSFont(name: $0, size: fontSize) }
            ?? NSFont.systemFont(ofSize: fontSize)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: palette.foreground,
        ]

        var sawListItem = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                guard sawListItem else { continue }
                result.append(NSAttributedString(string: "\n", attributes: baseAttributes))
                continue
            }

            if let listLine = parseListLine(line) {
                sawListItem = true
                appendListLine(listLine, to: result, baseURL: baseURL, palette: palette, bodyFont: bodyFont)
                continue
            }

            guard sawListItem, indentationColumns(in: line) >= 2 else { return nil }
            appendContinuationLine(line, to: result, baseURL: baseURL, palette: palette, bodyFont: bodyFont)
        }

        guard sawListItem, result.length > 0 else { return nil }
        if result.string.hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        return result
    }

    private static func appendListLine(
        _ line: ParsedListLine,
        to result: NSMutableAttributedString,
        baseURL: URL?,
        palette: MarkdownRenderer.Palette,
        bodyFont: NSFont
    ) {
        let paragraphStyle = listParagraphStyle(level: line.level)
        let markerAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: palette.foreground,
            .paragraphStyle: paragraphStyle,
        ]
        result.append(NSAttributedString(string: "\(line.marker)\t", attributes: markerAttributes))

        let content = attributedInlineMarkdown(line.content, baseURL: baseURL, palette: palette, bodyFont: bodyFont)
        content.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: content.length))
        result.append(content)
        result.append(NSAttributedString(string: "\n", attributes: markerAttributes))
    }

    private static func appendContinuationLine(
        _ line: String,
        to result: NSMutableAttributedString,
        baseURL: URL?,
        palette: MarkdownRenderer.Palette,
        bodyFont: NSFont
    ) {
        let level = max(0, indentationColumns(in: line) / 2)
        let paragraphStyle = continuationParagraphStyle(level: level)
        let content = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let attributed = attributedInlineMarkdown(content, baseURL: baseURL, palette: palette, bodyFont: bodyFont)
        attributed.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: attributed.length))
        result.append(attributed)
        result.append(NSAttributedString(string: "\n", attributes: [
            .font: bodyFont,
            .foregroundColor: palette.foreground,
            .paragraphStyle: paragraphStyle,
        ]))
    }

    private static func parseListLine(_ line: String) -> ParsedListLine? {
        let indent = indentation(in: line)
        let level = max(0, indent.columns / 2)
        let text = line[indent.index...]
        guard !text.isEmpty else { return nil }

        if let first = text.first, first == "-" || first == "*" || first == "+" {
            let afterMarker = text.index(after: text.startIndex)
            guard afterMarker < text.endIndex, text[afterMarker].isWhitespace else { return nil }
            let content = String(text[skipWhitespace(in: text, from: afterMarker)...])
            if let task = parseTaskMarker(in: content) {
                return ParsedListLine(level: level, marker: task.isCompleted ? "☑" : "☐", content: task.content)
            }
            return ParsedListLine(level: level, marker: "•", content: content)
        }

        var digitEnd = text.startIndex
        while digitEnd < text.endIndex, text[digitEnd].isNumber {
            digitEnd = text.index(after: digitEnd)
        }
        guard digitEnd > text.startIndex, digitEnd < text.endIndex else { return nil }
        let markerCharacter = text[digitEnd]
        guard markerCharacter == "." || markerCharacter == ")" else { return nil }
        let afterMarker = text.index(after: digitEnd)
        guard afterMarker < text.endIndex, text[afterMarker].isWhitespace else { return nil }
        let marker = String(text[text.startIndex ... digitEnd])
        let content = String(text[skipWhitespace(in: text, from: afterMarker)...])
        return ParsedListLine(level: level, marker: marker, content: content)
    }

    private static func attributedInlineMarkdown(
        _ markdown: String,
        baseURL: URL?,
        palette: MarkdownRenderer.Palette,
        bodyFont: NSFont
    ) -> NSMutableAttributedString {
        let attributed: NSMutableAttributedString
        do {
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            let parsed = try AttributedString(markdown: markdown, options: options, baseURL: baseURL)
            attributed = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        } catch {
            attributed = NSMutableAttributedString(string: markdown)
        }

        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0 else { return attributed }
        attributed.addAttributes([
            .font: bodyFont,
            .foregroundColor: palette.foreground,
        ], range: fullRange)

        attributed.enumerateAttribute(.inlinePresentationIntent, in: fullRange) { value, range, _ in
            guard let intent = value as? InlinePresentationIntent else { return }
            var font = bodyFont
            if intent.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            if intent.contains(.code) {
                font = NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize * 0.92, weight: .regular)
                attributed.addAttribute(.backgroundColor, value: palette.codeBackgroundColor, range: range)
            }
            if intent.contains(.strikethrough) {
                attributed.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            attributed.addAttribute(.font, value: font, range: range)
        }

        attributed.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            attributed.addAttributes([
                .foregroundColor: palette.accent,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: range)
        }

        return attributed
    }

    private static func listParagraphStyle(level: Int) -> NSParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        let baseIndent = CGFloat(level) * 22
        let contentIndent = baseIndent + 24
        paragraphStyle.firstLineHeadIndent = baseIndent
        paragraphStyle.headIndent = contentIndent
        paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: contentIndent)]
        paragraphStyle.defaultTabInterval = 24
        paragraphStyle.lineSpacing = 2
        paragraphStyle.paragraphSpacing = 5
        return paragraphStyle
    }

    private static func continuationParagraphStyle(level: Int) -> NSParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        let indent = CGFloat(level) * 22 + 24
        paragraphStyle.firstLineHeadIndent = indent
        paragraphStyle.headIndent = indent
        paragraphStyle.lineSpacing = 2
        paragraphStyle.paragraphSpacing = 5
        return paragraphStyle
    }

    private static func parseTaskMarker(in content: String) -> (isCompleted: Bool, content: String)? {
        let lowered = content.lowercased()
        if lowered.hasPrefix("[ ] ") {
            return (false, String(content.dropFirst(4)))
        }
        if lowered.hasPrefix("[x] ") {
            return (true, String(content.dropFirst(4)))
        }
        return nil
    }

    private static func indentationColumns(in line: String) -> Int {
        indentation(in: line).columns
    }

    private static func indentation(in line: String) -> (columns: Int, index: String.Index) {
        var columns = 0
        var index = line.startIndex
        while index < line.endIndex {
            switch line[index] {
            case " ":
                columns += 1
                index = line.index(after: index)
            case "\t":
                columns += 4
                index = line.index(after: index)
            default:
                return (columns, index)
            }
        }
        return (columns, index)
    }

    private static func skipWhitespace(in text: Substring, from start: Substring.Index) -> Substring.Index {
        var index = start
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        return index
    }
}

struct NativeMarkdownSelectableListView: NSViewRepresentable {
    let attributedString: NSAttributedString
    let palette: MarkdownRenderer.Palette
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator {
        Coordinator(openURL: openURL)
    }

    func makeNSView(context: Context) -> NativeMarkdownSelectableTextView {
        let textView = NativeMarkdownSelectableTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.linkTextAttributes = linkAttributes
        textView.textStorage?.setAttributedString(attributedString)
        return textView
    }

    func updateNSView(_ textView: NativeMarkdownSelectableTextView, context: Context) {
        context.coordinator.openURL = openURL
        textView.linkTextAttributes = linkAttributes
        if textView.attributedString() != attributedString {
            textView.textStorage?.setAttributedString(attributedString)
        }
        textView.invalidateIntrinsicContentSize()
    }

    static func dismantleNSView(_ nsView: NativeMarkdownSelectableTextView, coordinator _: Coordinator) {
        nsView.delegate = nil
    }

    private var linkAttributes: [NSAttributedString.Key: Any] {
        [
            .foregroundColor: palette.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: OpenURLAction

        init(openURL: OpenURLAction) {
            self.openURL = openURL
        }

        func textView(_: NSTextView, clickedOnLink link: Any, at _: Int) -> Bool {
            if let url = link as? URL {
                openURL(url)
                return true
            }
            if let string = link as? String, let url = URL(string: string) {
                openURL(url)
                return true
            }
            return false
        }
    }
}

final class NativeMarkdownSelectableTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 0)
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: ceil(usedRect.height + textContainerInset.height * 2)
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.containerSize = NSSize(width: max(0, newSize.width), height: .greatestFiniteMagnitude)
        invalidateIntrinsicContentSize()
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }
}
