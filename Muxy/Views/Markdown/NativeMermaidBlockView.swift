import AppKit
import SwiftUI

#if canImport(BeautifulMermaid)
import BeautifulMermaid

/// Native Mermaid block renderer for the native Markdown preview.
///
/// Renders Mermaid into a fitted native `NSImage` instead of embedding BeautifulMermaid's
/// live `NSView`. This keeps SwiftUI in control of the block's layout and guarantees the
/// diagram is aspect-fit into the markdown column rather than clipped by an intrinsic size.
@available(macOS 14.0, *)
struct NativeMermaidBlockView: View {
    let source: String
    let palette: MarkdownRenderer.Palette
    let refreshVersion: Int

    @State private var parseError: Error?
    @State private var diagramBounds: CGRect = .zero
    @State private var availableWidth: CGFloat = 0
    @State private var renderedImage: NSImage?
    @State private var renderKey: String = ""
    @State private var exportError: String?

    private var theme: DiagramTheme {
        // BeautifulMermaid uses `BMColor` which is `NSColor` on macOS.
        DiagramTheme(
            background: palette.background,
            foreground: palette.foreground,
            accent: palette.accent
        )
    }

    private var layoutConfig: BeautifulMermaid.LayoutConfig {
        BeautifulMermaid.LayoutConfig(padding: 24, nodeSpacing: 28, layerSpacing: 48, componentSpacing: 20)
    }

    private var fittedDiagramHeight: CGFloat {
        let fallback: CGFloat = 240
        guard availableWidth > 0, diagramBounds.width > 0, diagramBounds.height > 0 else { return fallback }
        return max(120, availableWidth * diagramBounds.height / diagramBounds.width)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Mermaid")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: palette.foreground).opacity(0.68))
                Spacer()
                Button {
                    openDiagramInPreview()
                } label: {
                    Label("Open in Preview", systemImage: "arrow.up.right.square")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
                .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ZStack {
                Color(nsColor: palette.background)

                if let renderedImage {
                    Image(nsImage: renderedImage)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .scaledToFit()
                        .scaleEffect(x: 1, y: isERDiagram(source) ? -1 : 1)
                        .frame(width: max(1, availableWidth), height: fittedDiagramHeight)
                } else if parseError == nil {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: max(1, availableWidth), height: fittedDiagramHeight)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        Color(nsColor: blend(foreground: palette.foreground, background: palette.background, amount: 0.2)),
                        lineWidth: 1
                    )
            )

            if let parseError {
                MermaidErrorBlockView(title: "Mermaid error", message: parseError.localizedDescription, palette: palette)
            }

            if let exportError {
                MermaidErrorBlockView(title: "Preview export error", message: exportError, palette: palette)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { updateAvailableWidth(proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, width in updateAvailableWidth(width) }
            }
        )
        .onAppear { renderFittedDiagramIfNeeded() }
        .onChange(of: source) { _, _ in invalidateAndRender() }
        .onChange(of: palette) { _, _ in invalidateAndRender() }
        .onChange(of: refreshVersion) { _, _ in invalidateAndRender() }
        .onChange(of: availableWidth) { _, _ in renderFittedDiagramIfNeeded() }
    }

    private func updateAvailableWidth(_ width: CGFloat) {
        availableWidth = max(0, floor(width))
    }

    private func invalidateAndRender() {
        renderedImage = nil
        diagramBounds = .zero
        parseError = nil
        exportError = nil
        renderKey = ""
        renderFittedDiagramIfNeeded()
    }

    private func renderFittedDiagramIfNeeded() {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            renderedImage = nil
            diagramBounds = .zero
            parseError = nil
            return
        }
        guard availableWidth > 0 else { return }

        let targetWidth = max(1, availableWidth)
        let keyParts = [
            String(trimmedSource.hashValue),
            String(Int(targetWidth)),
            palette.background.hexRenderKey,
            palette.foreground.hexRenderKey,
            palette.accent.hexRenderKey,
        ]
        let key = keyParts.joined(separator: "-")
        guard key != renderKey else { return }

