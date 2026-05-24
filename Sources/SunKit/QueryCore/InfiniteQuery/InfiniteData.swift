/// Accumulated page data for an infinite query.
///
/// `InfiniteData` stores fetched pages in display order together with the page
/// parameters that produced them. SunKit's MVP infinite-query model only
/// appends next pages; it does not evict, reverse, or prepend pages.
public struct InfiniteData<PageParam: Sendable, Page: Sendable>: Sendable {
    /// The fetched pages in append order.
    public let pages: [Page]

    /// The page parameters used to fetch `pages`.
    public let pageParams: [PageParam]

    /// Creates accumulated infinite query data.
    ///
    /// - Parameters:
    ///   - pages: The fetched pages in append order.
    ///   - pageParams: The page parameters used to fetch `pages`.
    public init(pages: [Page], pageParams: [PageParam]) {
        self.pages = pages
        self.pageParams = pageParams
    }
}
