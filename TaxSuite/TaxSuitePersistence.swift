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

    /// iCloud が利用できない場合のフォールバック（ローカルのみ、データは保持）
    static func makeContainerLocalOnly() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
