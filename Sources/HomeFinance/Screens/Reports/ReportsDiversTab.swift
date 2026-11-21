import SwiftUI
import Charts
import HFCore
import HFInsight

/// Rapport Diverse uitgaven: waar gingen de uitgaven zonder vaste post naartoe?
struct ReportsDiversTab: View {
    let data: ReportsData
    let year: Int
    @Binding var month: Int?

    private var buckets: [DiversTagBucket] { data.divers?.buckets ?? [] }
    private var total: Money { data.divers?.total ?? .zero }
    private var period: String { ReportsFormat.period(year: year, month: month) }
    /// Ruimte rechts van de langste staaf voor het bedrag.
    private var axisEnd: Double { (buckets.map { $0.total.magnitude.doubleValue }.max() ?? 1) * 1.3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ReportsQuestion("Waar gingen de overige uitgaven naartoe?",
                            detail: "Overig: boekingen die bij geen enkele post horen. In \(period): \(total.magnitude.formatted()).")
            if buckets.isEmpty {
                Label("Geen overige uitgaven in \(period). Kies een andere maand of het hele jaar.", systemImage: "tray")
                    .font(.title3).foregroundStyle(.secondary).padding(.vertical, 24)
            } else {
                chart.frame(height: CGFloat(buckets.count) * 58 + 10).frame(maxWidth: 860)
                ReportsDisclosure("Toon de \(data.topDivers.count) grootste uitgaven") {
                    ReportsEntryList(entries: data.topDivers, ranked: true, showTags: true).frame(maxWidth: 860)
                }
            }
        }
    }

    private var chart: some View {
        Chart(buckets) { bucket in
            BarMark(x: .value("Bedrag", bucket.total.magnitude.doubleValue), y: .value("Tag", bucket.name), height: .ratio(0.55))
                .foregroundStyle(bucket.tagId == nil ? ReportsColor.neutral.opacity(0.6) : ReportsColor.accent)
                .cornerRadius(5)
                .annotation(position: .trailing, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(bucket.total.magnitude.formatted()).monospacedDigit()
                        Text("\(ReportsFormat.share(bucket.total, of: total)) · \(bucket.count)×").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
        }
        .chartXScale(domain: 0...axisEnd)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { _ in AxisValueLabel().font(.body).foregroundStyle(Color.primary) }
        }
        .help("Zonder tag: overige uitgaven die nog geen tag hebben. Een uitgave met twee tags telt bij beide mee.")
    }
}
