import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    QueryExampleScreen()
                } label: {
                    Label("Query", systemImage: "person.2")
                }

                NavigationLink {
                    PaginatedQueryExampleScreen()
                } label: {
                    Label("Paginated Query", systemImage: "doc.text")
                }

                NavigationLink {
                    InfiniteQueryExampleScreen()
                } label: {
                    Label("Infinite Query", systemImage: "arrow.down.to.line")
                }

                NavigationLink {
                    MutationExampleScreen()
                } label: {
                    Label("Mutation", systemImage: "square.and.pencil")
                }

                NavigationLink {
                    QueryInvalidationExampleScreen()
                } label: {
                    Label("Query Invalidation", systemImage: "arrow.clockwise.circle")
                }
            }
            .navigationTitle("SunKit")
        }
    }
}

#Preview {
    ContentView()
}
