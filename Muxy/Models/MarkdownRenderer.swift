import AppKit

enum MarkdownRenderer {
    struct Palette: Equatable {
        let background: NSColor
        let foreground: NSColor
        let accent: NSColor
        let fontFamilyName: String?
        let fontScale: CGFloat
    }
}
