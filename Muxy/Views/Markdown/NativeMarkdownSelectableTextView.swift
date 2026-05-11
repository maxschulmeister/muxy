import AppKit
import SwiftUI

private extension NSAttributedString.Key {
    static let nativeMarkdownCodeBlock = NSAttributedString.Key("muxy.nativeMarkdown.codeBlock")
    static let nativeMarkdownInlineCode = NSAttributedString.Key("muxy.nativeMarkdown.inlineCode")
}

enum NativeMarkdownSelectableTextRenderer {
    private struct ParsedListLine {
        let level: Int
        let marker: String
        let content: String
    }

    private struct FenceStart {
        let marker: Character
        let count: Int
    }

    static func attributedMarkdown(from markdown: String, baseURL: URL?, palette: MarkdownRenderer.Palette) -> NSAttributedString? {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }

        let result = NSMutableAttributedString()
        let bodyFont = Self.bodyFont(for: palette)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                appendSoftBreak(to: result, font: bodyFont, palette: palette)
                index += 1
                continue
            }

            if let fence = parseFenceStart(trimmed) {
                let startIndex = index
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index]
                    if isFenceClose(candidate.trimmingCharacters(in: .whitespaces), for: fence) {
                        index += 1
                        break
                    }
                    codeLines.append(candidate)
                    index += 1
                }
                if index >= lines.count, codeLines.isEmpty {
                    codeLines = Array(lines[(startIndex + 1)...])
                }
                appendCodeBlock(codeLines.joined(separator: "\n"), to: result, palette: palette, bodyFont: bodyFont)
                continue
            }

            if let heading = parseHeading(trimmed) {
                appendHeading(level: heading.level, markdown: heading.text, to: result, baseURL: baseURL, palette: palette)
                index += 1
                continue
            }

            if isThematicBreak(trimmed) {
                appendThematicBreak(to: result, palette: palette, bodyFont: bodyFont)
                index += 1
                continue
            }

            if let listLine = parseListLine(line) {
                appendListLine(listLine, to: result, baseURL: baseURL, palette: palette, bodyFont: bodyFont)
                index += 1
                continue
            }

            if isBlockquote(trimmed) {
                var quoteLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard isBlockquote(candidate) else { break }
                    quoteLines.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                appendBlockquote(quoteLines.joined(separator: "\n"), to: result, baseURL: baseURL, palette: palette, bodyFont: bodyFont)
                continue
            }

            var paragraphLines: [String] = []
            while index < lines.count {
                let candidate = lines[index]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidateTrimmed.isEmpty, !startsNewBlock(candidateTrimmed, rawLine: candidate) else { break }
                paragraphLines.append(candidateTrimmed)
                index += 1
            }
            appendParagraph(paragraphLines.joined(separator: " "), to: result, baseURL: baseURL, palette: palette, bodyFont: bodyFont)
        }

        trimTrailingNewlines(from: result)
        return result.length > 0 ? result : nil
    }

    private static func appendHeading(
        level: Int,
        markdown: String,
        to result: NSMutableAttributedString,
        baseURL: URL?,
        palette: MarkdownRenderer.Palette
    ) {
        let size: CGFloat = switch level {
        case 1: 32
        case 2: 24
        case 3: 20
        case 4: 17
        case 5: 15
        default: 14
        }
        let font = palette.fontFamilyName.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold)
        let paragraphStyle = blockParagraphStyle(spacingBefore: result.length == 0 ? 0 : 12, spacingAfter: level <= 2 ? 10 : 8)
        let attributed = attributedInlineMarkdown(markdown, baseURL: baseURL, palette: palette, bodyFont: font)
        let range = NSRange(location: 0, length: attributed.length)
        attributed.addAttributes([
            .font: font,
            .foregroundColor: palette.foreground,
            .paragraphStyle: paragraphStyle,
        ], range: range)
        result.append(attributed)
        result.append(NSAttributedString(string: "\n", attributes: [
            .font: font,
            .foregroundColor: palette.foreground,
            .paragraphStyle: paragraphStyle,
        ]))
    }

    private static func appendParagraph(
        _ markdown: String,
        to result: NSMutableAttributedString,
        baseURL: URL?,
        palette: MarkdownRenderer.Palette,
        bodyFont: NSFont
    ) {
        guard !markdown.isEmpty else { return }
        let paragraphStyle = blockParagraphStyle(spacingBefore: 0, spacingAfter: 8)
        let attributed = attributedInlineMarkdown(markdown, baseURL: baseURL, palette: palette, bodyFont: bodyFont)
        attributed.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: attributed.length))
        result.append(attributed)
        result.append(NSAttributedString(string: "\n", attributes: [
            .font: bodyFont,
            .foregroundColor: palette.foreground,
            .paragraphStyle: paragraphStyle,
        ]))
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

    private static func appendBlockquote(
        _ markdown: String,
        to result: NSMutableAttributedString,
        baseURL: URL?,
        palette: MarkdownRenderer.Palette,
        bodyFont: NSFont
    ) {
        guard !markdown.isEmpty else { return }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.firstLineHeadIndent = 16
        paragraphStyle.headIndent = 16
        paragraphStyle.paragraphSpacing = 8
        paragraphStyle.lineSpacing = 2
        let attributed = attributedInlineMarkdown(markdown, baseURL: baseURL, palette: palette, bodyFont: bodyFont)
        attributed.addAttributes([
            .foregroundColor: palette.foreground.withAlphaComponent(0.78),
            .paragraphStyle: paragraphStyle,
        ], range: NSRange(location: 0, length: attributed.length))
        result.append(attributed)
        result.append(NSAttributedString(string: "\n", attributes: [
            .font: bodyFont,
            .foregroundColor: palette.foreground.withAlphaComponent(0.78),
            .paragraphStyle: paragraphStyle,
        ]))
    }

    private static func appendCodeBlock(
        _ code: String,
        to result: NSMutableAttributedString,
        palette: MarkdownRenderer.Palette,
        bodyFont: NSFont
    ) {
        let paragraphStyle = blockParagraphStyle(spacingBefore: 8, spacingAfter: 12)
        paragraphStyle.firstLineHeadIndent = 14
        paragraphStyle.headIndent = 14
        paragraphStyle.tailIndent = -14
        paragraphStyle.lineSpacing = 1
        let codeFont = NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize * 0.92, weight: .regular)
        let text = code.hasSuffix("\n") ? code : code + "\n"
        result.append(NSAttributedString(string: text, attributes: [
            .font: codeFont,
            .foregroundColor: palette.foreground,
            .nativeMarkdownCodeBlock: true,
            .paragraphStyle: paragraphStyle,
        ]))
    }

    private static func appendThematicBreak(to result: NSMutableAttributedString, palette: MarkdownRenderer.Palette, bodyFont: NSFont) {
        let paragraphStyle = blockParagraphStyle(spacingBefore: 8, spacingAfter: 12)
        result.append(NSAttributedString(string: "────────────\n", attributes: [
            .font: bodyFont,
            .foregroundColor: palette.borderColor,
            .paragraphStyle: paragraphStyle,
        ]))
    }

    private static func appendSoftBreak(to result: NSMutableAttributedString, font: NSFont, palette: MarkdownRenderer.Palette) {
        guard result.length > 0, !result.string.hasSuffix("\n\n") else { return }
        result.append(NSAttributedString(string: "\n", attributes: [
            .font: font,
            .foregroundColor: palette.foreground,
        ]))
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
            guard let intent = inlinePresentationIntent(from: value) else { return }
            var font = bodyFont
            if intent.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            if intent.contains(.code) {
                font = NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize * 0.92, weight: .regular)
                attributed.addAttribute(.nativeMarkdownInlineCode, value: true, range: range)
            }
            if intent.contains(.strikethrough) {
                attributed.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            attributed.addAttribute(.font, value: font, range: range)
        }

        attributed.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            attributed.addAttributes(linkAttributes(for: palette, underlined: false), range: range)
        }

        return attributed
    }

    private static func inlinePresentationIntent(from value: Any?) -> InlinePresentationIntent? {
        if let intent = value as? InlinePresentationIntent {
            return intent
        }
        if let number = value as? NSNumber {
            return InlinePresentationIntent(rawValue: number.uintValue)
        }
        return nil
    }

    private static func parseHeading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1 ... 6).contains(hashes), trimmed.count > hashes else { return nil }
        let markerEnd = trimmed.index(trimmed.startIndex, offsetBy: hashes)
        guard trimmed[markerEnd].isWhitespace else { return nil }
        return (hashes, String(trimmed[markerEnd...]).trimmingCharacters(in: .whitespaces))
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

    private static func parseFenceStart(_ trimmed: String) -> FenceStart? {
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let count = trimmed.prefix { $0 == marker }.count
        guard count >= 3 else { return nil }
        return FenceStart(marker: marker, count: count)
    }

    private static func isFenceClose(_ trimmed: String, for fence: FenceStart) -> Bool {
        let count = trimmed.prefix { $0 == fence.marker }.count
        return count >= fence.count && trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func startsNewBlock(_ trimmed: String, rawLine: String) -> Bool {
        parseHeading(trimmed) != nil
            || parseFenceStart(trimmed) != nil
            || parseListLine(rawLine) != nil
            || isBlockquote(trimmed)
            || isThematicBreak(trimmed)
    }

    private static func isBlockquote(_ trimmed: String) -> Bool {
        trimmed.hasPrefix(">")
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
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

    private static func bodyFont(for palette: MarkdownRenderer.Palette) -> NSFont {
        let fontSize = max(10, 14 * palette.fontScale)
        return palette.fontFamilyName.flatMap { NSFont(name: $0, size: fontSize) }
            ?? NSFont.systemFont(ofSize: fontSize)
    }

    private static func blockParagraphStyle(spacingBefore: CGFloat, spacingAfter: CGFloat) -> NSMutableParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacingBefore = spacingBefore
        paragraphStyle.paragraphSpacing = spacingAfter
        paragraphStyle.lineSpacing = 2
        return paragraphStyle
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
        paragraphStyle.paragraphSpacing = 4
        return paragraphStyle
    }

    static func linkAttributes(for palette: MarkdownRenderer.Palette, underlined: Bool) -> [NSAttributedString.Key: Any] {
        [
            .foregroundColor: palette.accent,
            .underlineStyle: underlined ? NSUnderlineStyle.single.rawValue : 0,
        ]
    }

    private static func trimTrailingNewlines(from attributedString: NSMutableAttributedString) {
        while attributedString.length > 0, attributedString.string.hasSuffix("\n") {
            attributedString.deleteCharacters(in: NSRange(location: attributedString.length - 1, length: 1))
        }
    }
}

