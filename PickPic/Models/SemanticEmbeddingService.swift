import Accelerate
import CoreML
import Photos
import SQLite3
import UIKit

struct SemanticEmbeddingMatch {
    let assetID: String
    let score: Float
}

struct SemanticSearchProgress: Equatable, Sendable {
    enum Phase: Hashable, Sendable {
        case understanding
        case comparing
        case ranking
    }

    let phase: Phase
    let completed: Int
    let total: Int
}

enum SemanticIndexQuality: Int, Codable, Sendable {
    case thumbnail = 0
    case refined = 1
}

struct SemanticAssetSnapshot: Sendable {
    let id: String
    let modifiedAt: TimeInterval?
}

actor SemanticEmbeddingService {
    private struct IndexDocument: Codable {
        let version: Int
        let model: String
        var entries: [String: IndexEntry]
    }

    fileprivate struct IndexEntry: Codable {
        let modifiedAt: TimeInterval?
        let quality: SemanticIndexQuality
        let vector: [Float]

        private enum CodingKeys: String, CodingKey {
            case modifiedAt
            case quality
            case vector
        }

        init(modifiedAt: TimeInterval?, quality: SemanticIndexQuality, vector: [Float]) {
            self.modifiedAt = modifiedAt
            self.quality = quality
            self.vector = vector
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            modifiedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .modifiedAt)
            quality = try container.decodeIfPresent(SemanticIndexQuality.self, forKey: .quality) ?? .refined
            vector = try container.decode([Float].self, forKey: .vector)
        }
    }

    static let shared = SemanticEmbeddingService()

    private let indexVersion = 2
    private let modelIdentifier = "google/siglip-base-patch16-256-multilingual"
    private let legacyIndexURL: URL
    private let database: SemanticIndexDatabase?
    private var entries: [String: IndexEntry] = [:]
    private var refinedEntryCount = 0
    private var pendingDatabaseWrites = 0
    private var imageModel: MLModel?
    private var textModel: MLModel?
    private var tokenizer: SigLIPTokenizer?
    private var textEmbeddingCache: [String: [Float]] = [:]
    private var didAttemptLoad = false
    private(set) var status = "等待加载语义模型"

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("PickPic", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        legacyIndexURL = directory.appendingPathComponent("siglip-multilingual-index-v1.json")
        database = SemanticIndexDatabase(
            url: directory.appendingPathComponent("siglip-multilingual-index-v2.sqlite"),
            version: indexVersion,
            model: modelIdentifier
        )

        if let database, !database.isEmpty {
            entries = database.loadEntries()
            refinedEntryCount = entries.values.count(where: { $0.quality == .refined })
            return
        }

        guard let data = try? Data(contentsOf: legacyIndexURL) else { return }

        if let document = try? JSONDecoder().decode(IndexDocument.self, from: data),
           document.version == indexVersion,
           document.model == modelIdentifier {
            entries = document.entries
        } else if let legacy = try? JSONDecoder().decode([String: [Float]].self, from: data) {
            entries = legacy.mapValues { IndexEntry(modifiedAt: nil, quality: .refined, vector: $0) }
        } else {
            let backup = legacyIndexURL
                .deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: legacyIndexURL, to: backup)
            status = "索引文件损坏，正在自动重建"
            return
        }
        refinedEntryCount = entries.values.count(where: { $0.quality == .refined })

        if let database {
            database.replaceAll(entries)
            let migratedURL = legacyIndexURL
                .deletingPathExtension()
                .appendingPathExtension("migrated.json")
            try? FileManager.default.moveItem(at: legacyIndexURL, to: migratedURL)
            status = "已有语义索引已迁移到增量数据库"
        }
    }

    var isAvailable: Bool {
        imageModel != nil && textModel != nil && tokenizer != nil
    }

    func prepare() async {
        guard !didAttemptLoad else { return }
        didAttemptLoad = true

        guard let imageURL = Bundle.main.url(forResource: "SigLIPImageEncoder", withExtension: "mlmodelc"),
              let textURL = Bundle.main.url(forResource: "SigLIPTextEncoder", withExtension: "mlmodelc"),
              let tokenizerURL = Bundle.main.url(
                forResource: "tokenizer",
                withExtension: "json",
                subdirectory: "SigLIPTokenizer.bundle"
              )
        else {
            status = "未找到语义模型资源"
            return
        }

        do {
            let configuration = MLModelConfiguration()
            // Avoid competing with UI animations on the GPU during foreground transitions.
            configuration.computeUnits = .cpuAndNeuralEngine
            imageModel = try MLModel(contentsOf: imageURL, configuration: configuration)
            textModel = try MLModel(contentsOf: textURL, configuration: configuration)
            tokenizer = try SigLIPTokenizer(contentsOf: tokenizerURL)
            status = "多语言 SigLIP 已就绪"
        } catch {
            status = "语义模型加载失败：\(error.localizedDescription)"
        }
    }

    var indexedCount: Int {
        entries.count
    }

    var refinedCount: Int {
        refinedEntryCount
    }

    func requiresIndex(_ asset: PHAsset, quality: SemanticIndexQuality = .thumbnail) -> Bool {
        guard let entry = entries[asset.localIdentifier] else { return true }
        return entry.modifiedAt != Self.modifiedAt(for: asset) || entry.quality.rawValue < quality.rawValue
    }

    func assetIDsRequiringIndex(
        _ assets: [SemanticAssetSnapshot],
        quality: SemanticIndexQuality
    ) -> Set<String> {
        Set(assets.compactMap { asset in
            guard let entry = entries[asset.id],
                  entry.modifiedAt == asset.modifiedAt,
                  entry.quality.rawValue >= quality.rawValue
            else {
                return asset.id
            }
            return nil
        })
    }

    @discardableResult
    func reconcile(validAssetIDs: Set<String>) -> Int {
        let staleIDs = entries.keys.filter { !validAssetIDs.contains($0) }
        guard !staleIDs.isEmpty else { return 0 }

        for assetID in staleIDs {
            if entries[assetID]?.quality == .refined {
                refinedEntryCount -= 1
            }
            entries.removeValue(forKey: assetID)
        }
        database?.delete(assetIDs: staleIDs)
        status = "已清理 \(staleIDs.count) 条失效索引"
        return staleIDs.count
    }

    @discardableResult
    func index(
        asset: PHAsset,
        quality: SemanticIndexQuality = .thumbnail,
        allowNetworkAccess: Bool = true
    ) async -> Bool {
        await prepare()
        guard isAvailable else { return false }
        guard requiresIndex(asset, quality: quality) else { return true }
        guard
              let image = await Self.requestImage(
                for: asset,
                quality: quality,
                allowNetworkAccess: allowNetworkAccess
              ),
              let vector = imageEmbedding(for: image)
        else {
            status = quality == .thumbnail
                ? "部分照片没有本地缩略图，将在精细阶段补齐"
                : "有照片暂时无法精细化，稍后将自动重试"
            return false
        }

        let entry = IndexEntry(
            modifiedAt: Self.modifiedAt(for: asset),
            quality: quality,
            vector: vector
        )
        let previousQuality = entries[asset.localIdentifier]?.quality
        entries[asset.localIdentifier] = entry
        if previousQuality != .refined, quality == .refined {
            refinedEntryCount += 1
        }
        database?.upsert(assetID: asset.localIdentifier, entry: entry)
        pendingDatabaseWrites += 1
        status = quality == .thumbnail
            ? "已快速覆盖 \(entries.count) 张照片"
            : "已精细化 \(refinedEntryCount) 张照片"
        if pendingDatabaseWrites >= 100 {
            database?.commit()
            pendingDatabaseWrites = 0
        }
        return true
    }

    func clearIndex() {
        entries = [:]
        refinedEntryCount = 0
        pendingDatabaseWrites = 0
        database?.clear()
        status = "语义索引已清除"
    }

    func search(
        _ query: String,
        progress: (@Sendable (SemanticSearchProgress) async -> Void)? = nil
    ) async -> [SemanticEmbeddingMatch] {
        await prepare()
        await progress?(SemanticSearchProgress(phase: .understanding, completed: 0, total: 1))
        guard let queryVector = textEmbedding(for: query) else { return [] }
        await progress?(SemanticSearchProgress(phase: .understanding, completed: 1, total: 1))

        let total = entries.count
        let updateInterval = max(total / 24, 64)
        var matches: [SemanticEmbeddingMatch] = []
        matches.reserveCapacity(total)

        await progress?(SemanticSearchProgress(phase: .comparing, completed: 0, total: total))
        for (index, element) in entries.enumerated() {
            matches.append(
                SemanticEmbeddingMatch(
                    assetID: element.key,
                    score: Self.dot(queryVector, element.value.vector)
                )
            )

            let completed = index + 1
            if completed.isMultiple(of: updateInterval) || completed == total {
                await progress?(SemanticSearchProgress(phase: .comparing, completed: completed, total: total))
                await Task.yield()
            }
        }

        await progress?(SemanticSearchProgress(phase: .ranking, completed: 0, total: 1))
        matches.sort { $0.score > $1.score }
        await progress?(SemanticSearchProgress(phase: .ranking, completed: 1, total: 1))
        return matches
    }

    func thematicSearch(
        _ themes: [(name: String, query: String)],
        minimumScore: Float,
        maximumScoreDrop: Float,
        limitPerTheme: Int
    ) async -> [String: [SemanticEmbeddingMatch]] {
        await prepare()
        let themeVectors = themes.compactMap { theme in
            textEmbedding(for: theme.query).map { (name: theme.name, vector: $0) }
        }
        guard !themeVectors.isEmpty else { return [:] }

        var candidatesByTheme = Dictionary(
            uniqueKeysWithValues: themeVectors.map { ($0.name, [SemanticEmbeddingMatch]()) }
        )
        for entry in entries {
            for theme in themeVectors {
                let match = SemanticEmbeddingMatch(
                    assetID: entry.key,
                    score: Self.dot(theme.vector, entry.value.vector)
                )
                let insertionIndex = candidatesByTheme[theme.name, default: []]
                    .firstIndex(where: { match.score > $0.score })
                    ?? candidatesByTheme[theme.name, default: []].endIndex
                candidatesByTheme[theme.name, default: []].insert(match, at: insertionIndex)
                if candidatesByTheme[theme.name, default: []].count > limitPerTheme {
                    candidatesByTheme[theme.name, default: []].removeLast()
                }
            }
        }

        var matchesByTheme: [String: [SemanticEmbeddingMatch]] = [:]
        for theme in themeVectors {
            let candidates = candidatesByTheme[theme.name] ?? []
            guard let bestScore = candidates.first?.score else { continue }
            let threshold = max(minimumScore, bestScore - maximumScoreDrop)
            matchesByTheme[theme.name] = Array(
                candidates.prefix { $0.score >= threshold }
            )
        }
        return matchesByTheme
    }

    func flush() {
        database?.commit()
        pendingDatabaseWrites = 0
    }

    private func textEmbedding(for text: String) -> [Float]? {
        if let cached = textEmbeddingCache[text] {
            return cached
        }
        guard let textModel, let tokenizer else { return nil }
        let tokens = Array((tokenizer.encode(text) + [tokenizer.eosTokenID]).prefix(64))
        guard let input = try? MLMultiArray(shape: [1, 64], dataType: .int32) else {
            return nil
        }

        for index in 0..<64 {
            input[index] = NSNumber(value: index < tokens.count ? tokens[index] : 1)
        }

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["input_ids": input]),
              let output = try? textModel.prediction(from: provider),
              let embedding = output.featureValue(for: "text_embedding")?.multiArrayValue
        else {
            return nil
        }
        let vector = Self.vector(from: embedding)
        if textEmbeddingCache.count >= 32 {
            textEmbeddingCache.removeAll(keepingCapacity: true)
        }
        textEmbeddingCache[text] = vector
        return vector
    }

    private func imageEmbedding(for image: UIImage) -> [Float]? {
        guard let imageModel, let cgImage = image.cgImage,
              let input = try? MLFeatureValue(
                cgImage: cgImage,
                pixelsWide: 256,
                pixelsHigh: 256,
                pixelFormatType: kCVPixelFormatType_32ARGB,
                options: nil
              ),
              let provider = try? MLDictionaryFeatureProvider(dictionary: ["image": input]),
              let output = try? imageModel.prediction(from: provider),
              let embedding = output.featureValue(for: "image_embedding")?.multiArrayValue
        else {
            return nil
        }
        return Self.vector(from: embedding)
    }

    private static func modifiedAt(for asset: PHAsset) -> TimeInterval? {
        (asset.modificationDate ?? asset.creationDate)?.timeIntervalSinceReferenceDate
    }

    private static func vector(from array: MLMultiArray) -> [Float] {
        (0..<array.count).map { array[$0].floatValue }
    }

    private static func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        return vDSP.dot(lhs, rhs)
    }

    private static func requestImage(
        for asset: PHAsset,
        quality: SemanticIndexQuality,
        allowNetworkAccess: Bool
    ) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = quality == .thumbnail ? .fastFormat : .highQualityFormat
            options.resizeMode = quality == .thumbnail ? .fast : .exact
            options.isNetworkAccessAllowed = quality == .refined && allowNetworkAccess

            let lock = NSLock()
            var finished = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 256, height: 256),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard quality == .thumbnail || !isDegraded else { return }

                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                continuation.resume(returning: image)
            }
        }
    }
}

