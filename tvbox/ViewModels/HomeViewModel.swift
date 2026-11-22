import Foundation
import SwiftUI
import Combine

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var sorts: [MovieSort.SortData] = []
    @Published var selectedSort: MovieSort.SortData?
    @Published var homeVideos: [Movie.Video] = []
    @Published var categoryVideos: [Movie.Video] = []
    @Published var currentPage = 1
    @Published var hasMore = true
    @Published var errorMessage: String?

    @Published private(set) var currentSource: SourceBean?
    @Published private var isSourceLoading = false
    @Published private var isCategoryLoading = false
    @Published private var isSourceRefreshing = false
    @Published private var isCategoryRefreshing = false
    @Published private(set) var isLoadingMore = false

    var isLoading: Bool { isSourceLoading || isCategoryLoading }
    var isRefreshing: Bool { isSourceRefreshing || isCategoryRefreshing }

    private let sourceService = SourceService.shared
    private var sourceTask: Task<Void, Never>?
    private var categoryTask: Task<Void, Never>?
    private var sourceRequestID = UUID()
    private var categoryRequestID = UUID()
    private var lastLoadFailedDueToNetwork = false
    private var networkRestoredCancellable: AnyCancellable?

    init() {
        setupNetworkRestoredAutoRetry()
    }

    func loadSorts() async {
        guard let source = ApiConfig.shared.homeSourceBean else { return }
        switchSource(source)
        await sourceTask?.value
    }

    func switchSource(_ source: SourceBean) {
        if currentSource?.cacheIdentifier == source.cacheIdentifier,
           !sorts.isEmpty || isSourceLoading {
            return
        }

        sourceTask?.cancel()
        categoryTask?.cancel()
        sourceRequestID = UUID()
        categoryRequestID = UUID()
        currentSource = source

        sorts = []
        selectedSort = nil
        homeVideos = []
        categoryVideos = []
        currentPage = 1
        hasMore = true
        errorMessage = nil
        isSourceLoading = true
        isCategoryLoading = false
        isLoadingMore = false
        isSourceRefreshing = false
        isCategoryRefreshing = false

        let requestID = sourceRequestID
        sourceTask = Task { [weak self] in
            guard let self else { return }
            await self.loadSource(source, requestID: requestID, forceRefresh: false)
        }
    }

    private func loadSource(
        _ source: SourceBean,
        requestID: UUID,
        forceRefresh: Bool
    ) async {
        isSourceLoading = sorts.isEmpty
        isSourceRefreshing = !sorts.isEmpty
        defer {
            if sourceRequestID == requestID, currentSource?.cacheIdentifier == source.cacheIdentifier {
                isSourceLoading = false
                isSourceRefreshing = false
            }
        }

        if !forceRefresh,
           let cached = await sourceService.cachedSort(sourceBean: source) {
            guard isCurrentSource(source, requestID: requestID) else { return }
            applyHomeContent(cached.value)
            isSourceLoading = false
            isSourceRefreshing = true
            lastLoadFailedDueToNetwork = false
            if cached.isFresh { return }
        }

        do {
            let result = try await sourceService.getSort(
                sourceBean: source,
                forceRefresh: forceRefresh
            )
            guard isCurrentSource(source, requestID: requestID) else { return }
            applyHomeContent(SourceHomeContent(sorts: result.sorts, homeVideos: result.homeVideos))
            lastLoadFailedDueToNetwork = false
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentSource(source, requestID: requestID) else { return }
            lastLoadFailedDueToNetwork = error.isNetworkConnectionError
            if sorts.isEmpty && homeVideos.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyHomeContent(_ content: SourceHomeContent) {
        let previousSortID = selectedSort?.id
        var allSorts = [MovieSort.SortData.home()]
        allSorts.append(contentsOf: content.sorts)
        sorts = allSorts
        homeVideos = content.homeVideos
        if let previousSortID,
           let matched = allSorts.first(where: { $0.id == previousSortID }) {
            selectedSort = matched
        } else {
            selectedSort = allSorts.first
        }
    }

    func selectSort(_ sort: MovieSort.SortData) {
        guard selectedSort?.id != sort.id,
              let source = currentSource,
              sorts.contains(where: { $0.id == sort.id }) else { return }

        categoryTask?.cancel()
        categoryRequestID = UUID()
        selectedSort = sort
        errorMessage = nil
        categoryVideos = []
        currentPage = 1
        hasMore = sort.id != "home"
        isCategoryLoading = sort.id != "home"
        isCategoryRefreshing = false
        isLoadingMore = false

        guard sort.id != "home" else { return }
        let requestID = categoryRequestID
        categoryTask = Task { [weak self] in
            guard let self else { return }
            await self.loadCategory(
                page: 1,
                sort: sort,
                source: source,
                requestID: requestID,
                forceRefresh: false
            )
        }
    }

    private func loadCategory(
        page: Int,
        sort: MovieSort.SortData,
        source: SourceBean,
        requestID: UUID,
        forceRefresh: Bool
    ) async {
        guard sort.id != "home" else { return }
        if page == 1 {
            isCategoryLoading = categoryVideos.isEmpty
            isCategoryRefreshing = !categoryVideos.isEmpty
        } else {
            isLoadingMore = true
        }
        defer {
            if isCurrentCategory(sort, source: source, requestID: requestID) {
                isCategoryLoading = false
                isCategoryRefreshing = false
                isLoadingMore = false
            }
        }

        if page == 1, !forceRefresh,
           let cached = await sourceService.cachedList(
            sourceBean: source,
            sortData: sort,
            page: page
           ) {
            guard isCurrentCategory(sort, source: source, requestID: requestID) else { return }
            categoryVideos = cached.value
            currentPage = page
            hasMore = !cached.value.isEmpty
            isCategoryLoading = false
            isCategoryRefreshing = true
            lastLoadFailedDueToNetwork = false
            if cached.isFresh { return }
        }

        do {
            let videos = try await sourceService.getList(
                sourceBean: source,
                sortData: sort,
                page: page,
                forceRefresh: forceRefresh
            )
            guard isCurrentCategory(sort, source: source, requestID: requestID) else { return }

            if page == 1 {
                categoryVideos = videos
            } else {
                let existingIDs = Set(categoryVideos.map(\.id))
                categoryVideos.append(contentsOf: videos.filter { !existingIDs.contains($0.id) })
            }
            currentPage = page
            hasMore = !videos.isEmpty
            errorMessage = nil
            lastLoadFailedDueToNetwork = false
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentCategory(sort, source: source, requestID: requestID) else { return }
            lastLoadFailedDueToNetwork = error.isNetworkConnectionError
            if categoryVideos.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadMore() async {
        guard let lastItem = categoryVideos.last else { return }
        await loadMoreIfNeeded(currentItem: lastItem)
    }

    func loadMoreIfNeeded(currentItem: Movie.Video) async {
        guard selectedSort?.id != "home",
              hasMore,
              !isCategoryLoading,
              !isLoadingMore,
              categoryVideos.last?.id == currentItem.id,
              let sort = selectedSort,
              let source = currentSource else { return }

        await loadCategory(
            page: currentPage + 1,
            sort: sort,
            source: source,
            requestID: categoryRequestID,
            forceRefresh: false
        )
    }

    func refresh() async {
        guard let source = currentSource ?? ApiConfig.shared.homeSourceBean else { return }
        sourceTask?.cancel()
        categoryTask?.cancel()
        sourceRequestID = UUID()
        categoryRequestID = UUID()
        currentSource = source
        errorMessage = nil

        await loadSource(source, requestID: sourceRequestID, forceRefresh: true)
        guard currentSource?.cacheIdentifier == source.cacheIdentifier,
              let sort = selectedSort,
              sort.id != "home" else { return }
        await loadCategory(
            page: 1,
            sort: sort,
            source: source,
            requestID: categoryRequestID,
            forceRefresh: true
        )
    }

    private func isCurrentSource(_ source: SourceBean, requestID: UUID) -> Bool {
        sourceRequestID == requestID && currentSource?.cacheIdentifier == source.cacheIdentifier
    }

    private func isCurrentCategory(
        _ sort: MovieSort.SortData,
        source: SourceBean,
        requestID: UUID
    ) -> Bool {
        categoryRequestID == requestID
            && selectedSort?.id == sort.id
            && currentSource?.cacheIdentifier == source.cacheIdentifier
    }

    private func setupNetworkRestoredAutoRetry() {
        networkRestoredCancellable = NetworkMonitor.shared.networkRestoredPublisher
            .sink { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.lastLoadFailedDueToNetwork || (self.sorts.isEmpty && self.homeVideos.isEmpty) else { return }
                    await self.refresh()
                }
            }
    }
}