struct NativeMarkdownSelectableTextBlockView: NSViewRepresentable {
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
        applyLinkAttributes(to: textView)
        textView.textStorage?.setAttributedString(attributedString)
        textView.refreshLinkCursorRects()
        return textView
    }

    func updateNSView(_ textView: NativeMarkdownSelectableTextView, context: Context) {
        context.coordinator.openURL = openURL
        applyLinkAttributes(to: textView)
        if textView.attributedString() != attributedString {
            textView.textStorage?.setAttributedString(attributedString)
            textView.refreshLinkCursorRects()
        }
        textView.invalidateIntrinsicContentSize()
    }

    static func dismantleNSView(_ nsView: NativeMarkdownSelectableTextView, coordinator _: Coordinator) {
        nsView.delegate = nil
    }

    private func applyLinkAttributes(to textView: NativeMarkdownSelectableTextView) {
        let base = NativeMarkdownSelectableTextRenderer.linkAttributes(for: palette, underlined: false)
        let hover = NativeMarkdownSelectableTextRenderer.linkAttributes(for: palette, underlined: true)
        textView.linkTextAttributes = base
        textView.baseLinkAttributes = base
        textView.hoverLinkAttributes = hover
        textView.nativeMarkdownCodeBackgroundColor = palette.codeBackgroundColor
        textView.nativeMarkdownCodeBorderColor = palette.borderColor
        textView.needsDisplay = true
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
    var baseLinkAttributes: [NSAttributedString.Key: Any] = [:]
    var hoverLinkAttributes: [NSAttributedString.Key: Any] = [:]
    var nativeMarkdownCodeBackgroundColor: NSColor = .textBackgroundColor
    var nativeMarkdownCodeBorderColor: NSColor = .separatorColor
    private var hoverTrackingArea: NSTrackingArea?
    private var hoveredLinkRange: NSRange?

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawNativeMarkdownCodeBackgrounds(in: dirtyRect)
        super.draw(dirtyRect)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHoveredLink(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHoveredLink()
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let characterIndex = characterIndex(at: point), linkRange(at: characterIndex) != nil {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addLinkCursorRects()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.containerSize = NSSize(width: max(0, newSize.width), height: .greatestFiniteMagnitude)
        invalidateIntrinsicContentSize()
        refreshLinkCursorRects()
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
        refreshLinkCursorRects()
    }

    func refreshLinkCursorRects() {
        guard let window else { return }
        window.invalidateCursorRects(for: self)
    }

    private func updateHoveredLink(at point: NSPoint) {
        let linkRange: NSRange? = if let characterIndex = characterIndex(at: point) {
            self.linkRange(at: characterIndex)
        } else {
            nil
        }

        guard linkRange != hoveredLinkRange else {
            if linkRange != nil { NSCursor.pointingHand.set() }
            return
        }

        clearHoveredLink()
        if let linkRange {
            textStorage?.addAttributes(hoverLinkAttributes, range: linkRange)
            hoveredLinkRange = linkRange
            NSCursor.pointingHand.set()
        }
    }

    private func clearHoveredLink() {
        guard let hoveredLinkRange else { return }
        if let textStorage, NSMaxRange(hoveredLinkRange) <= textStorage.length {
            textStorage.addAttributes(baseLinkAttributes, range: hoveredLinkRange)
        }
        self.hoveredLinkRange = nil
    }

    private func drawNativeMarkdownCodeBackgrounds(in dirtyRect: NSRect) {
        drawCodeBlockBackgrounds(in: dirtyRect)
        drawInlineCodeBackgrounds(in: dirtyRect)
    }

    private func drawCodeBlockBackgrounds(in dirtyRect: NSRect) {
        enumerateRanges(with: .nativeMarkdownCodeBlock) { range in
            guard let rect = blockBackgroundRect(for: range), rect.intersects(dirtyRect) else { return }

            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            nativeMarkdownCodeBackgroundColor.setFill()
            path.fill()

            nativeMarkdownCodeBorderColor.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawInlineCodeBackgrounds(in dirtyRect: NSRect) {
        enumerateRanges(with: .nativeMarkdownInlineCode) { range in
            for rect in inlineBackgroundRects(for: range) where rect.intersects(dirtyRect) {
                let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                nativeMarkdownCodeBackgroundColor.setFill()
                path.fill()
            }
        }
    }

    private func enumerateRanges(with attribute: NSAttributedString.Key, handler: (NSRange) -> Void) {
        guard let textStorage, textStorage.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(attribute, in: fullRange) { value, range, _ in
            guard value != nil, range.length > 0 else { return }
            handler(range)
        }
    }

    private func blockBackgroundRect(for characterRange: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }

        layoutManager.ensureLayout(for: textContainer)
        var unionRect: NSRect?
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, _, _ in
            unionRect = unionRect.map { $0.union(lineRect) } ?? lineRect
        }

        guard var rect = unionRect else { return nil }
        let origin = textContainerOrigin
        rect.origin.x = bounds.minX + 0.5
        rect.origin.y += origin.y - 6
        rect.size.width = max(0, bounds.width - 1)
        rect.size.height += 12
        return rect.integral
    }

    private func inlineBackgroundRects(for characterRange: NSRange) -> [NSRect] {
        guard let layoutManager, let textContainer else { return [] }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return [] }

        layoutManager.ensureLayout(for: textContainer)
        let origin = textContainerOrigin
        var rects: [NSRect] = []
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer
        ) { rect, _ in
            rects.append(
                rect
                    .offsetBy(dx: origin.x, dy: origin.y)
                    .insetBy(dx: -4, dy: -1.5)
                    .integral
            )
        }
        return rects
    }

    private func addLinkCursorRects() {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else { return }
        layoutManager.ensureLayout(for: textContainer)
        let textOrigin = textContainerOrigin
        let fullRange = NSRange(location: 0, length: textStorage.length)

        textStorage.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil, range.length > 0 else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }

            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { rect, _ in
                let cursorRect = rect
                    .offsetBy(dx: textOrigin.x, dy: textOrigin.y)
                    .insetBy(dx: -1, dy: -1)
                self.addCursorRect(cursorRect, cursor: .pointingHand)
            }
        }
    }

    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let textStorage else { return nil }
        var containerPoint = point
        containerPoint.x -= textContainerOrigin.x
        containerPoint.y -= textContainerOrigin.y
        guard containerPoint.x >= 0, containerPoint.y >= 0 else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        guard index >= 0, index < textStorage.length else { return nil }
        return index
    }

    private func linkRange(at index: Int) -> NSRange? {
        guard let textStorage, index >= 0, index < textStorage.length else { return nil }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        var effectiveRange = NSRange(location: NSNotFound, length: 0)
        let link = textStorage.attribute(.link, at: index, longestEffectiveRange: &effectiveRange, in: fullRange)
        guard link != nil, effectiveRange.location != NSNotFound, effectiveRange.length > 0 else { return nil }
        return effectiveRange
    }
}
