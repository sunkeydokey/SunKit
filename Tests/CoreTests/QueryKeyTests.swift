import Testing
@testable import SunKit

@Test func queryKeyEqualityIncludesPartValue() {
    let first = QueryKey<String>("project", 1)
    let second = QueryKey<String>("project", 1)
    let third = QueryKey<String>("project", 2)

    #expect(first == second)
    #expect(first != third)
}

@Test func queryKeyEqualityIncludesPartType() {
    let stringID = QueryKey<String>("project", "1")
    let intID = QueryKey<String>("project", 1)

    #expect(stringID != intID)
}

@Test func anyQueryKeySupportsPrefixMatching() {
    let key = AnyQueryKey("projects", 1, "comments")

    #expect(key.starts(with: AnyQueryKey("projects")))
    #expect(key.starts(with: AnyQueryKey("projects", 1)))
    #expect(!key.starts(with: AnyQueryKey("projects", 2)))
    #expect(!key.starts(with: AnyQueryKey("project")))
    #expect(!AnyQueryKey("projects").starts(with: key))
}

@Test func queryKeyCanBeBuiltFromErasedParts() {
    let parts: [AnyQueryKeyPart] = [
        AnyQueryKeyPart("projects"),
        AnyQueryKeyPart(1),
    ]

    let key = QueryKey<String>(parts)

    #expect(key.rawValue == AnyQueryKey("projects", 1))
}