        do {
            let renderer = MermaidImageRenderer(theme: theme, config: layoutConfig)
            guard let prepared = try renderer.prepare(from: source) else {
                renderedImage = nil
                diagramBounds = .zero
                parseError = nil
                renderKey = key
                return
            }

            diagramBounds = prepared.bounds
            let targetHeight = max(120, targetWidth * prepared.bounds.height / prepared.bounds.width)
            renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
            if let fittedImage = try renderer.renderImage(
                from: source,
                size: CGSize(width: targetWidth * renderer.scale, height: targetHeight * renderer.scale)
            ) {
                renderedImage = correctedImage(fittedImage)
            } else {
                renderedImage = nil
            }
            parseError = nil
            renderKey = key
        } catch {
            renderedImage = nil
            diagramBounds = .zero
            parseError = error
            renderKey = key
        }
    }

    private func correctedImage(_ image: NSImage) -> NSImage {
        // BeautifulMermaid's CGContext renderers do not currently agree on the same
        // final image-space orientation for every diagram family. Most renderers need
        // a vertical flip after fitted bitmap rendering, while ER diagrams are already
        // vertically oriented after that path but still need the horizontal correction.
        if isERDiagram(source) {
            return image.horizontallyMirrored().verticallyFlipped()
        }
        return image.verticallyFlipped()
    }

    private func isERDiagram(_ source: String) -> Bool {
        firstMermaidStatement(in: source)?.lowercased().hasPrefix("erdiagram") == true
    }

    private func firstMermaidStatement(in source: String) -> String? {
        source
            .components(separatedBy: .newlines)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("%%") }
    }

    private func openDiagramInPreview() {
        exportError = nil
        do {
            guard let data = try exportPNGData() else {
                exportError = "BeautifulMermaid did not produce PNG data."
                return
            }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MuxyMermaidPreviews", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory
                .appendingPathComponent("mermaid-\(UUID().uuidString)")
                .appendingPathExtension("png")
            try data.write(to: fileURL, options: .atomic)

            openPNGInPreview(fileURL)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func exportPNGData() throws -> Data? {
        let renderer = MermaidImageRenderer(theme: theme, config: layoutConfig)
        renderer.scale = 2.0
        guard let image = try renderer.renderImage(from: source) else { return nil }

        return image.appKitPNGDataWithTopLeftOrientation()
    }

    private func openPNGInPreview(_ fileURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Preview", fileURL.path]
        do {
            try process.run()
            return
        } catch {
            // Fall back to NSWorkspace below and surface an error only if both routes fail.
        }

        if let previewURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([fileURL], withApplicationAt: previewURL, configuration: configuration) { _, error in
                if let error {
                    DispatchQueue.main.async {
                        self.exportError = "Could not open Preview: \(error.localizedDescription). PNG written to \(fileURL.path)."
                    }
                }
            }
            return
        }

        let didOpen = NSWorkspace.shared.open(fileURL)
        if !didOpen {
            exportError = "Could not open the exported diagram. The PNG was written to \(fileURL.path)."
        }
    }
}

@available(macOS 14.0, *)
private struct MermaidErrorBlockView: View {
    let title: String
    let message: String
    let palette: MarkdownRenderer.Palette

    private var errorForeground: NSColor { .systemRed }
    private var errorBackground: NSColor {
        blend(foreground: errorForeground, background: palette.background, amount: 0.12)
    }

    private var errorBorder: NSColor {
        blend(foreground: errorForeground, background: palette.background, amount: 0.35)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: errorForeground))

            Text(message)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Color(nsColor: errorForeground))
                .textSelection(.enabled)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: errorBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: errorBorder), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private func blend(foreground: NSColor, background: NSColor, amount: CGFloat) -> NSColor {
    let fg = (foreground.usingColorSpace(.deviceRGB) ?? foreground)
    let bg = (background.usingColorSpace(.deviceRGB) ?? background)

    let clamped = min(max(amount, 0), 1)

    let r = bg.redComponent + (fg.redComponent - bg.redComponent) * clamped
    let g = bg.greenComponent + (fg.greenComponent - bg.greenComponent) * clamped
    let b = bg.blueComponent + (fg.blueComponent - bg.blueComponent) * clamped
    let a = bg.alphaComponent + (fg.alphaComponent - bg.alphaComponent) * clamped

    return NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    func appKitPNGDataWithTopLeftOrientation() -> Data? {
        let orientedImage = NSImage(size: size)
        orientedImage.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else {
            orientedImage.unlockFocus()
            return nil
        }

        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        draw(in: NSRect(origin: .zero, size: size))
        orientedImage.unlockFocus()

        return orientedImage.pngData()
    }

    func horizontallyMirrored() -> NSImage {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: cgImage.bitsPerComponent,
                  bytesPerRow: 0,
                  space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              )
        else { return self }

        context.translateBy(x: CGFloat(width), y: 0)
        context.scaleBy(x: -1, y: 1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let mirrored = context.makeImage() else { return self }
        return NSImage(cgImage: mirrored, size: size)
    }

    func verticallyFlipped() -> NSImage {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: cgImage.bitsPerComponent,
                  bytesPerRow: 0,
                  space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              )
        else { return self }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flipped = context.makeImage() else { return self }
        return NSImage(cgImage: flipped, size: size)
    }
}

private extension NSColor {
    var hexRenderKey: String {
        let color = usingColorSpace(.deviceRGB) ?? self
        return "\(color.redComponent)-\(color.greenComponent)-\(color.blueComponent)-\(color.alphaComponent)"
    }
}

#endif
