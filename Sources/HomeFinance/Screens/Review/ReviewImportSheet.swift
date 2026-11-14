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
                fact("Al bekend", "\(part.knownCount)")
                    .help(part.knownBreakdown + ". Nieuw, al bekend en fout zijn samen alle regels in het bestand.")
                fact("Fout", "\(preview.errorCount)", color: preview.errorCount > 0 ? Theme.negative : nil)
                fact("Periode", period)
                fact("Beginsaldo", preview.openingBalance?.formatted() ?? "—")
                fact("Eindsaldo", preview.closingBalance?.formatted() ?? "—")
                Spacer(minLength: 0)
            }
            chain
            if let seam = preview.seam { ReviewSeamBlock(part: part, seam: seam) }
            ForEach(Array(preview.warnings.filter { $0.kind == .ibanMismatch }.enumerated()), id: \.offset) { _, warning in
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Theme.warning)
            }
            if !preview.errors.isEmpty { errors }
            DisclosureGroup(isExpanded: $expanded) {
                rows.padding(.top, 6)
            } label: {
                Text("Transacties in het bestand (\(preview.rowCount))" + (preview.errorCount > 0 ? " · \(preview.errorCount) fout, zie hierboven" : "")).font(.callout)
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
                    if let known = part.knownLabel(row) {
                        Text(known).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(row.amount.formatted(symbol: false)).monospacedDigit().frame(width: 92, alignment: .trailing)
                }
                .font(.callout)
                .opacity(row.isDuplicate || row.isBeforeCutover ? 0.5 : 1)
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

/// Eerste import van een rekening: sluit het bestand aan op de administratie (beginsaldo of Excel-historie)?
private struct ReviewSeamBlock: View {
    @Environment(ReviewStore.self) private var store
    let part: ReviewImportPart
    let seam: ImportSeam
    @State private var extra = 0

    private var preview: ImportPreview { part.preview }
    private var difference: Money? { store.seamDifference(preview) }
    private var admin: String { seam.soughtBalance?.formatted() ?? "—" }

    /// Zelf kiezen is nodig als het saldo niet gevonden is, er twijfel was, of de gebruiker al gekozen heeft.
    private var showsPicker: Bool {
        seam.method == .manual || seam.balanceNotFound || seam.isAmbiguous
            || (seam.method != .foundByBalance && seam.method != .alreadyProcessed)
    }
    private var fits: Bool {
        switch seam.method {
        case .foundByBalance, .alreadyProcessed: true
        default: difference?.isZero ?? false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(part.hasHistory ? "Aansluiting op je Excel-historie" : "Aansluiting op je beginsaldo").font(.callout.weight(.semibold))
            Label { Text(headline).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: fits ? "checkmark.seal.fill" : "xmark.seal.fill")
            }
            .foregroundStyle(fits ? Theme.positive : Theme.negative)
            if seam.isAmbiguous, seam.method != .manual {
                Text("Dit saldo komt op meer plekken in het bestand voor. Kijk hieronder of de goede regel is gekozen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if showsPicker { picker }
        }
        .font(.callout)
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background((fits ? Theme.positive : Theme.negative).opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .help("Bij de eerste import van een rekening zoekt de app de regel in het bankbestand waarvan het saldo vóór de mutatie gelijk is aan het saldo van je administratie. Alles daarvoor staat al in de app.")
    }

    private var headline: String {
        let skipped = seam.skippedCount
        let skippedText = skipped == 0 ? "" : " \(skipped) eerdere \(skipped == 1 ? "regel" : "regels") overgeslagen (\(part.hasHistory ? "die \(skipped == 1 ? "staat" : "staan") al in je Excel" : "die \(skipped == 1 ? "valt" : "vallen") vóór je beginsaldo"))."
        switch seam.method {
        case .alreadyProcessed:
            return "Alles in dit bestand staat al in je administratie."
        case .foundByBalance:
            return "Sluit aan: je administratie staat op \(admin); de bank gaat verder vanaf \(seam.day?.short(withYear: true) ?? "—"), regel \(seam.lineNumber.map(String.init) ?? "—").\(skippedText)"
        case .manual where fits:
            return preview.newCount == 0
                ? "Sluit aan met jouw keuze: alles in dit bestand staat al in je administratie."
                : "Sluit aan met jouw keuze: je administratie staat op \(admin); \(preview.newCount) \(preview.newCount == 1 ? "regel gaat" : "regels gaan") mee."
        default:
            return "Sluit niet aan: je administratie staat op \(admin), maar geen regel in dit bestand begint op dat saldo."
        }
    }

    private var picker: some View {
        let rows = preview.rowsChronological
        let center = min(part.seamCenter ?? 0, rows.count)
        let lower = max(0, center - 6 - extra), upper = min(rows.count, center + 6 + extra)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 22) {
                fact("Beginsaldo bestand", seam.fileOpeningBalance)
                fact("Eindsaldo bestand", seam.fileClosingBalance)
                Spacer()
                if let difference {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Verschil bij deze keuze").font(.caption).foregroundStyle(.secondary)
                        Text(difference.formatted(alwaysSign: !difference.isZero)).font(.body.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(difference.isZero ? Theme.positive : Theme.negative)
                    }
                    .help("Eindsaldo van het bestand min het saldo van je administratie en de aangevinkte regels. Bij € 0,00 sluit de overgang.")
                }
            }
            Text(part.hasHistory ? "Vink aan wat nog niet in je Excel staat. Wat uit staat, wordt niet geïmporteerd."
                                 : "Vink aan wat na je beginsaldo komt. Wat uit staat, wordt niet geïmporteerd.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                if lower > 0 { more("\(lower) eerdere \(lower == 1 ? "regel" : "regels") · toon meer") }
                ForEach(rows[lower..<upper]) { row in
                    Toggle(isOn: Binding(get: { !row.isBeforeCutover },
                                         set: { store.setIncluded($0, line: row.lineNumber, in: part.id) })) {
                        HStack(spacing: 10) {
                            Text("\(row.lineNumber)").foregroundStyle(.tertiary).frame(width: 34, alignment: .trailing)
                            Text(row.day.short(withYear: true)).frame(width: 84, alignment: .leading)
                            Text(row.counterpartyName.isEmpty ? row.descriptionText : row.counterpartyName).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if row.isDuplicate { Text("al geïmporteerd").font(.caption).foregroundStyle(.secondary) }
                            Text(row.amount.formatted(symbol: false)).frame(width: 84, alignment: .trailing)
                            Text(row.balanceBefore?.formatted(symbol: false) ?? "").foregroundStyle(.secondary)
                                .frame(width: 92, alignment: .trailing)
                                .help("Saldo vóór deze regel volgens de bank")
                        }
                        .monospacedDigit()
                    }
                    .toggleStyle(.checkbox)
                    .disabled(row.isDuplicate)
                    .padding(.vertical, 3)
                }
                if upper < rows.count { more("\(rows.count - upper) latere \(rows.count - upper == 1 ? "regel" : "regels") gaan mee · toon meer") }
            }
            .foregroundStyle(Color.primary)
        }
    }

    private func fact(_ title: String, _ value: Money?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value?.formatted() ?? "—").font(.body.weight(.medium)).monospacedDigit().foregroundStyle(Color.primary)
        }
    }

    private func more(_ title: String) -> some View {
        Button(title) { extra += 10 }.buttonStyle(.link).font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
    }
}
