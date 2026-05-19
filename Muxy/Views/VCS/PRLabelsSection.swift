import SwiftUI

struct PRLabelsSection: View {
    @Bindable var state: VCSTabState
    let info: GitRepositoryService.PRInfo

    @State private var showAddLabelPopover = false

    private var canEditLabels: Bool {
        info.state == .open
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIMetrics.spacing3) {
            HStack(spacing: UIMetrics.spacing3) {
                Text("Labels")
                    .font(.system(size: UIMetrics.fontFootnote))
                    .foregroundStyle(MuxyTheme.fgMuted)
                Spacer(minLength: 0)
                if canEditLabels {
                    addLabelButton
                }
            }

            if info.labels.isEmpty {
                Text("No labels")
                    .font(.system(size: UIMetrics.fontFootnote))
                    .foregroundStyle(MuxyTheme.fgDim)
            } else {
                LabelFlowLayout(spacing: UIMetrics.spacing2, lineSpacing: UIMetrics.spacing2) {
                    ForEach(info.labels) { label in
                        labelBadge(label)
                    }
                }
            }
        }
    }

    private var addLabelButton: some View {
        Button {
            showAddLabelPopover = true
            state.loadRepositoryLabels()
        } label: {
            HStack(spacing: UIMetrics.spacing1) {
                Image(systemName: "plus")
                    .font(.system(size: UIMetrics.fontMicro, weight: .bold))
                Text("Add")
                    .font(.system(size: UIMetrics.fontCaption, weight: .medium))
            }
            .foregroundStyle(MuxyTheme.fgMuted)
            .padding(.horizontal, UIMetrics.spacing3)
            .padding(.vertical, UIMetrics.scaled(2))
            .background(MuxyTheme.surface, in: RoundedRectangle(cornerRadius: UIMetrics.radiusSM))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAddLabelPopover, arrowEdge: .trailing) {
            AddLabelPopover(
                state: state,
                appliedNames: Set(info.labels.map(\.name)),
                onSelect: { name in
                    showAddLabelPopover = false
                    state.addLabel(name)
                }
            )
        }
    }

    private func labelBadge(_ label: GitRepositoryService.PRLabel) -> some View {
        let bg = Color(hex: label.color) ?? MuxyTheme.surface
        let fg = LabelColorMath.foreground(forHex: label.color)
        let isPending = state.pendingLabelUpdates.contains(label.name)

        return HStack(spacing: UIMetrics.spacing2) {
            Text(label.name)
                .font(.system(size: UIMetrics.fontCaption, weight: .semibold))
                .foregroundStyle(fg)
                .lineLimit(1)
            if canEditLabels {
                Button {
                    state.removeLabel(label.name)
                } label: {
                    if isPending {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: "xmark")
                            .font(.system(size: UIMetrics.fontMicro, weight: .bold))
                            .foregroundStyle(fg.opacity(0.75))
                    }
                }
                .buttonStyle(.plain)
                .disabled(isPending)
                .help("Remove \(label.name)")
            }
        }
        .padding(.horizontal, UIMetrics.spacing3)
        .padding(.vertical, UIMetrics.scaled(2))
        .background(bg, in: RoundedRectangle(cornerRadius: UIMetrics.radiusSM))
        .help(label.description.isEmpty ? label.name : "\(label.name) — \(label.description)")
    }
}

private struct AddLabelPopover: View {
    @Bindable var state: VCSTabState
    let appliedNames: Set<String>
    let onSelect: (String) -> Void

    @State private var searchText = ""

