import SwiftData

enum TaxSuitePersistence {
    static let schema = Schema([
        ExpenseItem.self,
        RecurringExpense.self,
        IncomeItem.self,
        LocationTrigger.self
    ])

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: inMemory ? .none : .automatic
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
