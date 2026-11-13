import SwiftUI
import HFCore
import HFInsight

/// Het grid zelf: één schuifvlak in twee richtingen, met een vaste eerste kolom, een vaste koprij
/// en de totaalrijen vast onderaan. De vaste lagen schuiven tegen de scrollpositie in.
struct GridTable: View {
    @Environment(AppModel.self) private var model

    var grid: MonthGrid
    var lines: [GridLine]
    var density: GridDensity
    var options: GridOptions
    var reserveExpanded: Bool
    var onToggleReserve: () -> Void

    @State private var scroll: CGPoint = .zero
    @State private var popover: GridTarget?
    @State private var popoverRect: CGRect = .zero
    @State private var form: GridTarget?

    private var hasReserveLines: Bool { grid.rows.contains { $0.kind == .reserveLine } }

    /// Hoogte van alles samen; het vlak wordt niet hoger dan nodig.
    static func contentHeight(lineCount: Int, density: GridDensity) -> CGFloat {
        28 + CGFloat(lineCount + GridTotalLine.allCases.count) * density.rowHeight
    }

    /// Het zichtbare deel van het schuifvlak. Met vaste schuifbalken (muis, of de systeeminstelling
    /// "altijd tonen") nemen die ruimte in; met zwevende schuifbalken niet.
    static func visibleSize(in size: CGSize, lineCount: Int, density: GridDensity) -> CGSize {
        guard NSScroller.preferredScrollerStyle == .legacy else { return size }
        let bar = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let height = contentHeight(lineCount: lineCount, density: density)
        var visible = size
        if height > size.height { visible.width -= bar }
        if GridLayout(density: density, availableWidth: visible.width).contentWidth > visible.width {
            visible.height -= bar
            if height > visible.height && visible.width == size.width { visible.width -= bar }
        }
        return visible
    }

    var body: some View {
        GeometryReader { geo in
            let visible = Self.visibleSize(in: geo.size, lineCount: lines.count, density: density)
            let layout = GridLayout(density: density, availableWidth: visible.width)
            let bodyHeight = CGFloat(lines.count) * layout.rowHeight
            let footerHeight = CGFloat(GridTotalLine.allCases.count) * layout.rowHeight
            let contentHeight = layout.headerHeight + bodyHeight + footerHeight
            let maxX = max(0, layout.contentWidth - visible.width)
            let maxY = max(0, contentHeight - visible.height)
            let x = min(max(scroll.x, 0), maxX)
            let y = min(max(scroll.y, 0), maxY)
            // De totaalrijen staan onderaan de inhoud; schuif ze omhoog tot de onderrand van het venster.
            let footerY = layout.headerHeight + bodyHeight - (maxY - y)

            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    GridBodyLayer(lines: lines, layout: layout, options: options, selectedId: popover?.id,
                                  onClick: { target, index in
                                      show(target, at: CGRect(x: layout.monthX(target.month) - x,
                                                              y: layout.headerHeight + CGFloat(index) * layout.rowHeight - y,
                                                              width: layout.columnWidth, height: layout.rowHeight))
                                  },
                                  onDoubleClick: { target in startForm(target) })
                        .equatable()
                        .offset(x: layout.labelWidth, y: layout.headerHeight)

                    GridLabelLayer(lines: lines, layout: layout, reserveExpanded: reserveExpanded,
                                   hasReserveLines: hasReserveLines, onToggleReserve: onToggleReserve)
                        .equatable()
                        .offset(x: x, y: layout.headerHeight)

                    GridFooterLayer(grid: grid, layout: layout, options: options, selectedId: popover?.id,
                                    onClick: { target, index in
                                        show(target, at: CGRect(x: layout.monthX(target.month) - x,
                                                                y: footerY + CGFloat(index) * layout.rowHeight - y,
                                                                width: layout.columnWidth, height: layout.rowHeight))
                                    })
                        .equatable()
                        .offset(x: layout.labelWidth, y: footerY)
                        .shadow(color: .black.opacity(maxY - y > 0.5 ? 0.10 : 0), radius: 5, y: -2)

                    GridFooterLabelLayer(layout: layout)
                        .equatable()
                        .offset(x: x, y: footerY)

                    GridHeaderLayer(layout: layout, options: options)
                        .equatable()
                        .offset(x: layout.labelWidth, y: y)

                    corner(layout)
                        .offset(x: x, y: y)
                }
                .frame(width: layout.contentWidth, height: contentHeight, alignment: .topLeading)
            }
            .onScrollGeometryChange(for: GridScrollState.self) {
                GridScrollState(offset: $0.contentOffset, visible: $0.containerSize)
            } action: { old, new in
                scroll = new.offset
                // Een open venstertje hoort bij een cel; na schuiven klopt de plek niet meer.
                if old.offset != new.offset, popover != nil { popover = nil }
            }
            .popover(item: $popover, attachmentAnchor: .rect(.rect(popoverRect)), arrowEdge: .bottom) { target in
                GridCellPopover(target: target, options: options, total: total(of: target),
                                onAdd: { popover = nil; startForm(target) },
                                onShowTransactions: { popover = nil; model.selection = .transactions })
                    .environment(model)
            }
        }
        .sheet(item: $form) { target in
            if case .item(let row) = target.kind {
                GridEntryForm(row: row, year: options.year, month: target.month)
                    .environment(model)
            }
        }
    }

    private func corner(_ layout: GridLayout) -> some View {
        Text("Vaste post")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 12)
            .frame(width: layout.labelWidth, height: layout.headerHeight, alignment: .leading)
            .background(GridPalette.header)
            .overlay(alignment: .bottom) { GridRowLine(strong: true) }
            .overlay(alignment: .trailing) { GridColumnLine() }
    }

    private func total(of target: GridTarget) -> Money {
        switch target.kind {
        case .item(let row):
            return row.cells.first { $0.month == target.month }?.sum ?? .zero
        case .divers(let positive):
            guard let totals = grid.monthTotals.first(where: { $0.month == target.month }) else { return .zero }
            return positive ? totals.inDivers : totals.uitDivers
        }
    }

    private func show(_ target: GridTarget, at rect: CGRect) {
        popoverRect = rect
        popover = target
    }

    private func startForm(_ target: GridTarget) {
        guard case .item(let row) = target.kind, row.kind != .reserveLine else { return }
        guard options.editable else {
            model.toast = "\(String(options.year)) is afgesloten; boekingen toevoegen kan niet."
            return
        }
        form = target
    }
}

/// Scrollpositie en zichtbare maat van het schuifvlak.
struct GridScrollState: Equatable {
    var offset: CGPoint
    var visible: CGSize
}
