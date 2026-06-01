/// Accumulated page data for an infinite query.
///
/// `InfiniteData` stores fetched pages in display order together with the page
/// parameters that produced them. SunKit's infinite-query model appends next
/// pages and can evict older pages when ``InfiniteQuery/maxPages`` is set; it
/// does not prepend pages.
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