private final class SemanticIndexDatabase {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var handle: OpaquePointer?
    private var transactionOpen = false

    init?(url: URL, version: Int, model: String) {
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            return nil
        }

        execute("PRAGMA journal_mode=WAL")
        execute("PRAGMA synchronous=NORMAL")
        execute("PRAGMA temp_store=MEMORY")
        execute("""
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """)
        execute("""
            CREATE TABLE IF NOT EXISTS embeddings (
                asset_id TEXT PRIMARY KEY,
                modified_at REAL,
                quality INTEGER NOT NULL DEFAULT 1,
                vector BLOB NOT NULL
            ) WITHOUT ROWID
            """)
        execute("ALTER TABLE embeddings ADD COLUMN quality INTEGER NOT NULL DEFAULT 1")

        let storedVersion = metadataValue(for: "version")
        let storedModel = metadataValue(for: "model")
        if storedVersion != String(version) || storedModel != model {
            execute("DELETE FROM embeddings")
            setMetadataValue(String(version), for: "version")
            setMetadataValue(model, for: "model")
        }
    }

    deinit {
        commit()
        if let handle {
            sqlite3_close(handle)
        }
    }

    var isEmpty: Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "SELECT 1 FROM embeddings LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            return true
        }
        return sqlite3_step(statement) != SQLITE_ROW
    }

    func loadEntries() -> [String: SemanticEmbeddingService.IndexEntry] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            handle,
            "SELECT asset_id, modified_at, quality, vector FROM embeddings",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return [:]
        }

        var entries: [String: SemanticEmbeddingService.IndexEntry] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let assetCString = sqlite3_column_text(statement, 0) else { continue }
            let assetID = String(cString: assetCString)
            let modifiedAt = sqlite3_column_type(statement, 1) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(statement, 1)
            let quality = SemanticIndexQuality(rawValue: Int(sqlite3_column_int(statement, 2))) ?? .refined
            let byteCount = Int(sqlite3_column_bytes(statement, 3))
            guard let bytes = sqlite3_column_blob(statement, 3), byteCount > 0 else { continue }
            let data = Data(bytes: bytes, count: byteCount)
            entries[assetID] = SemanticEmbeddingService.IndexEntry(
                modifiedAt: modifiedAt,
                quality: quality,
                vector: Self.vector(from: data)
            )
        }
        return entries
    }

    func replaceAll(_ entries: [String: SemanticEmbeddingService.IndexEntry]) {
        execute("BEGIN IMMEDIATE")
        execute("DELETE FROM embeddings")
        for (assetID, entry) in entries {
            upsert(assetID: assetID, entry: entry, beginTransaction: false)
        }
        execute("COMMIT")
        transactionOpen = false
    }

    func upsert(assetID: String, entry: SemanticEmbeddingService.IndexEntry) {
        upsert(assetID: assetID, entry: entry, beginTransaction: true)
    }

    func delete(assetIDs: [String]) {
        guard !assetIDs.isEmpty else { return }
        beginTransactionIfNeeded()

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "DELETE FROM embeddings WHERE asset_id = ?", -1, &statement, nil) == SQLITE_OK else {
            return
        }
        for assetID in assetIDs {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, assetID, -1, Self.transient)
            sqlite3_step(statement)
        }
        commit()
    }

    func commit() {
        guard transactionOpen else { return }
        execute("COMMIT")
        transactionOpen = false
    }

    func clear() {
        commit()
        execute("DELETE FROM embeddings")
        execute("VACUUM")
    }

    private func upsert(
        assetID: String,
        entry: SemanticEmbeddingService.IndexEntry,
        beginTransaction: Bool
    ) {
        if beginTransaction {
            beginTransactionIfNeeded()
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            handle,
            """
            INSERT INTO embeddings(asset_id, modified_at, quality, vector)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(asset_id) DO UPDATE SET
                modified_at = excluded.modified_at,
                quality = excluded.quality,
                vector = excluded.vector
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return
        }

        sqlite3_bind_text(statement, 1, assetID, -1, Self.transient)
        if let modifiedAt = entry.modifiedAt {
            sqlite3_bind_double(statement, 2, modifiedAt)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        sqlite3_bind_int(statement, 3, Int32(entry.quality.rawValue))
        let data = entry.vector.withUnsafeBytes { Data($0) }
        data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(bytes.count), Self.transient)
            sqlite3_step(statement)
        }
    }

    private func beginTransactionIfNeeded() {
        guard !transactionOpen else { return }
        execute("BEGIN IMMEDIATE")
        transactionOpen = true
    }

    private func metadataValue(for key: String) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "SELECT value FROM metadata WHERE key = ?", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_text(statement, 1, key, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0)
        else {
            return nil
        }
        return String(cString: value)
    }

    private func setMetadataValue(_ value: String, for key: String) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            handle,
            "INSERT OR REPLACE INTO metadata(key, value) VALUES(?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return
        }
        sqlite3_bind_text(statement, 1, key, -1, Self.transient)
        sqlite3_bind_text(statement, 2, value, -1, Self.transient)
        sqlite3_step(statement)
    }

    private func execute(_ sql: String) {
        sqlite3_exec(handle, sql, nil, nil, nil)
    }

    private static func vector(from data: Data) -> [Float] {
        data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float.self))
        }
    }
}
