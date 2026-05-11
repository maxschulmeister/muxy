import AppKit
import Testing

@testable import Muxy

@Suite("NativeMarkdownSelectableTextRenderer")
struct NativeMarkdownSelectableTextRendererTests {
    private let palette = MarkdownRenderer.Palette(
        background: .white,
        foreground: .black,
        accent: .systemBlue,
        fontFamilyName: nil,
        fontScale: 1
    )

    @Test("inline code is styled as monospaced with a custom background marker")
    func inlineCodeStyling() throws {
        let attributed = try #require(NativeMarkdownSelectableTextRenderer.attributedMarkdown(
            from: "Use `let value = 1` here.",
            baseURL: nil,
            palette: palette
        ))

        let codeRange = (attributed.string as NSString).range(of: "let value = 1")
        #expect(codeRange.location != NSNotFound)
        #expect(attributed.attribute(NSAttributedString.Key("muxy.nativeMarkdown.inlineCode"), at: codeRange.location, effectiveRange: nil) != nil)

        let font = try #require(attributed.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont)
        #expect(font.isFixedPitch)
    }

    @Test("fenced code blocks are monospaced and tagged for full block background drawing")
    func fencedCodeBlockStyling() throws {
        let attributed = try #require(NativeMarkdownSelectableTextRenderer.attributedMarkdown(
            from: """
            Before

            ```swift
            let value = 1
            print(value)
            ```

            After
            """,
            baseURL: nil,
            palette: palette
        ))

        let codeRange = (attributed.string as NSString).range(of: "let value = 1")
        #expect(codeRange.location != NSNotFound)
        #expect(attributed.attribute(NSAttributedString.Key("muxy.nativeMarkdown.codeBlock"), at: codeRange.location, effectiveRange: nil) != nil)

        let font = try #require(attributed.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont)
        #expect(font.isFixedPitch)
    }
}
