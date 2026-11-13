import SwiftUI
import HFCore
import HFImport

/// Voorbeeld van een gekozen bestand, vóór het importeren. Bij een zip van de bank één blok per rekening.
struct ReviewImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(ReviewStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let pending: ReviewPendingImport
    @State private var skipFaulty = false

    private var canImport: Bool { pending.newCount > 0 && (pending.errorCount == 0 || skipFaulty) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let recognition = pending.recognition {
                        Label(recognition, systemImage: pending.recognized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(pending.recognized ? Theme.positive : Theme.warning)
                            .font(.callout.weight(.medium))
                            .help("De rekening wordt bepaald door het IBAN in het bestand of in de bestandsnaam, niet door de rekening die bovenaan gekozen is.")
                    }
                    ForEach(pending.parts) { part in
                        ReviewImportPartView(part: part, showFileName: pending.archive != nil,
                                             expanded: pending.parts.count == 1)
                    }
                    if !pending.skipped.isEmpty { skipped }
                    if pending.parts.isEmpty {
                        Label("In dit bestand zit niets dat geïmporteerd kan worden.", systemImage: "tray")
                            .foregroundStyle(.secondary)
                    }
                    if pending.errorCount > 0 {
                        Toggle("Foute regels overslaan en de rest importeren", isOn: $skipFaulty)
                            .help("Zonder dit vinkje wordt er niets geïmporteerd. Foute regels moet je dan later met de hand invoeren.")
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 640)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: pending.archive != nil ? "doc.zipper" : "doc.text").font(.title).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(pending.fileName).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var subtitle: String {
        if pending.archive != nil {
            let n = pending.parts.count
            return n == 1 ? "Zip van de bank · 1 rekening" : "Zip van de bank · \(n) rekeningen"
        }
        return "Importeren naar \(pending.parts.first?.accountName ?? "de gekozen rekening")"
    }

    private var skipped: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(pending.skipped.count == 1 ? "1 bestand gaat niet mee" : "\(pending.skipped.count) bestanden gaan niet mee",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(Theme.warning)
            ForEach(pending.skipped) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.fileName).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Text(item.message ?? "Dit bestand kan niet geïmporteerd worden.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Hoort een bestand bij een rekening die nog niet bestaat? Maak die eerst aan in Instellingen, met het juiste IBAN.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack {
            if pending.newCount == 0 {
                Text("Alles staat al in de app; er is niets nieuws.").font(.callout).foregroundStyle(.secondary)
            } else if pending.errorCount > 0, !skipFaulty {
                Text("Vink 'Foute regels overslaan' aan om toch te importeren.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Annuleren") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(buttonTitle) { store.commit(pending, skipFaultyRows: skipFaulty, model) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canImport)
        }
        .padding(16)
    }

    private var buttonTitle: String {
        let n = pending.newCount
        let count = n == 1 ? "1 transactie" : "\(n) transacties"
        return pending.archive != nil ? "Importeer alles (\(count))" : "Importeer \(count)"
    }
}

/// Eén rekening in het voorbeeld: aantallen, periode, saldi, saldoketen, fouten en (uitklapbaar) de regels.
private struct ReviewImportPartView: View {
    let part: ReviewImportPart
    var showFileName: Bool
    @State var expanded: Bool

    private var preview: ImportPreview { part.preview }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(part.accountName).font(.headline)
                    if showFileName {
                        Text(part.fileName).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                Text(preview.profile.name).font(.caption).foregroundStyle(.secondary)
                    .help("De herkende indeling van het bestand (\(preview.encodingName)).")
            }
            HStack(alignment: .top, spacing: 26) {
                fact("Nieuw", "\(preview.newCount)", strong: true)
                fact("Al bekend", "\(preview.duplicateCount)")
                fact("Fout", "\(preview.errorCount)", color: preview.errorCount > 0 ? Theme.negative : nil)
                fact("Periode", period)
                fact("Beginsaldo", preview.openingBalance?.formatted() ?? "—")
                fact("Eindsaldo", preview.closingBalance?.formatted() ?? "—")
                Spacer(minLength: 0)
            }
            chain
            ForEach(Array(preview.warnings.filter { $0.kind == .ibanMismatch }.enumerated()), id: \.offset) { _, warning in
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Theme.warning)
            }
            if !preview.errors.isEmpty { errors }
            DisclosureGroup(isExpanded: $expanded) {
                rows.padding(.top, 6)
            } label: {
                Text("Transacties in het bestand (\(preview.rows.count))").font(.callout)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private var period: String {
        guard let first = preview.firstDay, let last = preview.lastDay else { return "—" }
        return "\(first.short(withYear: first.year != last.year)) t/m \(last.short(withYear: true))"
    }

    private func fact(_ title: String, _ value: String, strong: Bool = false, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(strong ? .title3.weight(.semibold) : .body.weight(.medium)).monospacedDigit()
                .foregroundStyle(color ?? Color.primary)
        }
    }

    @ViewBuilder private var chain: some View {
        Group {
            switch preview.chainOK {
            case true?:
                Label("De saldoketen sluit: elk saldo volgt uit het vorige saldo en het bedrag.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.positive)
            case false?:
                VStack(alignment: .leading, spacing: 4) {
                    Label("De saldoketen sluit niet. Er ontbreekt mogelijk een regel.", systemImage: "xmark.seal.fill")
                        .foregroundStyle(Theme.negative)
                    ForEach(Array(preview.chainBreaks.prefix(3).enumerated()), id: \.offset) { _, chainBreak in
                        Text(chainBreak.message).font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
                    }
                    if preview.chainBreaks.count > 3 {
                        Text("… en nog \(preview.chainBreaks.count - 3)").font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
                    }
                }
            case nil:
                Label("Het bestand levert geen saldo per regel; de saldoketen is niet gecontroleerd.", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .help("Saldoketen: de bank levert bij elke regel het saldo vóór de mutatie. Dat saldo plus het bedrag moet het saldo van de volgende regel zijn.")
    }

    private var errors: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(preview.errorCount == 1 ? "1 regel kan niet gelezen worden" : "\(preview.errorCount) regels kunnen niet gelezen worden")
                .font(.callout.weight(.semibold)).foregroundStyle(Theme.negative)
            ForEach(preview.errors.prefix(20)) { error in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Regel \(error.lineNumber)").monospacedDigit().fontWeight(.medium).frame(width: 74, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(error.message)
                        if !error.fields.isEmpty {
                            Text(error.fields.joined(separator: " | ")).font(.caption.monospaced())
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .font(.callout)
            }
            if preview.errors.count > 20 {
                Text("… en nog \(preview.errors.count - 20) regels").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.negative.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private var rows: some View {
        let all = preview.rowsChronological
        let shown = Array(all.prefix(40))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { row in
                HStack(spacing: 10) {
                    Text("\(row.lineNumber)").monospacedDigit().foregroundStyle(.tertiary).frame(width: 34, alignment: .trailing)
                    Text(row.day.short(withYear: true)).monospacedDigit().frame(width: 84, alignment: .leading)
                    Text(row.counterpartyName.isEmpty ? row.descriptionText : row.counterpartyName).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if row.isDuplicate { Text("al bekend").font(.caption).foregroundStyle(.secondary) }
                    Text(row.amount.formatted(symbol: false)).monospacedDigit().frame(width: 92, alignment: .trailing)
                }
                .font(.callout)
                .opacity(row.isDuplicate ? 0.5 : 1)
                .padding(.vertical, 4)
            }
            if all.count > shown.count {
                Text("… en nog \(all.count - shown.count)").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }
}

/// De kolomindeling is niet herkend: toon de eerste regels onbewerkt en zeg wat er aan de hand is.
struct ReviewRawFileSheet: View {
    @Environment(\.dismiss) private var dismiss
    let file: ReviewRawFile

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "questionmark.folder.fill").font(.title).foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("De indeling van dit bestand is niet herkend").font(.title3.weight(.semibold))
                    Text(file.fileName).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Text("De app vindt in dit bestand geen kolom met een datum en een kolom met een bedrag op de plek waar hij ze verwacht. Er is niets geïmporteerd. Gebruik het zip-bestand van je bank, of een los afschrift als CSV of PDF. Zelf kolommen aanwijzen kan in deze versie nog niet.")
                .fixedSize(horizontal: false, vertical: true)
            Text("De eerste regels van het bestand (\(file.columnCount) kolommen)").font(.headline)
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        ForEach(0..<max(file.columnCount, 1), id: \.self) { index in
                            Text("\(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(file.rows.enumerated()), id: \.offset) { _, fields in
                        GridRow {
                            ForEach(0..<max(file.columnCount, 1), id: \.self) { index in
                                Text(index < fields.count ? fields[index] : "").font(.callout.monospaced()).lineLimit(1)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: .infinity)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Spacer()
                Button("Sluiten") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 480)
    }
}
