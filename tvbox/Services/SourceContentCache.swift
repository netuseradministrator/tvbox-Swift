import Foundation
import CryptoKit

struct SourceHomeContent: Codable {
    let sorts: [MovieSort.SortData]
    let homeVideos: [Movie.Video]
}

struct CachedSourceValue<Value> {
    let value: Value
    let isFresh: Bool
}

actor SourceContentCache {
    static let shared = SourceContentCache()

    private struct Envelope<Value: Codable>: Codable {
        let value: Value
        let storedAt: Date
    }

    private let directory: URL
    private let homeTTL: TimeInterval
    private let listTTL: TimeInterval
    private var homeMemory: [String: Envelope<SourceHomeContent>] = [:]
    private var listMemory: [String: Envelope<[Movie.Video]>] = [:]

    init(
        directory: URL? = nil,
        homeTTL: TimeInterval = 30 * 60,
        listTTL: TimeInterval = 10 * 60
    ) {
        self.directory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SourceContent", isDirectory: true)
        self.homeTTL = homeTTL
        self.listTTL = listTTL
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func cachedHome(for source: SourceBean) -> CachedSourceValue<SourceHomeContent>? {
        let key = cacheKey("home|\(source.cacheIdentifier)")
        let envelope: Envelope<SourceHomeContent>?
        if let memory = homeMemory[key] {
            envelope = memory
        } else {
            envelope = load(key: key)
            homeMemory[key] = envelope
        }
        guard let envelope else { return nil }
        return CachedSourceValue(
            value: envelope.value,
            isFresh: Date().timeIntervalSince(envelope.storedAt) < homeTTL
        )
    }

    func storeHome(_ content: SourceHomeContent, for source: SourceBean) {
        let key = cacheKey("home|\(source.cacheIdentifier)")
        let envelope = Envelope(value: content, storedAt: Date())
        homeMemory[key] = envelope
        persist(envelope, key: key)
    }

    func cachedList(
        for source: SourceBean,
        sortID: String,
        page: Int,
        filters: [String: String]? = nil
    ) -> CachedSourceValue<[Movie.Video]>? {
        let key = cacheKey(listIdentifier(source: source, sortID: sortID, page: page, filters: filters))
        let envelope: Envelope<[Movie.Video]>?
        if let memory = listMemory[key] {
            envelope = memory
        } else {
            envelope = load(key: key)
            listMemory[key] = envelope
        }
        guard let envelope else { return nil }
        return CachedSourceValue(
            value: envelope.value,
            isFresh: Date().timeIntervalSince(envelope.storedAt) < listTTL
        )
    }

    func storeList(
        _ videos: [Movie.Video],
        for source: SourceBean,
        sortID: String,
        page: Int,
        filters: [String: String]? = nil
    ) {
        let key = cacheKey(listIdentifier(source: source, sortID: sortID, page: page, filters: filters))
        let envelope = Envelope(value: videos, storedAt: Date())
        listMemory[key] = envelope
        persist(envelope, key: key)
    }

    func removeAll() {
        homeMemory.removeAll()
        listMemory.removeAll()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func listIdentifier(
        source: SourceBean,
        sortID: String,
        page: Int,
        filters: [String: String]?
    ) -> String {
        let filterIdentifier = (filters ?? [:])
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        return "list|\(source.cacheIdentifier)|\(sortID)|\(page)|\(filterIdentifier)"
    }

    private func cacheKey(_ identifier: String) -> String {
        let digest = SHA256.hash(data: Data(identifier.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".json"
    }

    private func load<Value: Codable>(key: String) -> Envelope<Value>? {
        let file = directory.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Envelope<Value>.self, from: data)
    }

    private func persist<Value: Codable>(_ envelope: Envelope<Value>, key: String) {
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: directory.appendingPathComponent(key), options: .atomic)
    }
}

extension SourceBean {
    var cacheIdentifier: String {
        "\(key)|\(type)|\(api)|\(ext ?? "")"
    }
}
