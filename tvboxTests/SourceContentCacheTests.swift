import Testing
import Foundation
@testable import TVBox

@Suite("Source content cache")
struct SourceContentCacheTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceContentCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeSource(api: String = "https://example.com/api.php/provide/vod") -> SourceBean {
        SourceBean(key: "demo", name: "Demo", api: api, type: 1)
    }

    private func makeContent(videoID: String = "1") -> SourceHomeContent {
        SourceHomeContent(
            sorts: [MovieSort.SortData(id: "movie", name: "Movie")],
            homeVideos: [Movie.Video(id: videoID, name: "Video")]
        )
    }

    @Test("Fresh home values round trip through disk")
    func freshHomeRoundTrip() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = makeSource()
        let content = makeContent()

        let writer = SourceContentCache(directory: directory)
        await writer.storeHome(content, for: source)
        let reader = SourceContentCache(directory: directory)
        let cached = await reader.cachedHome(for: source)

        #expect(cached?.isFresh == true)
        #expect(cached?.value.sorts.map(\.id) == ["movie"])
        #expect(cached?.value.homeVideos.map(\.id) == ["1"])
    }

    @Test("Expired home content remains available for immediate display")
    func expiredHomeIsReturnedAsStale() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = makeSource()
        let cache = SourceContentCache(directory: directory, homeTTL: -1)
        await cache.storeHome(makeContent(), for: source)

        let cached = await cache.cachedHome(for: source)
        #expect(cached?.isFresh == false)
        #expect(cached?.value.homeVideos.count == 1)
    }

    @Test("Source identity includes API address")
    func sourceAddressChangeDoesNotReuseContent() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SourceContentCache(directory: directory)
        await cache.storeHome(makeContent(), for: makeSource())

        let cached = await cache.cachedHome(for: makeSource(api: "https://other.example.com/vod"))
        #expect(cached == nil)
    }

    @Test("List cache normalizes filters and isolates pages")
    func listCacheUsesStableKeys() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = makeSource()
        let sort = MovieSort.SortData(id: "movie", name: "Movie")
        let cache = SourceContentCache(directory: directory)
        let videos = [Movie.Video(id: "page-1")]
        await cache.storeList(
            videos,
            for: source,
            sortID: sort.id,
            page: 1,
            filters: ["year": "2026", "area": "all"]
        )

        let matched = await cache.cachedList(
            for: source,
            sortID: sort.id,
            page: 1,
            filters: ["area": "all", "year": "2026"]
        )
        let otherPage = await cache.cachedList(for: source, sortID: sort.id, page: 2)
        #expect(matched?.value.map(\.id) == ["page-1"])
        #expect(otherPage == nil)
    }

    @Test("Clear removes memory and persisted entries")
    func clearRemovesEntries() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = makeSource()
        let cache = SourceContentCache(directory: directory)
        await cache.storeHome(makeContent(), for: source)
        await cache.removeAll()

        let memoryValue = await cache.cachedHome(for: source)
        #expect(memoryValue == nil)
        let reader = SourceContentCache(directory: directory)
        let persistedValue = await reader.cachedHome(for: source)
        #expect(persistedValue == nil)
    }

    @Test("Only HTTP type 3 sources receive the JSON fallback")
    func type3FallbackScope() {
        #expect(SourceBean(key: "json", api: "https://example.com/vod", type: 3).isSupportedInSwift)
        #expect(!SourceBean(key: "jar", api: "csp_Demo", type: 3).isSupportedInSwift)
        #expect(!SourceBean(key: "js", api: "./js/demo.js", type: 3).isSupportedInSwift)
    }
}


@Suite("Progressive image loading")
struct ImageLoadWindowTests {
    @Test("Only the first eight images are enabled initially")
    func initialWindow() {
        let window = ImageLoadWindow()
        #expect(window.allowsImage(at: 0))
        #expect(window.allowsImage(at: 7))
        #expect(!window.allowsImage(at: 8))
        #expect(!window.allowsImage(at: 100))
    }

    @Test("Appearing items reveal only the next small batch")
    func revealNextBatch() {
        var window = ImageLoadWindow()
        window.reveal(index: 8)
        #expect(window.allowsImage(at: 8))
        #expect(window.allowsImage(at: 11))
        #expect(!window.allowsImage(at: 12))
    }

    @Test("Changing a channel resets the image window")
    func resetWindow() {
        var window = ImageLoadWindow()
        window.reveal(index: 40)
        #expect(window.allowsImage(at: 40))
        window.reset()
        #expect(!window.allowsImage(at: 40))
        #expect(window.allowsImage(at: 0))
    }
}

private actor ImageConcurrencyProbe {
    private var active = 0
    private(set) var maximum = 0

    func enter() {
        active += 1
        maximum = max(maximum, active)
    }

    func leave() {
        active -= 1
    }
}

@Suite("Image load concurrency")
struct ImageLoadLimiterTests {
    @Test("At most four image loads run concurrently")
    func concurrencyLimit() async {
        let probe = ImageConcurrencyProbe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await ImageLoadLimiter.shared.acquire()
                    await probe.enter()
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    await probe.leave()
                    await ImageLoadLimiter.shared.release()
                }
            }
        }
        let maximum = await probe.maximum
        #expect(maximum <= 4)
        #expect(maximum > 0)
    }
}


@Suite("Player engine defaults")
struct PlayerEngineDefaultsTests {
    @Test("System player is the safe default and invalid values fall back to it")
    func systemPlayerIsDefault() {
        #expect(PlayerEngine.defaultEngine == .system)
        #expect(PlayerEngine.fromStoredValue(-1) == .system)
    }
}