    private var filtered: [GitRepositoryService.PRLabel] {
        let unapplied = state.availableRepositoryLabels.filter { !appliedNames.contains($0.name) }
        guard !searchText.isEmpty else { return unapplied }
        return unapplied.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: UIMetrics.spacing3) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: UIMetrics.fontFootnote))
                    .foregroundStyle(MuxyTheme.fgMuted)
                TextField("Search labels", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: UIMetrics.fontFootnote))
            }
            .padding(.horizontal, UIMetrics.spacing4)
            .padding(.vertical, UIMetrics.spacing3)

            Divider().overlay(MuxyTheme.border)

            content
        }
        .frame(width: UIMetrics.scaled(240))
        .frame(maxHeight: UIMetrics.scaled(280))
        .background(MuxyTheme.bg)
        .task { state.loadRepositoryLabels() }
    }

    @ViewBuilder
    private var content: some View {
        if state.isLoadingRepositoryLabels, state.availableRepositoryLabels.isEmpty {
            VStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(UIMetrics.spacing5)
        } else if let error = state.repositoryLabelsError {
            VStack(alignment: .leading, spacing: UIMetrics.spacing3) {
                Text(error)
                    .font(.system(size: UIMetrics.fontFootnote))
                    .foregroundStyle(MuxyTheme.diffRemoveFg)
                Button("Retry") { state.loadRepositoryLabels(force: true) }
                    .font(.system(size: UIMetrics.fontFootnote))
            }
            .padding(UIMetrics.spacing5)
        } else if filtered.isEmpty {
            Text(searchText.isEmpty ? "No labels available" : "No matches")
                .font(.system(size: UIMetrics.fontFootnote))
                .foregroundStyle(MuxyTheme.fgMuted)
                .padding(UIMetrics.spacing5)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { label in
                        labelRow(label)
                    }
                }
                .padding(.vertical, UIMetrics.spacing2)
            }
        }
    }

    private func labelRow(_ label: GitRepositoryService.PRLabel) -> some View {
        let pending = state.pendingLabelUpdates.contains(label.name)
        return Button {
            guard !pending else { return }
            onSelect(label.name)
        } label: {
            HStack(spacing: UIMetrics.spacing3) {
                Circle()
                    .fill(Color(hex: label.color) ?? MuxyTheme.surface)
                    .frame(width: UIMetrics.scaled(10), height: UIMetrics.scaled(10))
                Text(label.name)
                    .font(.system(size: UIMetrics.fontFootnote, weight: .medium))
                    .foregroundStyle(MuxyTheme.fg)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if pending {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, UIMetrics.spacing4)
            .padding(.vertical, UIMetrics.spacing3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pending)
    }
}

enum LabelColorMath {
    static func foreground(forHex hex: String) -> Color {
        var trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return .white }
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return luminance > 0.6 ? .black : .white
    }
}

struct LabelFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let arrangement = arrange(subviews: subviews, maxWidth: maxWidth)
        return CGSize(width: arrangement.width, height: arrangement.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let arrangement = arrange(subviews: subviews, maxWidth: proposal.width ?? bounds.width)
        for placement in arrangement.placements {
            subviews[placement.index].place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private struct Placement {
        let index: Int
        let origin: CGPoint
        let size: CGSize
    }

    private struct Arrangement {
        let placements: [Placement]
        let width: CGFloat
        let height: CGFloat
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> Arrangement {
        var placements: [Placement] = []
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0
        var cursorY: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needsNewLine = rowWidth > 0 && rowWidth + spacing + size.width > maxWidth
            if needsNewLine {
                maxRowWidth = max(maxRowWidth, rowWidth)
                cursorY += rowHeight + lineSpacing
                totalHeight = cursorY
                rowWidth = 0
                rowHeight = 0
            }
            let x = rowWidth == 0 ? 0 : rowWidth + spacing
            placements.append(Placement(index: index, origin: CGPoint(x: x, y: cursorY), size: size))
            rowWidth = x + size.width
            rowHeight = max(rowHeight, size.height)
        }
        maxRowWidth = max(maxRowWidth, rowWidth)
        totalHeight = cursorY + rowHeight
        return Arrangement(placements: placements, width: maxRowWidth, height: totalHeight)
    }
}
