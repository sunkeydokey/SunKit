/// A typed fetch declaration for next-page-only infinite queries.
///
/// `InfiniteQuery` stores all loaded pages under one base cache identity. Values
/// that change the returned page sequence, such as filters, auth scope, locale,
/// or endpoint, must be included in the key.
public struct InfiniteQuery<PageParam: Sendable, Page: Sendable>: Sendable {
    /// The cache identity for the accumulated infinite data.
    public let key: QueryKey<InfiniteData<PageParam, Page>>

    /// Query execution options, or `nil` to use the executing client's defaults.
    public let options: QueryOptions?

    /// The page parameter used when loading or refetching the first page.
    public let initialPageParam: PageParam

    /// The maximum number of pages to keep, or `nil` to keep every loaded page.
    public let maxPages: Int?

    /// Returns the next page parameter from the current accumulated pages.
    ///
    /// Return `nil` when no next page is available.
    public let getNextPageParam: @Sendable (Page, [Page]) -> PageParam?

    internal let fetchPage: @Sendable (PageParam) async throws -> Page

    /// Creates an infinite query from key parts and an async page fetcher.
    ///
    /// - Parameters:
    ///   - key: The base cache identity parts for the full page sequence.
    ///   - initialPageParam: The page parameter used for the first page.
    ///   - options: Execution options for page fetches, or `nil` to use the
    ///     executing client's defaults.
    ///   - maxPages: The maximum number of pages to keep, or `nil` to keep all
    ///     loaded pages. When the limit is exceeded by a next-page fetch, the
    ///     oldest pages are dropped.
    ///   - getNextPageParam: Returns the next page parameter, or `nil` when
    ///     the loaded pages are complete.
    ///   - fetchPage: The async operation that loads one page.
    public init(
        key: [AnyQueryKeyPart],
        initialPageParam: PageParam,
        options: QueryOptions? = nil,
        maxPages: Int? = nil,
        getNextPageParam: @escaping @Sendable (Page, [Page]) -> PageParam?,
        fetchPage: @escaping @Sendable (PageParam) async throws -> Page
    ) {
        precondition(maxPages == nil || maxPages! > 0, "maxPages must be greater than zero")
        self.key = QueryKey(key)
        self.initialPageParam = initialPageParam
        self.options = options
        self.maxPages = maxPages
        self.getNextPageParam = getNextPageParam
        self.fetchPage = fetchPage
    }

    /// Creates an infinite query from a typed key and an async page fetcher.
    ///
    /// - Parameters:
    ///   - key: The typed cache identity for the full page sequence.
    ///   - initialPageParam: The page parameter used for the first page.
    ///   - options: Execution options for page fetches, or `nil` to use the
    ///     executing client's defaults.
    ///   - maxPages: The maximum number of pages to keep, or `nil` to keep all
    ///     loaded pages. When the limit is exceeded by a next-page fetch, the
    ///     oldest pages are dropped.
    ///   - getNextPageParam: Returns the next page parameter, or `nil` when
    ///     the loaded pages are complete.
    ///   - fetchPage: The async operation that loads one page.
    public init(
        key: QueryKey<InfiniteData<PageParam, Page>>,
        initialPageParam: PageParam,
        options: QueryOptions? = nil,
        maxPages: Int? = nil,
        getNextPageParam: @escaping @Sendable (Page, [Page]) -> PageParam?,
        fetchPage: @escaping @Sendable (PageParam) async throws -> Page
    ) {
        precondition(maxPages == nil || maxPages! > 0, "maxPages must be greater than zero")
        self.key = key
        self.initialPageParam = initialPageParam
        self.options = options
        self.maxPages = maxPages
        self.getNextPageParam = getNextPageParam
        self.fetchPage = fetchPage
    }
}
