import SwiftUI
import SwiftData

@main
struct TaxSuiteApp: App {
    var sharedModelContainer: ModelContainer = {
        // 🌟 IncomeItem (売上) を追加！
        let schema = Schema([
            ExpenseItem.self,
            RecurringExpense.self,
            IncomeItem.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
