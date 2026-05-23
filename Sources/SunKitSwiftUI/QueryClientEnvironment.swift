import SwiftUI
import SunKit

private struct QueryClientKey: EnvironmentKey {
    static let defaultValue = QueryClient()
}

extension EnvironmentValues {
    /// The query client used by SunKit SwiftUI views in this environment.
    public var queryClient: QueryClient {
        get { self[QueryClientKey.self] }
        set { self[QueryClientKey.self] = newValue }
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
