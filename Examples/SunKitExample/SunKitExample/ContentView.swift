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
                    ParallelQueriesBindingModifierExampleScreen()
                } label: {
                    Label("Parallel Queries", systemImage: "rectangle.stack")
                }

                NavigationLink {
                    SelectExampleScreen()
                } label: {
                    Label("Select", systemImage: "line.3.horizontal.decrease.circle")
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

                NavigationLink {
                    EnabledExampleScreen()
                } label: {
                    Label("Enabled", systemImage: "switch.2")
                }
            }
            .navigationTitle("SunKit")
        }
    }
}

#Preview {
    ContentView()
}
