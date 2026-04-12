import SwiftUI
import SwiftData
#if canImport(GoogleMobileAds)
import GoogleMobileAds
#endif

enum TaxSuitePersistence {
    static let schema = Schema([
        ExpenseItem.self,
        RecurringExpense.self,
        IncomeItem.self
    ])

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

@main
struct TaxSuiteApp: App {
    init() {
#if canImport(GoogleMobileAds)
        MobileAds.shared.start(completionHandler: nil)
#endif
    }

    var sharedModelContainer: ModelContainer = {
        do {
            return try TaxSuitePersistence.makeContainer()
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
