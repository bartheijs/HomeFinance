import Testing
import HFCore
@testable import HFInsight

@Suite struct ItemPickerOrderTests {
    private func item(_ id: Int64, _ label: String, _ direction: Direction) -> BudgetItem {
        BudgetItem(id: id, yearId: 1, label: label, direction: direction, planAmount: .zero, sortOrder: Int(id))
    }

    @Test func expensesFirstThenIncomeEachAlphabetical() {
        let items = [
            item(1, "Zorgverzekering", .UIT), item(2, "salaris", .IN), item(3, "Boodschappen", .UIT),
            item(4, "Kinderbijslag", .IN), item(5, "energie", .UIT),
        ]
        #expect(Insight.itemPickerOrder(items).map(\.label)
                == ["Boodschappen", "energie", "Zorgverzekering", "Kinderbijslag", "salaris"])
    }

    @Test func ignoresCaseAccentsAndSortsNumbersAsNumbers() {
        let items = [item(1, "Verzekering 10", .UIT), item(2, "verzekering 2", .UIT), item(3, "École", .UIT),
                     item(4, "eten", .UIT), item(5, "Abonnement", .UIT)]
        #expect(Insight.itemPickerOrder(items).map(\.label)
                == ["Abonnement", "École", "eten", "verzekering 2", "Verzekering 10"])
    }

    @Test func reservationLinesGoLast() {
        let items = [item(1, "Auto", .RES), item(2, "Huur", .UIT), item(3, "Loon", .IN)]
        #expect(Insight.itemPickerOrder(items).map(\.label) == ["Huur", "Loon", "Auto"])
    }

    @Test func equalLabelsKeepTheirOriginalOrder() {
        let items = [item(9, "Huur", .UIT), item(4, "Huur", .UIT), item(6, "Huur", .UIT)]
        #expect(Insight.itemPickerOrder(items).map(\.id) == [9, 4, 6])
    }

    @Test func filteringPerDirectionKeepsTheAlphabet() {
        let items = Insight.itemPickerOrder([item(1, "Water", .UIT), item(2, "Bonus", .IN), item(3, "Afval", .UIT),
                                             item(4, "Aanvulling", .IN)])
        #expect(items.filter { $0.direction == .UIT }.map(\.label) == ["Afval", "Water"])
        #expect(items.filter { $0.direction == .IN }.map(\.label) == ["Aanvulling", "Bonus"])
    }
}
