import SwiftUI
import SunKit
import SunKitSwiftUI

@main
struct SunKitExampleApp: App {
  private let client = QueryClient(
    defaultQueryOptions: QueryOptions(),
    defaultCacheOptions: QueryCacheOptions(staleTime: 10)
  )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .queryClient(client)
        }
    }
}
