import AppKit
import SwiftUI

struct NativeMarkdownPreviewView: View {
    let content: String
    let filePath: String?
    let projectPath: String?
    let palette: MarkdownRenderer.Palette
    let refreshVersion: Int
    @Binding var syncScrollRequest: CGFloat?
    let syncScrollRequestVersion: Int
    var fragmentTarget: String?
    var fragmentRequestVersion: Int = 0
    var scrollSyncEnabled = true
    var onScrollReport: ((MarkdownPreviewScrollReport) -> Void)?
    var onLayoutChanged: (() -> Void)?
    var onAnchorGeometryChanged: (([MarkdownPreviewAnchorGeometry]) -> Void)?
    var onOpenInternalLink: ((String, String?) -> Void)?
    var onReloadFromDisk: (() -> Void)?

    @State private var lastAppliedSyncRequestVersion: Int = -1
    @State private var lastAppliedSyncScrollTop: CGFloat?
    @State private var lastReportedMetrics: MarkdownPreviewScrollReport?
    @State private var currentScrollTop: CGFloat = 0
    @State private var lastReportedAnchorGeometries: [MarkdownPreviewAnchorGeometry] = []
    @State private var lastReportedAnchorGeometryContentHeight: CGFloat = 0
    @State private var latestScrollMetrics: NativeMarkdownScrollMetricsPreferenceKey.Value = NativeMarkdownScrollMetricsPreferenceKey
        .defaultValue
    @State private var scrollView: NSScrollView?
    @State private var programmaticScrollSuppressionUntil: Date?
    @State private var lastAppliedFragmentRequestVersion: Int = -1

    private static let programmaticScrollSuppressionWindow: TimeInterval = 0.2

    private var baseURL: URL? {
        guard let filePath else { return nil }
        return URL(fileURLWithPath: filePath).deletingLastPathComponent()
    }

