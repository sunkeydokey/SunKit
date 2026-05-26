import SwiftUI
import SunKit

private struct QueryClientKey: EnvironmentKey {
    static let defaultValue: QueryClient? = nil
}

extension EnvironmentValues {
    /// The query client used by SunKit SwiftUI views in this environment.
    ///
    /// This value must be provided with ``View/queryClient(_:)`` near the app
    /// or scene root. Reading it without a configured client is a programming
    /// error and terminates with `fatalError`.
    public var queryClient: QueryClient {
        get {
            guard let client = self[QueryClientKey.self] else {
                fatalError(
                    "SunKitSwiftUI requires a QueryClient in the SwiftUI environment. " +
                    "Add `.queryClient(QueryClient(...))` near your app or scene root " +
                    "before using SunKit query modifiers or @Environment(\\.queryClient)."
                )
            }
            return client
        }
        set { self[QueryClientKey.self] = newValue }
    }

    var isQueryClientConfigured: Bool {
        self[QueryClientKey.self] != nil
    }
}

extension View {
    /// Sets the query client used by SunKit SwiftUI views in this view hierarchy.
    ///
    /// Use this modifier near the root of an app or scene so child query views
    /// share the same cache scope.
    public func queryClient(_ client: QueryClient) -> some View {
        environment(\.queryClient, client)
    }
}
