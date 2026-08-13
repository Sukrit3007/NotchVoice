import Foundation
import SwiftData

/// The SwiftData container, and whether it is the real one.
///
/// A store that cannot be opened must not stop the app dictating — it worked for
/// months with no store at all, and losing history is a smaller failure than
/// losing the hotkey. So a failure here degrades to an in-memory container and
/// says so, rather than trapping on `try!`.
///
/// `isEphemeral` is carried alongside rather than inferred, because "history is
/// empty" and "history is broken" look identical from the UI, and that is
/// exactly the ambiguity this app keeps refusing to ship.
struct DataStack: Sendable {

    let container: ModelContainer
    let isEphemeral: Bool

    static let schema = Schema([
        Capture.self,
        DictionaryEntry.self,
        Snippet.self,
    ])

    static let shared: DataStack = make()

    static func make() -> DataStack {
        do {
            try AppPaths.ensure(AppPaths.support)
            let configuration = ModelConfiguration(
                schema: schema,
                url: AppPaths.history
            )
            let container = try ModelContainer(for: schema, configurations: configuration)
            Log.data.info("Store opened at \(AppPaths.history.path, privacy: .public)")
            return DataStack(container: container, isEphemeral: false)
        } catch {
            Log.data.error(
                "Store could not be opened, history is this-launch-only: \(error.localizedDescription, privacy: .public)")
            return DataStack(container: memoryOnly(), isEphemeral: true)
        }
    }

    /// Last resort. If even an in-memory container cannot be built, the schema
    /// itself is wrong — a programmer error, not a runtime condition, and the
    /// trap is the correct outcome.
    private static func memoryOnly() -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: configuration)
    }

    /// A throwaway store for tests.
    static func inMemory() throws -> DataStack {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return DataStack(
            container: try ModelContainer(for: schema, configurations: configuration),
            isEphemeral: true
        )
    }
}