    var body: some View {
        let renderUnits = NativeMarkdownRenderUnitBuilder.build(content: content)

        GeometryReader { viewportProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(renderUnits) { unit in
                        Group {
                            switch unit.block {
                            case let .markdown(markdown):
                                NativeMarkdownCompatibleMarkdownView(
                                    markdown: markdown,
                                    baseURL: baseURL,
                                    palette: palette
                                )
                            case let .mermaid(source):
                                NativeMermaidBlockView(source: source, palette: palette, refreshVersion: refreshVersion)
                            }
                        }
                        .id("\(unit.id)-\(refreshVersion)")
                        .nativeMarkdownAnchorGeometry(
                            anchorID: unit.anchor.id,
                            startLine: unit.anchor.startLine,
                            endLine: unit.anchor.endLine
                        )
                    }
                }
                .frame(maxWidth: 900, alignment: .topLeading)
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, max(160, viewportProxy.size.height * 0.35))
                .frame(maxWidth: .infinity, alignment: .top)
                .background(
                    ZStack {
                        GeometryReader { contentProxy in
                            Color.clear.preference(
                                key: NativeMarkdownScrollMetricsPreferenceKey.self,
                                value: NativeMarkdownScrollMetricsPreferenceKey.Value(
                                    contentMinY: contentProxy.frame(
                                        in: .named(NativeMarkdownScrollMetricsPreferenceKey.coordinateSpaceName)
                                    ).minY,
                                    contentHeight: contentProxy.size.height,
                                    viewportHeight: viewportProxy.size.height
                                )
                            )
                        }
                        EnclosingNSScrollViewReader(
                            onResolve: { resolvedScrollView in
                                scrollView = resolvedScrollView
                                NativeMarkdownCursorCoordinator.shared.attach(resolvedScrollView)
                                handleScrollViewDidScroll(resolvedScrollView)
                                applyPreferredScrollIfNeeded()
                            },
                            onScroll: { resolvedScrollView in
                                handleScrollViewDidScroll(resolvedScrollView)
                            }
                        )
                        .frame(width: 0, height: 0)
                    }
                    .allowsHitTesting(false)
                )
            }
            .coordinateSpace(name: NativeMarkdownScrollMetricsPreferenceKey.coordinateSpaceName)
            .environment(\.openURL, OpenURLAction { url in
                switch MarkdownLinkResolver.resolve(
                    href: url.absoluteString,
                    currentFilePath: filePath,
                    projectPath: projectPath
                ) {
                case let .external(url):
                    NSWorkspace.shared.open(url)
                    return .handled
                case let .internalFile(path, fragment):
                    onOpenInternalLink?(path, fragment)
                    return .handled
                case let .sameDocumentFragment(fragment):
                    scrollToFragment(fragment, renderUnits: renderUnits)
                    return .handled
                case .unsupported:
                    return .systemAction
                }
            })
        }
        .background(Color(nsColor: palette.background))
        .onAppear {
            onLayoutChanged?()
            onAnchorGeometryChanged?([])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let scrollView {
                    handleScrollViewDidScroll(scrollView)
                    applyPreferredScrollIfNeeded()
                    applyFragmentScrollIfNeeded(renderUnits: renderUnits)
                }
            }
        }
        .onDisappear {
            if let scrollView {
                NativeMarkdownCursorCoordinator.shared.detach(scrollView)
            }
        }
        .onPreferenceChange(NativeMarkdownScrollMetricsPreferenceKey.self) { value in
            latestScrollMetrics = value
            let scrollTop = max(0, -value.contentMinY)
            currentScrollTop = scrollTop

            guard scrollSyncEnabled else { return }

            applyPreferredScrollIfNeeded()

            if let until = programmaticScrollSuppressionUntil, Date() < until {
                return
            }

            let report = MarkdownPreviewScrollReport(
                scrollTop: scrollTop,
                scrollHeight: max(0, value.contentHeight),
                clientHeight: max(0, value.viewportHeight)
            )

            if let last = lastReportedMetrics {
                let sameTop = abs(last.scrollTop - report.scrollTop) <= 0.5
                let sameHeights = abs(last.scrollHeight - report.scrollHeight) <= 0.5
                    && abs(last.clientHeight - report.clientHeight) <= 0.5
                if sameTop, sameHeights {
                    return
                }
            }

            lastReportedMetrics = report
            onScrollReport?(report)
        }
        .onPreferenceChange(NativeMarkdownAnchorFramesPreferenceKey.self) { frames in
            let geometries: [MarkdownPreviewAnchorGeometry] = frames
                .compactMap { frame in
                    guard let anchorID = frame.anchorID else { return nil }
                    let top = frame.minY + currentScrollTop
                    return MarkdownPreviewAnchorGeometry(
                        anchorID: anchorID,
                        startLine: frame.startLine,
                        endLine: frame.endLine,
                        top: top,
                        height: frame.height
                    )
                }
                .sorted {
                    let delta = $0.top - $1.top
                    if abs(delta) > 0.5 { return delta < 0 }
                    return $0.anchorID < $1.anchorID
                }

            let contentHeight = latestScrollMetrics.contentHeight
            guard shouldReportAnchorGeometries(geometries, contentHeight: contentHeight) else {
                lastReportedAnchorGeometryContentHeight = contentHeight
                return
            }
            lastReportedAnchorGeometries = geometries
            lastReportedAnchorGeometryContentHeight = contentHeight
            onAnchorGeometryChanged?(geometries)
            onLayoutChanged?()
            applyFragmentScrollIfNeeded(renderUnits: renderUnits)
        }
        .onChange(of: syncScrollRequestVersion) { _, _ in
            applyPreferredScrollIfNeeded()
        }
        .onChange(of: syncScrollRequest) { _, _ in
            applyPreferredScrollIfNeeded()
        }
        .onChange(of: fragmentRequestVersion) { _, _ in
            applyFragmentScrollIfNeeded(renderUnits: renderUnits)
        }
        .onChange(of: fragmentTarget) { _, _ in
            applyFragmentScrollIfNeeded(renderUnits: renderUnits)
        }
    }

    private func handleScrollViewDidScroll(_ scrollView: NSScrollView) {
        NativeMarkdownCursorCoordinator.shared.scheduleUpdateAfterScroll(for: scrollView)

        let report = makeScrollReport(from: scrollView)
        latestScrollMetrics = NativeMarkdownScrollMetricsPreferenceKey.Value(
            contentMinY: -report.scrollTop,
            contentHeight: report.scrollHeight,
            viewportHeight: report.clientHeight
        )
        currentScrollTop = report.scrollTop

        guard scrollSyncEnabled else { return }
        if let until = programmaticScrollSuppressionUntil, Date() < until { return }
        reportScrollIfChanged(report)
    }

    private func reportScrollIfChanged(_ report: MarkdownPreviewScrollReport) {
        if let last = lastReportedMetrics {
            let sameTop = abs(last.scrollTop - report.scrollTop) <= 0.5
            let sameHeights = abs(last.scrollHeight - report.scrollHeight) <= 0.5
                && abs(last.clientHeight - report.clientHeight) <= 0.5
            if sameTop, sameHeights {
                return
            }
        }

        lastReportedMetrics = report
        onScrollReport?(report)
    }

    private func makeScrollReport(from scrollView: NSScrollView) -> MarkdownPreviewScrollReport {
        let clipView = scrollView.contentView
        let documentHeight = max(
            scrollView.documentView?.bounds.height ?? 0,
            latestScrollMetrics.contentHeight,
            0
        )
        let viewportHeight = max(clipView.bounds.height, 0)
        let maxScrollTop = max(0, documentHeight - viewportHeight)

        let rawY = clipView.bounds.origin.y
        let scrollTop: CGFloat = if scrollView.documentView?.isFlipped == false {
            maxScrollTop - rawY
        } else {
            rawY
        }

        return MarkdownPreviewScrollReport(
            scrollTop: min(max(0, scrollTop), maxScrollTop),
            scrollHeight: documentHeight,
            clientHeight: viewportHeight
        )
    }

    private func applyPreferredScrollIfNeeded() {
        guard scrollSyncEnabled else { return }
        guard let requestedScrollTop = syncScrollRequest else { return }
        guard let scrollView else { return }

        let versionChanged = syncScrollRequestVersion != lastAppliedSyncRequestVersion
        let topChanged: Bool = if let lastAppliedSyncScrollTop {
            abs(lastAppliedSyncScrollTop - requestedScrollTop) > 0.5
        } else {
            true
        }

        guard versionChanged || topChanged else { return }

        let scrollReport = makeScrollReport(from: scrollView)
        let maxScrollTop = max(0, scrollReport.scrollHeight - scrollReport.clientHeight)
        let clampedScrollTop = min(max(0, requestedScrollTop), maxScrollTop)

        lastAppliedSyncRequestVersion = syncScrollRequestVersion
        lastAppliedSyncScrollTop = clampedScrollTop

        guard abs(scrollReport.scrollTop - clampedScrollTop) >= 0.5 else {
            currentScrollTop = scrollReport.scrollTop
            latestScrollMetrics = NativeMarkdownScrollMetricsPreferenceKey.Value(
                contentMinY: -scrollReport.scrollTop,
                contentHeight: scrollReport.scrollHeight,
                viewportHeight: scrollReport.clientHeight
            )
            return
        }

        programmaticScrollSuppressionUntil = Date().addingTimeInterval(Self.programmaticScrollSuppressionWindow)

        let clipView = scrollView.contentView
        let documentHeight = scrollReport.scrollHeight
        let viewportHeight = max(clipView.bounds.height, scrollReport.clientHeight)
        let maximumDocumentOriginY = max(0, documentHeight - viewportHeight)
        let targetY = scrollView.documentView?.isFlipped == false
            ? maximumDocumentOriginY - clampedScrollTop
            : clampedScrollTop

        let targetPoint = NSPoint(x: clipView.bounds.origin.x, y: targetY)
        clipView.setBoundsOrigin(targetPoint)
        clipView.scroll(to: targetPoint)
        scrollView.reflectScrolledClipView(clipView)

        handleScrollViewDidScroll(scrollView)
    }

    private func applyFragmentScrollIfNeeded(renderUnits: [NativeMarkdownRenderUnit]) {
        guard fragmentRequestVersion != lastAppliedFragmentRequestVersion else { return }
        guard let fragmentTarget, !fragmentTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = scrollToFragment(fragmentTarget, renderUnits: renderUnits)
    }

    @discardableResult
    private func scrollToFragment(_ fragment: String, renderUnits: [NativeMarkdownRenderUnit]) -> Bool {
        guard let scrollView else { return false }
        let normalizedTarget = normalizedAnchorFragment(fragment)
        guard let unit = renderUnits.first(where: { unit in
            guard case .markdown = unit.block else { return false }
            return headingFragments(for: unit).contains(normalizedTarget)
        })
        else { return false }
        guard let geometry = lastReportedAnchorGeometries.first(where: { $0.anchorID == unit.anchor.id }) else { return false }

        scrollPreview(to: max(0, geometry.top - 12), in: scrollView)
        lastAppliedFragmentRequestVersion = fragmentRequestVersion
        return true
    }

    private func scrollPreview(to requestedScrollTop: CGFloat, in scrollView: NSScrollView) {
        let report = makeScrollReport(from: scrollView)
        let maxScrollTop = max(0, report.scrollHeight - report.clientHeight)
        let clampedScrollTop = min(max(0, requestedScrollTop), maxScrollTop)
        let clipView = scrollView.contentView
        let maximumDocumentOriginY = max(0, report.scrollHeight - report.clientHeight)
        let targetY = scrollView.documentView?.isFlipped == false
            ? maximumDocumentOriginY - clampedScrollTop
            : clampedScrollTop
        let targetPoint = NSPoint(x: clipView.bounds.origin.x, y: targetY)
        clipView.setBoundsOrigin(targetPoint)
        clipView.scroll(to: targetPoint)
        scrollView.reflectScrolledClipView(clipView)
        handleScrollViewDidScroll(scrollView)
    }

    private func headingFragments(for unit: NativeMarkdownRenderUnit) -> Set<String> {
        var fragments: Set<String> = [unit.anchor.startLine.description]

        let markdown: String
        switch unit.block {
        case let .markdown(text): markdown = text
        case .mermaid: return fragments
        }

        for heading in markdownHeadingTexts(from: markdown) + htmlHeadingTexts(from: markdown) {
            let normalized = normalizedAnchorFragment(heading)
            if !normalized.isEmpty {
                fragments.insert(normalized)
            }
        }
        return fragments
    }

    private func markdownHeadingTexts(from markdown: String) -> [String] {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let hashes = trimmed.prefix { $0 == "#" }.count
            guard (1 ... 6).contains(hashes), trimmed.count > hashes else { return nil }
            let start = trimmed.index(trimmed.startIndex, offsetBy: hashes)
            guard trimmed[start].isWhitespace else { return nil }
            return String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func htmlHeadingTexts(from markdown: String) -> [String] {
        let pattern = #"(?is)<h[1-6]\b[^>]*>(.*?)</h[1-6]>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: markdown, options: [], range: NSRange(markdown.startIndex..., in: markdown)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: markdown) else { return nil }
            return String(markdown[range])
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func normalizedAnchorFragment(_ value: String) -> String {
        let decoded = value.removingPercentEncoding ?? value
        let lowercased = decoded.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let filteredScalars = lowercased.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(filteredScalars))
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func shouldReportAnchorGeometries(
        _ geometries: [MarkdownPreviewAnchorGeometry],
        contentHeight: CGFloat
    ) -> Bool {
        guard !lastReportedAnchorGeometries.isEmpty else { return !geometries.isEmpty }
        guard geometries.count == lastReportedAnchorGeometries.count else { return true }

        let contentHeightChanged = abs(contentHeight - lastReportedAnchorGeometryContentHeight) > 1
        for (current, previous) in zip(geometries, lastReportedAnchorGeometries) {
            guard current.anchorID == previous.anchorID,
                  current.startLine == previous.startLine,
                  current.endLine == previous.endLine
            else { return true }

            let heightChanged = abs(current.height - previous.height) > 1
            let topChanged = abs(current.top - previous.top) > 1
            if heightChanged || (topChanged && contentHeightChanged) {
                return true
            }
        }

        return false
    }
}

private struct NativeMarkdownRenderUnit: Identifiable, Equatable {
    enum Block: Equatable {
        case markdown(String)
        case mermaid(String)
    }

    let id: String
    let anchor: MarkdownSyncAnchor
    let block: Block
}

private enum NativeMarkdownRenderUnitBuilder {
    static func build(content: String) -> [NativeMarkdownRenderUnit] {
        let syncAnchors = MarkdownAnchorParser.parseAnchors(in: content)
        return NativeMarkdownDocumentParser.parseSpanned(content).enumerated().map { index, spannedBlock in
            let kind: MarkdownSyncAnchorKind = switch spannedBlock.block {
            case .markdown: .paragraph
            case .mermaid: .mermaid
            }
            let fallbackAnchor = MarkdownSyncAnchor(
                id: "anchor-\(kind.rawValue)-\(index + 1)",
                kind: kind,
                startLine: spannedBlock.startLine,
                endLine: spannedBlock.endLine
            )
            let anchor = syncAnchors.first { anchor in
                anchor.startLine >= spannedBlock.startLine && anchor.startLine <= spannedBlock.endLine
            } ?? fallbackAnchor
            let block: NativeMarkdownRenderUnit.Block = switch spannedBlock.block {
            case let .markdown(markdown): .markdown(markdown)
            case let .mermaid(source): .mermaid(source)
            }
            return NativeMarkdownRenderUnit(id: anchor.id, anchor: anchor, block: block)
        }
    }
}

private struct NativeMarkdownCompatibleMarkdownView: View {
    let markdown: String
    let baseURL: URL?
    let palette: MarkdownRenderer.Palette

    private var segments: [NativeMarkdownHTMLCompatibilityPreprocessor.Segment] {
        NativeMarkdownHTMLCompatibilityPreprocessor.segments(from: markdown, baseURL: baseURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(segments) { segment in
                switch segment.content {
                case let .markdown(markdown):
                    let preparedMarkdown = NativeMarkdownHTMLCompatibilityPreprocessor.preprocess(markdown, baseURL: baseURL)
                    NativeMarkdownFlowContentView(markdown: preparedMarkdown, baseURL: baseURL, palette: palette)

                case let .heading(level, text, alignment):
                    Text(text)
                        .font(headingFont(for: level))
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(nsColor: palette.foreground))
                        .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
                        .multilineTextAlignment(alignment.textAlignment)

                case let .paragraph(markdown, alignment):
                    let preparedMarkdown = NativeMarkdownHTMLCompatibilityPreprocessor.preprocess(markdown, baseURL: baseURL)
                    NativeMarkdownFlowContentView(
                        markdown: preparedMarkdown,
                        baseURL: baseURL,
                        palette: palette,
                        textAlignment: alignment.nsTextAlignment
                    )
                    .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)

                case let .images(images, alignment):
                    Group {
                        if images.count == 1, let image = images.first {
                            NativeMarkdownHTMLImageView(image: image, palette: palette)
                        } else {
                            HStack(alignment: .center, spacing: 8) {
                                ForEach(images) { image in
                                    NativeMarkdownHTMLImageView(image: image, palette: palette)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func headingFont(for level: Int) -> Font {
        let size: CGFloat = switch level {
        case 1: 32
        case 2: 24
        case 3: 20
        case 4: 17
        case 5: 15
        default: 14
        }

        if let fontFamilyName = palette.fontFamilyName {
            return .custom(fontFamilyName, size: size)
        }

        switch level {
        case 1,
             2: return .system(size: size, weight: .bold)
        default: return .system(size: size, weight: .semibold)
        }
    }
}

private struct NativeMarkdownHTMLImageView: View {
    let image: NativeMarkdownHTMLCompatibilityPreprocessor.HTMLImage
    let palette: MarkdownRenderer.Palette
    @State private var remoteImage: NSImage?
    @State private var remoteImageLoadFailed = false
    @State private var remoteImageIsLoading = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            imageContent
                .frame(width: requestedWidth, height: requestedHeight, alignment: .center)

            imageContent
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityLabel(image.alt.isEmpty ? "Markdown image" : image.alt)
        .task(id: image.resolvedURL) {
            await loadRemoteImageIfNeeded()
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let renderedImage {
            Image(nsImage: renderedImage)
                .resizable()
                .scaledToFit()
        } else if remoteImageIsLoading {
            ProgressView()
        } else if shouldLoadRemoteImage, !remoteImageLoadFailed {
            ProgressView()
        } else {
            missingImageLabel
        }
    }

    private var renderedImage: NSImage? {
        nsImage ?? remoteImage
    }

    private var shouldLoadRemoteImage: Bool {
        guard MarkdownPreviewPreferences.allowRemoteImages,
              let url = image.resolvedURL,
              !url.isFileURL
        else { return false }
        return url.scheme?.lowercased() == "https"
    }

    private var nsImage: NSImage? {
        guard let url = image.resolvedURL, url.isFileURL else { return nil }
        return NSImage(contentsOf: url)
    }

    private var requestedWidth: CGFloat? {
        image.width ?? renderedImage?.size.width
    }

    private var requestedHeight: CGFloat? {
        image.height ?? renderedImage?.size.height
    }

    private var aspectRatio: CGFloat? {
        if let width = requestedWidth, let height = requestedHeight, width > 0, height > 0 {
            return width / height
        }

        guard let size = renderedImage?.size, size.width > 0, size.height > 0 else { return nil }
        return size.width / size.height
    }

    private func loadRemoteImageIfNeeded() async {
        guard let url = image.resolvedURL, !url.isFileURL else { return }
        guard shouldLoadRemoteImage else {
            await MainActor.run {
                remoteImage = nil
                remoteImageLoadFailed = true
                remoteImageIsLoading = false
            }
            return
        }

        await MainActor.run {
            remoteImage = nil
            remoteImageLoadFailed = false
            remoteImageIsLoading = true
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("Muxy Markdown Preview", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200 ..< 300).contains(httpResponse.statusCode) {
                throw URLError(.badServerResponse)
            }

            guard let loadedImage = NSImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }

            await MainActor.run {
                remoteImage = loadedImage
                remoteImageLoadFailed = false
                remoteImageIsLoading = false
            }
        } catch {
            await MainActor.run {
                remoteImage = nil
                remoteImageLoadFailed = true
                remoteImageIsLoading = false
            }
        }
    }

    private var missingImageLabel: some View {
        Label(image.alt.isEmpty ? "Image unavailable" : image.alt, systemImage: "photo")
            .font(.caption)
            .foregroundStyle(Color(nsColor: palette.foreground).opacity(0.7))
            .padding(8)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: palette.borderColor), lineWidth: 1)
            )
    }
}

private enum NativeMarkdownHTMLCompatibilityPreprocessor {
    struct Segment: Identifiable {
        let id: Int
        let content: Content

        enum Content {
            case markdown(String)
            case heading(level: Int, text: String, alignment: HTMLAlignment)
            case paragraph(markdown: String, alignment: HTMLAlignment)
            case images([HTMLImage], alignment: HTMLAlignment)
        }
    }

    struct HTMLImage: Identifiable {
        let id: String
        let source: String
        let alt: String
        let width: CGFloat?
        let height: CGFloat?
        let resolvedURL: URL?
    }

    struct HTMLHeading {
        let level: Int
        let text: String
        let alignment: HTMLAlignment
    }

    enum HTMLAlignment {
        case leading
        case center
        case trailing

        var frameAlignment: Alignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }

        var textAlignment: TextAlignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }

        var nsTextAlignment: NSTextAlignment {
            switch self {
            case .leading: .left
            case .center: .center
            case .trailing: .right
            }
        }

        init(attributes: [String: String]) {
            switch attributes["align"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "center": self = .center
            case "right",
                 "end": self = .trailing
            default: self = .leading
            }
        }
    }

    static func segments(from markdown: String, baseURL: URL?) -> [Segment] {
        var output: [Segment] = []
        var markdownBuffer: [String] = []
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        func flushMarkdown() {
            let text = markdownBuffer.joined(separator: "\n")
            markdownBuffer.removeAll(keepingCapacity: true)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            output.append(Segment(id: output.count, content: .markdown(text)))
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if let heading = parseHeading(trimmed) {
                flushMarkdown()
                output.append(Segment(id: output.count, content: .heading(
                    level: heading.level,
                    text: heading.text,
                    alignment: heading.alignment
                )))
                index += 1
                continue
            }

            if let containerStart = parseContainerStart(trimmed) {
                var htmlLines = [line]
                var scanIndex = index
                while !containsClosingContainer(htmlLines.joined(separator: "\n"), tag: containerStart.tag), scanIndex + 1 < lines.count {
                    scanIndex += 1
                    htmlLines.append(lines[scanIndex])
                }

                let html = htmlLines.joined(separator: "\n")
                if let content = parseContainer(html, tag: containerStart.tag, baseURL: baseURL) {
                    flushMarkdown()
                    output.append(Segment(id: output.count, content: content))
                    index = scanIndex + 1
                    continue
                }
            }

            if let images = parseImagesOnlyHTML(trimmed, baseURL: baseURL), !images.isEmpty {
                flushMarkdown()
                output.append(Segment(id: output.count, content: .images(images, alignment: .leading)))
                index += 1
                continue
            }

            markdownBuffer.append(line)
            index += 1
        }

        flushMarkdown()
        return output.isEmpty ? [Segment(id: 0, content: .markdown(markdown))] : output
    }

    static func preprocess(_ markdown: String, baseURL: URL?) -> String {
        var output = markdown
        output = replaceImages(in: output, baseURL: baseURL)
        output = replaceHeadings(in: output)
        output = replaceLinks(in: output)
        output = replaceLineBreaks(in: output)
        output = stripContainerTags(in: output)
        output = decodeBasicHTMLEntities(in: output)
        return output
    }

    private static func parseHeading(_ html: String) -> HTMLHeading? {
        guard let match = firstMatch(pattern: #"(?is)^<h([1-6])\b([^>]*)>(.*?)</h\1>$"#, in: html),
              let level = Int(match.capture(1))
        else { return nil }
        let attributes = parseAttributes(match.capture(2))
        let text = decodeBasicHTMLEntities(in: stripAllTags(from: match.capture(3)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return HTMLHeading(level: level, text: text, alignment: HTMLAlignment(attributes: attributes))
    }

    private static func parseContainerStart(_ html: String) -> (tag: String, attributes: [String: String])? {
        guard let match = firstMatch(pattern: #"(?is)^<(p|div|center)\b([^>]*)>"#, in: html) else { return nil }
        let tag = match.capture(1).lowercased()
        var attributes = parseAttributes(match.capture(2))
        if tag == "center" { attributes["align"] = "center" }
        return (tag, attributes)
    }

    private static func parseContainer(_ html: String, tag: String, baseURL: URL?) -> Segment.Content? {
        guard let start = parseContainerStart(html.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let alignment = HTMLAlignment(attributes: start.attributes)
        let inner = stripOuterContainer(from: html, tag: tag)
        let images = parseImages(in: inner, baseURL: baseURL)
        let remainder = stripAllTags(from: replaceMatches(pattern: #"(?is)<img\b([^>]*)/?>"#, in: inner) { _ in "" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !images.isEmpty, remainder.isEmpty {
            return .images(images, alignment: alignment)
        }

        let paragraph = inlineHTMLToMarkdown(inner, baseURL: baseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paragraph.isEmpty else { return nil }
        return .paragraph(markdown: paragraph, alignment: alignment)
    }

    private static func parseImagesOnlyHTML(_ html: String, baseURL: URL?) -> [HTMLImage]? {
        guard html.range(of: #"<img\b"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        let remainder = stripAllTags(from: replaceMatches(pattern: #"(?is)<img\b([^>]*)/?>"#, in: html) { _ in "" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard remainder.isEmpty else { return nil }
        return parseImages(in: html, baseURL: baseURL)
    }

    private static func parseImages(in html: String, baseURL: URL?) -> [HTMLImage] {
        allMatches(pattern: #"(?is)<img\b([^>]*)/?>"#, in: html).compactMap { match in
            let attributes = parseAttributes(match.capture(1))
            guard let source = attributes["src"], !source.isEmpty else { return nil }
            let width = parseCGFloat(attributes["width"])
            let height = parseCGFloat(attributes["height"])
            return HTMLImage(
                id: stableImageID(source: source, width: width, height: height, alt: attributes["alt"]),
                source: source,
                alt: attributes["alt"] ?? "",
                width: width,
                height: height,
                resolvedURL: resolveImageURL(source, baseURL: baseURL)
            )
        }
    }

    private static func replaceImages(in markdown: String, baseURL: URL?) -> String {
        replaceMatches(
            pattern: #"(?is)<img\b([^>]*)/?>"#,
            in: markdown
        ) { match in
            let attributes = parseAttributes(match.capture(1))
            guard let source = attributes["src"], !source.isEmpty else { return "" }
            let alt = attributes["alt"].map(escapeMarkdownText) ?? ""
            let resolvedSource = resolveImageURL(source, baseURL: baseURL)?.absoluteString ?? source
            return "\n\n![\(alt)](<\(resolvedSource)>)\n\n"
        }
    }

    private static func replaceHeadings(in markdown: String) -> String {
        replaceMatches(
            pattern: #"(?is)<h([1-6])\b([^>]*)>(.*?)</h\1>"#,
            in: markdown
        ) { match in
            let level = max(1, min(6, Int(match.capture(1)) ?? 1))
            let text = decodeBasicHTMLEntities(in: stripAllTags(from: match.capture(3)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\n\n\(String(repeating: "#", count: level)) \(text)\n\n"
        }
    }

    private static func replaceLinks(in markdown: String) -> String {
        replaceMatches(
            pattern: #"(?is)<a\b([^>]*)>(.*?)</a>"#,
            in: markdown
        ) { match in
            let attributes = parseAttributes(match.capture(1))
            guard let href = attributes["href"], !href.isEmpty else {
                return match.capture(2)
            }
            let label = stripAllTags(from: match.capture(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(escapeMarkdownText(label.isEmpty ? href : label))](<\(href)>)"
        }
    }

    private static func replaceLineBreaks(in markdown: String) -> String {
        replaceMatches(pattern: #"(?i)<br\s*/?>"#, in: markdown) { _ in "  \n" }
    }

    private static func stripContainerTags(in markdown: String) -> String {
        replaceMatches(
            pattern: #"(?is)</?\s*(p|div|span|center|section|article|header|footer)\b[^>]*>"#,
            in: markdown
        ) { _ in "\n" }
    }

    private static func inlineHTMLToMarkdown(_ html: String, baseURL: URL?) -> String {
        var output = html
        output = replaceImages(in: output, baseURL: baseURL)
        output = replaceLinks(in: output)
        output = replaceLineBreaks(in: output)
        output = stripContainerTags(in: output)
        output = decodeBasicHTMLEntities(in: output)
        return output
    }

    private static func stripOuterContainer(from html: String, tag: String) -> String {
        var output = html
        output = replaceMatches(pattern: #"(?is)^\s*<\#(tag)\b[^>]*>"#, in: output) { _ in "" }
        output = replaceMatches(pattern: #"(?is)</\#(tag)>\s*$"#, in: output) { _ in "" }
        return output
    }

    private static func containsClosingContainer(_ html: String, tag: String) -> Bool {
        html.range(of: #"</\#(tag)>"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func resolveImageURL(_ source: String, baseURL: URL?) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            if scheme.lowercased() == "file" { return url.standardizedFileURL }
            return url
        }

        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }

        guard let baseURL else { return URL(string: trimmed) }
        return URL(fileURLWithPath: trimmed, relativeTo: baseURL).standardizedFileURL
    }

    private static func parseCGFloat(_ value: String?) -> CGFloat? {
        guard let value else { return nil }
        let numeric = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "px", with: "")
        guard let double = Double(numeric), double > 0 else { return nil }
        return CGFloat(double)
    }

    private static func stableImageID(source: String, width: CGFloat?, height: CGFloat?, alt: String?) -> String {
        [
            source,
            width.map { String(Double($0)) } ?? "",
            height.map { String(Double($0)) } ?? "",
            alt ?? "",
        ].joined(separator: "|")
    }

    private static func stripAllTags(from html: String) -> String {
        replaceMatches(pattern: #"(?is)<[^>]+>"#, in: html) { _ in "" }
    }

    private static func parseAttributes(_ rawAttributes: String) -> [String: String] {
        var attributes: [String: String] = [:]
        guard let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>/]+))"#,
            options: []
        )
        else { return attributes }

        let nsString = rawAttributes as NSString
        let range = NSRange(location: 0, length: nsString.length)
        for match in regex.matches(in: rawAttributes, options: [], range: range) {
            guard match.numberOfRanges >= 5 else { continue }
            let name = nsString.substring(with: match.range(at: 1)).lowercased()
            let valueRange = (2 ..< 5)
                .map { match.range(at: $0) }
                .first { $0.location != NSNotFound }
            guard let valueRange else { continue }
            attributes[name] = decodeBasicHTMLEntities(in: nsString.substring(with: valueRange))
        }
        return attributes
    }

    private static func firstMatch(pattern: String, in string: String) -> RegexMatch? {
        allMatches(pattern: pattern, in: string).first
    }

    private static func allMatches(pattern: String, in string: String) -> [RegexMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsString = string as NSString
        let matches = regex.matches(in: string, options: [], range: NSRange(location: 0, length: nsString.length))
        return matches.map { RegexMatch(match: $0, source: nsString) }
    }

    private static func replaceMatches(
        pattern: String,
        in string: String,
        transform: (RegexMatch) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return string }
        let nsString = string as NSString
        let matches = regex.matches(in: string, options: [], range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return string }

        var result = string
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(RegexMatch(match: match, source: nsString)))
        }
        return result
    }

    private static func escapeMarkdownText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func decodeBasicHTMLEntities(in text: String) -> String {
        text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private struct RegexMatch {
        let match: NSTextCheckingResult
        let source: NSString

        func capture(_ index: Int) -> String {
            guard index < match.numberOfRanges else { return "" }
            let range = match.range(at: index)
            guard range.location != NSNotFound else { return "" }
            return source.substring(with: range)
        }
    }
}

private struct NativeMarkdownAnchorFrame: Equatable, Identifiable {
    let id: String
    let anchorID: String?
    let startLine: Int?
    let endLine: Int?
    let minY: CGFloat
    let height: CGFloat
}

private enum NativeMarkdownAnchorFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [NativeMarkdownAnchorFrame] { [] }

    static func reduce(value: inout [NativeMarkdownAnchorFrame], nextValue: () -> [NativeMarkdownAnchorFrame]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    func nativeMarkdownAnchorGeometry(anchorID: String?, startLine: Int?, endLine: Int?) -> some View {
        background(
            GeometryReader { proxy in
                let rect = proxy.frame(in: .named(NativeMarkdownScrollMetricsPreferenceKey.coordinateSpaceName))
                if let anchorID {
                    Color.clear.preference(
                        key: NativeMarkdownAnchorFramesPreferenceKey.self,
                        value: [
                            NativeMarkdownAnchorFrame(
                                id: anchorID,
                                anchorID: anchorID,
                                startLine: startLine,
                                endLine: endLine,
                                minY: rect.minY,
                                height: rect.height
                            ),
                        ]
                    )
                } else {
                    Color.clear.preference(key: NativeMarkdownAnchorFramesPreferenceKey.self, value: [])
                }
            }
        )
    }
}

private enum NativeMarkdownScrollMetricsPreferenceKey: PreferenceKey {
    static let coordinateSpaceName = "NativeMarkdownPreviewScrollView"

    struct Value: Equatable {
        var contentMinY: CGFloat
        var contentHeight: CGFloat
        var viewportHeight: CGFloat
    }

    static var defaultValue: Value {
        Value(contentMinY: 0, contentHeight: 0, viewportHeight: 0)
    }

    static func reduce(value: inout Value, nextValue: () -> Value) {
        value = nextValue()
    }
}

extension MarkdownRenderer.Palette {
    var borderColor: NSColor {
        background.blended(withFraction: 0.18, of: foreground) ?? foreground.withAlphaComponent(0.25)
    }

    var codeBackgroundColor: NSColor {
        background.blended(withFraction: 0.08, of: foreground) ?? background
    }

    var rowBackgroundColor: NSColor {
        background.blended(withFraction: 0.04, of: foreground) ?? background
    }
}
