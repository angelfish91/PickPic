import BackgroundTasks
import Photos
import CoreLocation
import Network
import SQLite3
import SwiftUI

struct PhotoEvent: Identifiable {
    let id: String
    let assets: [PHAsset]
    let startDate: Date
    let endDate: Date
    let coverAsset: PHAsset
    let semanticTitle: String?

    var title: String {
        if let semanticTitle {
            return semanticTitle
        }

        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: startDate)

        switch hour {
        case 5..<11: return "清晨与上午"
        case 11..<15: return "午后的片刻"
        case 15..<19: return "傍晚时分"
        default: return "夜晚的记录"
        }
    }

    var subtitle: String {
        let date = startDate.formatted(.dateTime.year().month(.wide).day())
        return "\(date) · \(assets.count) 张照片"
    }
}

struct SemanticSearchResult: Identifiable {
    let asset: PHAsset
    let score: Float
    let reason: String

    var id: String { asset.localIdentifier }
}

private struct PhotoInteractionDocument: Codable {
    var favoriteAssetIDs: [String] = []
    var irrelevantAssetIDsByQuery: [String: [String]] = [:]
    var feedbackEvents: [PhotoFeedbackEvent] = []
}

private struct VisualAnalysisCacheDocument: Codable {
    let version: Int
    var entries: [String: PhotoVisualAnalysis]
}

private struct CachedPhotoEvent {
    let id: String
    let assetIDs: [String]
    let startDate: Date
    let endDate: Date
    let coverAssetID: String
    let semanticTitle: String?
}

private struct PhotoAssetSnapshot {
    let id: String
    let modifiedAt: TimeInterval?
}

struct PhotoFeedbackEvent: Codable {
    let query: String
    let assetID: String
    let kind: String
    let createdAt: Date
}

private final class PhotoEventCache {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var handle: OpaquePointer?

    init(url: URL) {
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            handle = nil
            return
        }
        execute("PRAGMA journal_mode=WAL")
        execute("PRAGMA synchronous=NORMAL")
        execute("""
            CREATE TABLE IF NOT EXISTS asset_snapshot (
                position INTEGER PRIMARY KEY,
                asset_id TEXT NOT NULL,
                modified_at REAL
            )
            """)
        execute("""
            CREATE TABLE IF NOT EXISTS events (
                event_id TEXT PRIMARY KEY,
                start_date REAL NOT NULL,
                end_date REAL NOT NULL,
                cover_asset_id TEXT NOT NULL,
                semantic_title TEXT,
                asset_ids BLOB NOT NULL
            )
            """)
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    func loadEvents(matching snapshots: [PhotoAssetSnapshot]) -> [CachedPhotoEvent]? {
        guard snapshotMatches(snapshots) else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            handle,
            """
            SELECT event_id, start_date, end_date, cover_asset_id, semantic_title, asset_ids
            FROM events ORDER BY end_date DESC
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return nil
        }

        var events: [CachedPhotoEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let coverText = sqlite3_column_text(statement, 3),
                  let bytes = sqlite3_column_blob(statement, 5)
            else {
                return nil
            }
            let byteCount = Int(sqlite3_column_bytes(statement, 5))
            let data = Data(bytes: bytes, count: byteCount)
            guard let assetIDs = try? JSONDecoder().decode([String].self, from: data) else {
                return nil
            }
            let title = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            events.append(
                CachedPhotoEvent(
                    id: String(cString: idText),
                    assetIDs: assetIDs,
                    startDate: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1)),
                    endDate: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2)),
                    coverAssetID: String(cString: coverText),
                    semanticTitle: title
                )
            )
        }
        return events
    }

    func matches(_ snapshots: [PhotoAssetSnapshot]) -> Bool {
        snapshotMatches(snapshots)
    }

    func replace(events: [PhotoEvent], snapshots: [PhotoAssetSnapshot]) {
        guard handle != nil else { return }
        execute("BEGIN IMMEDIATE")
        execute("DELETE FROM asset_snapshot")
        execute("DELETE FROM events")

        var snapshotStatement: OpaquePointer?
        if sqlite3_prepare_v2(
            handle,
            "INSERT INTO asset_snapshot(position, asset_id, modified_at) VALUES(?, ?, ?)",
            -1,
            &snapshotStatement,
            nil
        ) == SQLITE_OK {
            for (position, snapshot) in snapshots.enumerated() {
                sqlite3_reset(snapshotStatement)
                sqlite3_clear_bindings(snapshotStatement)
                sqlite3_bind_int64(snapshotStatement, 1, Int64(position))
                sqlite3_bind_text(snapshotStatement, 2, snapshot.id, -1, Self.transient)
                if let modifiedAt = snapshot.modifiedAt {
                    sqlite3_bind_double(snapshotStatement, 3, modifiedAt)
                } else {
                    sqlite3_bind_null(snapshotStatement, 3)
                }
                sqlite3_step(snapshotStatement)
            }
        }
        sqlite3_finalize(snapshotStatement)

        var eventStatement: OpaquePointer?
        if sqlite3_prepare_v2(
            handle,
            """
            INSERT INTO events(event_id, start_date, end_date, cover_asset_id, semantic_title, asset_ids)
            VALUES(?, ?, ?, ?, ?, ?)
            """,
            -1,
            &eventStatement,
            nil
        ) == SQLITE_OK {
            for event in events {
                guard let assetData = try? JSONEncoder().encode(event.assets.map(\.localIdentifier)) else {
                    continue
                }
                sqlite3_reset(eventStatement)
                sqlite3_clear_bindings(eventStatement)
                sqlite3_bind_text(eventStatement, 1, event.id, -1, Self.transient)
                sqlite3_bind_double(eventStatement, 2, event.startDate.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(eventStatement, 3, event.endDate.timeIntervalSinceReferenceDate)
                sqlite3_bind_text(eventStatement, 4, event.coverAsset.localIdentifier, -1, Self.transient)
                if let title = event.semanticTitle {
                    sqlite3_bind_text(eventStatement, 5, title, -1, Self.transient)
                } else {
                    sqlite3_bind_null(eventStatement, 5)
                }
                assetData.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(eventStatement, 6, bytes.baseAddress, Int32(bytes.count), Self.transient)
                    sqlite3_step(eventStatement)
                }
            }
        }
        sqlite3_finalize(eventStatement)
        execute("COMMIT")
    }

    func clear() {
        execute("DELETE FROM asset_snapshot")
        execute("DELETE FROM events")
        execute("VACUUM")
    }

    private func snapshotMatches(_ snapshots: [PhotoAssetSnapshot]) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            handle,
            "SELECT asset_id, modified_at FROM asset_snapshot ORDER BY position",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return false
        }

        var position = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            guard position < snapshots.count,
                  let idText = sqlite3_column_text(statement, 0),
                  String(cString: idText) == snapshots[position].id
            else {
                return false
            }
            let storedModifiedAt = sqlite3_column_type(statement, 1) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(statement, 1)
            guard storedModifiedAt == snapshots[position].modifiedAt else {
                return false
            }
            position += 1
        }
        return position == snapshots.count
    }

    private func execute(_ sql: String) {
        guard let handle else { return }
        sqlite3_exec(handle, sql, nil, nil, nil)
    }
}

@MainActor
final class PhotoLibraryStore: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let backgroundIndexTaskIdentifier = "com.sparrowsong.PickPic.background-index"

    @Published private(set) var assets: [PHAsset] = []
    @Published private(set) var events: [PhotoEvent] = []
    @Published private(set) var travelMemoryEvents: [PhotoEvent] = []
    @Published private(set) var lightMemoryEvents: [PhotoEvent] = []
    @Published private(set) var travelLocationNames: [String: String] = [:]
    @Published private(set) var excludedAssetCount = 0
    @Published private(set) var visuallyExcludedAssetCount = 0
    @Published private(set) var visualScanProgress = 0
    @Published private(set) var visualScanTotal = 0
    @Published private(set) var isVisualScanning = false
    @Published private(set) var semanticModelStatus = "等待加载语义模型"
    @Published private(set) var semanticIndexProgress = 0
    @Published private(set) var semanticIndexTotal = 0
    @Published private(set) var semanticIndexFailed = 0
    @Published private(set) var isSemanticIndexing = false
    @Published private(set) var semanticIndexPhase = "快速索引"
    @Published private(set) var indexedPhotoCount = 0
    @Published private(set) var refinedPhotoCount = 0
    @Published private(set) var isIndexingPaused = false
    @Published private(set) var isPreparingSearch = true
    @Published private(set) var searchPreparationStatus = "正在准备照片搜索"
    @Published private(set) var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var isLoading = false
    @Published private(set) var favoriteAssetIDs: Set<String> = []
    @Published var downloadsICloudOnWiFiOnly: Bool {
        didSet {
            UserDefaults.standard.set(downloadsICloudOnWiFiOnly, forKey: Self.wifiOnlyPreferenceKey)
        }
    }
    @Published private(set) var isOnWiFi = false
    @Published private(set) var cacheByteCount: Int64 = 0
    @Published private(set) var isManagingCache = false
    private var metadataAssets: [PHAsset] = []
    private var libraryFetchResult: PHFetchResult<PHAsset>?
    private var visualAnalyses: [String: PhotoVisualAnalysis] = [:]
    private var pendingLibraryRefresh = false
    private let interactionURL: URL
    private let visualAnalysisCacheURL: URL
    private let eventCache: PhotoEventCache
    private let supportDirectory: URL
    private let networkMonitor = NWPathMonitor()
    private var irrelevantAssetIDsByQuery: [String: Set<String>] = [:]
    private var feedbackEvents: [PhotoFeedbackEvent] = []
    private let visualAnalysisCacheVersion = 2
    private var activePhotoBrowsers = 0
    private var isApplicationActive = true
    private var isBackgroundProcessingAllowed = false
    private var scenePhaseGeneration = 0
    private var travelLocationTask: Task<Void, Never>?
    private var startupPreparationTask: Task<Void, Never>?
    private var startupLibrarySnapshotMatched = false
    private var cachedMemoryEvents: [PhotoEvent] = []
    private var cachedFeaturedMemoryEvents: [PhotoEvent] = []
    private var cachedTodayMemoryEvents: [PhotoEvent] = []
    private var cachedTimeCapsuleEvents: [PhotoEvent] = []
    private var assetsByID: [String: PHAsset] = [:]
    private static let wifiOnlyPreferenceKey = "downloadsICloudOnWiFiOnly"

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("PickPic", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        interactionURL = directory.appendingPathComponent("photo-interactions-v1.json")
        visualAnalysisCacheURL = directory.appendingPathComponent("visual-analysis-cache-v1.plist")
        eventCache = PhotoEventCache(url: directory.appendingPathComponent("photo-events-v1.sqlite"))
        supportDirectory = directory
        downloadsICloudOnWiFiOnly = UserDefaults.standard.object(
            forKey: Self.wifiOnlyPreferenceKey
        ) as? Bool ?? true
        super.init()
        loadInteractions()
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.isOnWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "PickPic.NetworkMonitor"))
        PHPhotoLibrary.shared().register(self)
        registerBackgroundIndexTask()
    }

    deinit {
        startupPreparationTask?.cancel()
        networkMonitor.cancel()
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    var heroEvent: PhotoEvent? {
        events.first(where: { $0.assets.count >= 3 }) ?? events.first
    }

    var memoryEvents: [PhotoEvent] {
        cachedMemoryEvents
    }

    var featuredMemoryEvents: [PhotoEvent] {
        cachedFeaturedMemoryEvents
    }

    var todayMemoryEvents: [PhotoEvent] {
        cachedTodayMemoryEvents
    }

    var timeCapsuleEvents: [PhotoEvent] {
        cachedTimeCapsuleEvents
    }

    var analyzedPhotoCount: Int {
        visualAnalyses.count
    }

    func search(
        _ query: String,
        progress: (@Sendable (SemanticSearchProgress) async -> Void)? = nil
    ) async -> [SemanticSearchResult] {
        async let semanticTask = SemanticEmbeddingService.shared.search(query, progress: progress)
        async let detailTask = HybridSearchIndex.shared.search(query)
        let semanticMatches = await semanticTask
        let detailMatches = await detailTask
        let irrelevantIDs = irrelevantAssetIDsByQuery[Self.normalizedQuery(query)] ?? []

        var fusedScores: [String: (score: Float, semantic: Bool, detail: Bool)] = [:]
        if let bestScore = semanticMatches.first?.score {
            let similarityThreshold = max(Self.minimumSearchSimilarity, bestScore - Self.maximumScoreDrop)
            let semanticRange = max(bestScore - similarityThreshold, 0.001)
            for match in semanticMatches.prefix(while: { $0.score >= similarityThreshold }) {
                guard !irrelevantIDs.contains(match.assetID) else { continue }
                let normalizedScore = min(max((match.score - similarityThreshold) / semanticRange, 0), 1)
                fusedScores[match.assetID] = (
                    score: 0.25 + normalizedScore * 0.72,
                    semantic: true,
                    detail: false
                )
            }
        }

        for match in detailMatches where !irrelevantIDs.contains(match.assetID) {
            let existing = fusedScores[match.assetID]
            let detailScore = match.score * 0.42
            fusedScores[match.assetID] = (
                score: (existing?.score ?? 0) + detailScore + (existing == nil ? 0 : 0.18),
                semantic: existing?.semantic ?? false,
                detail: true
            )
        }

        return fusedScores
            .sorted { $0.value.score > $1.value.score }
            .compactMap { assetID, fused in
                guard let asset = assetsByID[assetID] else { return nil }
                let reason = fused.semantic && fused.detail
                    ? "混合匹配"
                    : fused.detail ? "细节匹配" : "语义相似"
                return SemanticSearchResult(asset: asset, score: fused.score, reason: reason)
            }
    }

    func isFavorite(_ asset: PHAsset) -> Bool {
        favoriteAssetIDs.contains(asset.localIdentifier)
    }

    func toggleFavorite(_ asset: PHAsset) {
        let assetID = asset.localIdentifier
        if favoriteAssetIDs.remove(assetID) == nil {
            favoriteAssetIDs.insert(assetID)
        }
        persistInteractions()
    }

    func markIrrelevant(_ asset: PHAsset, for query: String) {
        let normalized = Self.normalizedQuery(query)
        guard !normalized.isEmpty else { return }

        irrelevantAssetIDsByQuery[normalized, default: []].insert(asset.localIdentifier)
        feedbackEvents.append(
            PhotoFeedbackEvent(
                query: normalized,
                assetID: asset.localIdentifier,
                kind: "irrelevant",
                createdAt: Date()
            )
        )
        persistInteractions()
    }

    func start() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status

        guard status == .authorized || status == .limited else {
            setVisibleAssets([])
            setEvents([])
            isPreparingSearch = false
            return
        }

        isPreparingSearch = true
        searchPreparationStatus = "正在读取照片图库"
        await loadAssets(rebuildCollections: false)
        startupLibrarySnapshotMatched = eventCache.matches(Self.assetSnapshots(metadataAssets))
        isPreparingSearch = false
        semanticModelStatus = "正在后台恢复照片理解数据"

        startupPreparationTask?.cancel()
        startupPreparationTask = Task { [weak self] in
            await self?.finishStartupPreparation()
        }
    }

    private func finishStartupPreparation() async {
        // Give the first screen and its initial thumbnails time to become interactive.
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }

        await loadVisualAnalysisCache()
        guard !Task.isCancelled else { return }
        restoreCachedVisualAnalysisState()
        await rebuildHybridSearchIndex()
        await rebuildMemoryCollections()
        await refreshCacheUsage()
        guard !Task.isCancelled else { return }

        // Keep heavyweight model and index loading away from the first interaction window.
        try? await Task.sleep(for: .milliseconds(1_200))
        guard !Task.isCancelled else { return }

        let semanticCounts = await Task.detached(priority: .utility) {
            let indexed = await SemanticEmbeddingService.shared.indexedCount
            let refined = await SemanticEmbeddingService.shared.refinedCount
            return (indexed, refined)
        }.value
        guard !Task.isCancelled else { return }
        indexedPhotoCount = semanticCounts.0
        refinedPhotoCount = semanticCounts.1
        semanticModelStatus = semanticCounts.0 > 0
            ? "已有 \(semanticCounts.0) 张照片可搜索"
            : "正在建立首批可搜索照片"

        await SemanticEmbeddingService.shared.prepare()
        guard !Task.isCancelled else { return }
        semanticModelStatus = await SemanticEmbeddingService.shared.status
        if semanticCounts.0 > 0 {
            await refreshLightMemoryEvents()
            guard !Task.isCancelled else { return }
        }

        if startupLibrarySnapshotMatched {
            semanticModelStatus = semanticCounts.0 > 0
                ? "照片图库未变化，已复用 \(semanticCounts.0) 张照片的理解数据"
                : "照片图库未变化，等待系统后台建立搜索索引"
            return
        }

        await scanAllAssets()
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            await self?.refreshAfterLibraryChange(changeInstance)
        }
    }

    func loadAssets(rebuildCollections: Bool = true) async {
        isLoading = true
        let fetchResult = Self.fetchImageAssets()
        libraryFetchResult = fetchResult
        let (fetched, excluded) = await Self.filterCameraAssets(from: fetchResult)

        metadataAssets = fetched
        setVisibleAssets(fetched)
        excludedAssetCount = excluded
        isLoading = false

        if rebuildCollections {
            await rebuildMemoryCollections()
        }
    }

    private func rebuildMemoryCollections() async {
        let fetched = metadataAssets
        let snapshots = Self.assetSnapshots(fetched)
        if let cachedEvents = eventCache.loadEvents(matching: snapshots),
           let restored = Self.restoreEvents(cachedEvents, assetsByID: Dictionary(
            uniqueKeysWithValues: fetched.map { ($0.localIdentifier, $0) }
           )) {
            setEvents(restored)
            await rebuildTravelMemoryEvents()
            return
        }

        let analyses = visualAnalyses
        let newEvents = await Task.detached(priority: .utility) {
            Self.clusterIntoEvents(fetched, analyses: analyses)
        }.value
        setEvents(newEvents)
        eventCache.replace(events: newEvents, snapshots: snapshots)
        await rebuildTravelMemoryEvents()
    }

    private func rebuildTravelMemoryEvents() async {
        let memoryEvents = events.filter { $0.assets.count >= 2 }
        let travelEvents = await Task.detached(priority: .utility) {
            Self.clusterTravelEvents(memoryEvents)
        }.value
        travelMemoryEvents = travelEvents
        resolveTravelLocationNames(for: travelEvents)
    }

    nonisolated private static func fetchImageAssets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(with: .image, options: options)
    }

    nonisolated private static func filterCameraAssets(
        from result: PHFetchResult<PHAsset>
    ) async -> ([PHAsset], Int) {
        await Task.detached(priority: .userInitiated) {
            var fetched: [PHAsset] = []
            fetched.reserveCapacity(result.count)
            var excluded = 0
            result.enumerateObjects { asset, _, _ in
                if isLikelyCameraPhoto(asset) {
                    fetched.append(asset)
                } else {
                    excluded += 1
                }
            }
            return (fetched, excluded)
        }.value
    }

    func scanAllAssets(dismissPreparationAfterPlanning: Bool = false) async {
        guard !isVisualScanning, !isSemanticIndexing else {
            pendingLibraryRefresh = true
            if dismissPreparationAfterPlanning {
                isPreparingSearch = false
            }
            return
        }

        let validAssetIDs = Set(metadataAssets.map(\.localIdentifier))
        reconcileVisualAnalysisCache(validAssetIDs: validAssetIDs)
        _ = await SemanticEmbeddingService.shared.reconcile(validAssetIDs: validAssetIDs)
        await HybridSearchIndex.shared.reconcile(validAssetIDs: validAssetIDs)
        let visualCandidates = metadataAssets.filter(requiresVisualAnalysis)
        let visualCandidateIDs = Set(visualCandidates.map(\.localIdentifier))
        let snapshots = metadataAssets.map {
            SemanticAssetSnapshot(
                id: $0.localIdentifier,
                modifiedAt: ($0.modificationDate ?? $0.creationDate)?.timeIntervalSinceReferenceDate
            )
        }
        let semanticCandidateIDs = await SemanticEmbeddingService.shared.assetIDsRequiringIndex(
            snapshots,
            quality: .thumbnail
        )
        let pendingIndexCount = semanticCandidateIDs.count(where: {
            visualAnalyses[$0]?.isLikelyDocument != true
        })
        let candidates = metadataAssets.filter {
            visualCandidateIDs.contains($0.localIdentifier)
                || semanticCandidateIDs.contains($0.localIdentifier)
        }
        semanticIndexTotal = pendingIndexCount
        semanticIndexProgress = 0
        semanticIndexFailed = 0
        semanticIndexPhase = "快速索引"
        isSemanticIndexing = semanticIndexTotal > 0
        visualScanTotal = visualCandidates.count
        visualScanProgress = 0
        isVisualScanning = !candidates.isEmpty
        if dismissPreparationAfterPlanning {
            isPreparingSearch = false
        }

        // Keep background analysis deliberately gentle so navigation stays responsive.
        let batchSize = 1
        var completedVisualCount = 0
        var completedSemanticCount = 0
        var failedSemanticCount = 0
        for batchStart in stride(from: 0, to: candidates.count, by: batchSize) {
            while activePhotoBrowsers > 0 || isIndexingPaused || !canRunIndexing {
                try? await Task.sleep(for: .milliseconds(350))
            }

            let batchEnd = min(batchStart + batchSize, candidates.count)
            let batch = Array(candidates[batchStart..<batchEnd])
            let visualBatch = batch.filter { visualCandidateIDs.contains($0.localIdentifier) }

            var results: [PhotoVisualAnalysis] = []
            if let asset = visualBatch.first,
               let analysis = await VisualAnalysisService.analyze(asset: asset) {
                results.append(analysis)
            }

            for analysis in results {
                visualAnalyses[analysis.assetID] = analysis
            }
            await updateHybridSearchIndex(with: results)

            completedVisualCount += visualBatch.count
            if !visualBatch.isEmpty
                && (completedVisualCount.isMultiple(of: 400) || completedVisualCount == visualScanTotal) {
                await applyVisualResults()
            }
            if !visualBatch.isEmpty
                && (completedVisualCount.isMultiple(of: 500) || completedVisualCount == visualScanTotal) {
                persistVisualAnalysisCache()
            }

            let semanticBatch = batch.filter {
                semanticCandidateIDs.contains($0.localIdentifier)
                    && visualAnalyses[$0.localIdentifier]?.isLikelyDocument != true
            }
            let semanticResults = await indexBatch(semanticBatch, quality: .thumbnail)
            completedSemanticCount += semanticResults.count(where: { $0 })
            failedSemanticCount += semanticResults.count(where: { !$0 })
            if batchStart.isMultiple(of: 12) || batchEnd == candidates.count {
                visualScanProgress = completedVisualCount
                semanticIndexProgress = completedSemanticCount
                semanticIndexFailed = failedSemanticCount
                semanticModelStatus = await SemanticEmbeddingService.shared.status
                indexedPhotoCount = await SemanticEmbeddingService.shared.indexedCount
            }
            try? await Task.sleep(for: .milliseconds(80))
        }

        let visibleIDs = Set(metadataAssets.compactMap { asset in
            visualAnalyses[asset.localIdentifier]?.isLikelyDocument == true ? nil : asset.localIdentifier
        })
        _ = await SemanticEmbeddingService.shared.reconcile(validAssetIDs: visibleIDs)
        await HybridSearchIndex.shared.reconcile(validAssetIDs: visibleIDs)
        await SemanticEmbeddingService.shared.flush()
        await HybridSearchIndex.shared.flush()
        persistVisualAnalysisCache()
        await applyVisualResults()
        await refreshLightMemoryEvents()
        isVisualScanning = false

        let refinementSnapshots = assets.map {
            SemanticAssetSnapshot(
                id: $0.localIdentifier,
                modifiedAt: ($0.modificationDate ?? $0.creationDate)?.timeIntervalSinceReferenceDate
            )
        }
        let refinementIDs = await SemanticEmbeddingService.shared.assetIDsRequiringIndex(
            refinementSnapshots,
            quality: .refined
        )
        let refinementCandidates = assets.filter { refinementIDs.contains($0.localIdentifier) }
        semanticIndexPhase = "精细索引"
        semanticIndexTotal = refinementCandidates.count
        semanticIndexProgress = 0
        semanticIndexFailed = 0
        isSemanticIndexing = !refinementCandidates.isEmpty
        semanticModelStatus = refinementCandidates.isEmpty
            ? "所有语义索引均已精细化"
            : "快速索引已可搜索，正在后台精细化"

        let refinementBatchSize = 1
        var completedRefinementCount = 0
        var failedRefinementCount = 0
        for batchStart in stride(from: 0, to: refinementCandidates.count, by: refinementBatchSize) {
            while activePhotoBrowsers > 0 || isIndexingPaused || !canRunIndexing {
                try? await Task.sleep(for: .milliseconds(350))
            }

            let batchEnd = min(batchStart + refinementBatchSize, refinementCandidates.count)
            let batch = Array(refinementCandidates[batchStart..<batchEnd])
            let results = await indexBatch(
                batch,
                quality: .refined,
                allowNetworkAccess: canDownloadICloudPhotos
            )
            completedRefinementCount += results.count(where: { $0 })
            failedRefinementCount += results.count(where: { !$0 })
            if batchStart.isMultiple(of: 12) || batchEnd == refinementCandidates.count {
                semanticIndexProgress = completedRefinementCount
                semanticIndexFailed = failedRefinementCount
                semanticModelStatus = await SemanticEmbeddingService.shared.status
                indexedPhotoCount = await SemanticEmbeddingService.shared.indexedCount
                refinedPhotoCount = await SemanticEmbeddingService.shared.refinedCount
            }
            try? await Task.sleep(for: .milliseconds(80))
        }

        await SemanticEmbeddingService.shared.flush()
        let indexedCount = await SemanticEmbeddingService.shared.indexedCount
        let refinedCount = await SemanticEmbeddingService.shared.refinedCount
        indexedPhotoCount = indexedCount
        refinedPhotoCount = refinedCount
        semanticModelStatus = semanticIndexFailed == 0
            ? "语义索引已同步，共 \(indexedCount) 张，精细化 \(refinedCount) 张"
            : "已覆盖 \(indexedCount) 张，\(semanticIndexFailed) 张稍后精细化"
        await refreshLightMemoryEvents()
        await refreshCacheUsage()
        isSemanticIndexing = false

        if pendingLibraryRefresh {
            pendingLibraryRefresh = false
            await loadAssets()
            await scanAllAssets()
        }
    }

    func retryFailedIndexing() async {
        guard semanticIndexFailed > 0 else { return }
        await scanAllAssets()
    }

    func continueRefinedIndexing() async {
        guard !isVisualScanning, !isSemanticIndexing else { return }
        guard canDownloadICloudPhotos else {
            semanticModelStatus = "等待连接 Wi-Fi 后继续下载 iCloud 照片"
            return
        }

        await SemanticEmbeddingService.shared.prepare()
        let snapshots = assets.map {
            SemanticAssetSnapshot(
                id: $0.localIdentifier,
                modifiedAt: ($0.modificationDate ?? $0.creationDate)?.timeIntervalSinceReferenceDate
            )
        }
        let refinementIDs = await SemanticEmbeddingService.shared.assetIDsRequiringIndex(
            snapshots,
            quality: .refined
        )
        let candidates = assets.filter { refinementIDs.contains($0.localIdentifier) }
        guard !candidates.isEmpty else {
            semanticModelStatus = "所有可用照片均已精细化"
            return
        }

        semanticIndexPhase = "精细索引"
        semanticIndexTotal = candidates.count
        semanticIndexProgress = 0
        semanticIndexFailed = 0
        isSemanticIndexing = true
        semanticModelStatus = "正在从 iCloud 继续精细化"
        var interruptedForWiFi = false

        for (offset, asset) in candidates.enumerated() {
            while isIndexingPaused || !canRunIndexing {
                try? await Task.sleep(for: .milliseconds(350))
            }
            if downloadsICloudOnWiFiOnly && !isOnWiFi {
                semanticModelStatus = "Wi-Fi 已断开，精细索引已暂停"
                interruptedForWiFi = true
                break
            }
            let succeeded = await SemanticEmbeddingService.shared.index(
                asset: asset,
                quality: .refined,
                allowNetworkAccess: true
            )
            if succeeded {
                semanticIndexProgress += 1
            } else {
                semanticIndexFailed += 1
            }
            if offset.isMultiple(of: 12) || offset == candidates.count - 1 {
                refinedPhotoCount = await SemanticEmbeddingService.shared.refinedCount
            }
        }

        await SemanticEmbeddingService.shared.flush()
        indexedPhotoCount = await SemanticEmbeddingService.shared.indexedCount
        refinedPhotoCount = await SemanticEmbeddingService.shared.refinedCount
        isSemanticIndexing = false
        semanticModelStatus = interruptedForWiFi
            ? "Wi-Fi 已断开，连接后可继续精细索引"
            : semanticIndexFailed == 0
            ? "精细索引已同步"
            : "本次完成 \(semanticIndexProgress) 张，\(semanticIndexFailed) 张稍后重试"
        await refreshCacheUsage()
    }

    func rebuildSemanticIndex() async {
        guard !isVisualScanning, !isSemanticIndexing else { return }
        isManagingCache = true
        await SemanticEmbeddingService.shared.clearIndex()
        indexedPhotoCount = 0
        refinedPhotoCount = 0
        isManagingCache = false
        await scanAllAssets()
        await refreshCacheUsage()
    }

    func clearCaches() async {
        guard !isVisualScanning, !isSemanticIndexing else { return }
        isManagingCache = true
        await SemanticEmbeddingService.shared.clearIndex()
        await HybridSearchIndex.shared.clear()
        eventCache.clear()
        visualAnalyses = [:]
        try? FileManager.default.removeItem(at: visualAnalysisCacheURL)
        indexedPhotoCount = 0
        refinedPhotoCount = 0
        visuallyExcludedAssetCount = 0
        setVisibleAssets(metadataAssets)
        setEvents([])
        lightMemoryEvents = []
        travelMemoryEvents = []
        isManagingCache = false
        await refreshCacheUsage()
    }

    func refreshCacheUsage() async {
        let directory = supportDirectory
        let interactionPath = interactionURL.path
        cacheByteCount = await Task.detached(priority: .utility) {
            Self.cacheUsage(in: directory, excluding: interactionPath)
        }.value
    }

    nonisolated private static func cacheUsage(in directory: URL, excluding excludedPath: String) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator where url.path != excludedPath {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    func setIndexingPaused(_ paused: Bool) {
        isIndexingPaused = paused
        semanticModelStatus = paused ? "后台整理已暂停" : "后台整理已继续"
    }

    func handleScenePhase(_ phase: ScenePhase) async {
        scenePhaseGeneration += 1
        let generation = scenePhaseGeneration

        guard phase == .active else {
            isApplicationActive = false
            scheduleBackgroundIndexing()
            return
        }

        // Let unlock animations, Photos and the visible UI settle before resuming inference.
        try? await Task.sleep(for: .milliseconds(1_500))
        guard generation == scenePhaseGeneration else { return }
        isApplicationActive = true
    }

    private var canRunIndexing: Bool {
        isApplicationActive || isBackgroundProcessingAllowed
    }

    private var canDownloadICloudPhotos: Bool {
        !downloadsICloudOnWiFiOnly || isOnWiFi
    }

    private func registerBackgroundIndexTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundIndexTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                self?.runBackgroundIndexing(processingTask)
            }
        }
    }

    private func scheduleBackgroundIndexing() {
        guard !isIndexingPaused else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundIndexTaskIdentifier)
        let request = BGProcessingTaskRequest(identifier: Self.backgroundIndexTaskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func runBackgroundIndexing(_ task: BGProcessingTask) {
        var expired = false
        isBackgroundProcessingAllowed = true
        semanticModelStatus = "系统正在后台整理照片"

        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                expired = true
                self?.isBackgroundProcessingAllowed = false
                self?.scheduleBackgroundIndexing()
            }
        }

        Task { @MainActor [weak self] in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }

            if metadataAssets.isEmpty {
                authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                guard authorizationStatus == .authorized || authorizationStatus == .limited else {
                    isBackgroundProcessingAllowed = false
                    task.setTaskCompleted(success: false)
                    return
                }
                await loadVisualAnalysisCache()
                await loadAssets()
                await SemanticEmbeddingService.shared.prepare()
            }

            if !isVisualScanning && !isSemanticIndexing {
                await scanAllAssets()
            } else {
                while (isVisualScanning || isSemanticIndexing) && !expired {
                    try? await Task.sleep(for: .seconds(1))
                }
            }

            isBackgroundProcessingAllowed = false
            if isVisualScanning || isSemanticIndexing || semanticIndexFailed > 0 {
                scheduleBackgroundIndexing()
            }
            task.setTaskCompleted(success: !expired)
        }
    }

    func clearSearchPreferences() {
        irrelevantAssetIDsByQuery = [:]
        feedbackEvents = []
        persistInteractions()
    }

    func beginPhotoBrowsing() {
        activePhotoBrowsers += 1
    }

    func endPhotoBrowsing() {
        activePhotoBrowsers = max(0, activePhotoBrowsers - 1)
    }

    private func indexBatch(
        _ assets: [PHAsset],
        quality: SemanticIndexQuality,
        allowNetworkAccess: Bool = false
    ) async -> [Bool] {
        await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for asset in assets {
                group.addTask {
                    await SemanticEmbeddingService.shared.index(
                        asset: asset,
                        quality: quality,
                        allowNetworkAccess: allowNetworkAccess
                    )
                }
            }

            var results: [Bool] = []
            results.reserveCapacity(assets.count)
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    private func refreshAfterLibraryChange(_ change: PHChange) async {
        guard authorizationStatus == .authorized || authorizationStatus == .limited else { return }
        startupPreparationTask?.cancel()
        if isVisualScanning || isSemanticIndexing {
            pendingLibraryRefresh = true
            return
        }

        guard let libraryFetchResult,
              let details = change.changeDetails(for: libraryFetchResult),
              details.hasIncrementalChanges
        else {
            await loadAssets()
            await scanAllAssets()
            return
        }

        let removedAssets = details.removedObjects
        let insertedAssets = details.insertedObjects
        let changedAssets = details.changedObjects
        let changedCount = removedAssets.count + insertedAssets.count + changedAssets.count
        guard changedCount <= max(200, metadataAssets.count / 5) else {
            self.libraryFetchResult = details.fetchResultAfterChanges
            await loadAssets()
            await scanAllAssets()
            return
        }

        self.libraryFetchResult = details.fetchResultAfterChanges
        await applyIncrementalLibraryChange(
            removed: removedAssets,
            inserted: insertedAssets,
            changed: changedAssets
        )
        await scanAllAssets()
    }

    private func applyIncrementalLibraryChange(
        removed: [PHAsset],
        inserted: [PHAsset],
        changed: [PHAsset]
    ) async {
        let changedIDs = Set((removed + changed).map(\.localIdentifier))
        var updatedAssets = metadataAssets.filter { !changedIDs.contains($0.localIdentifier) }
        updatedAssets.append(contentsOf: (inserted + changed).filter(Self.isLikelyCameraPhoto))
        updatedAssets.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }

        let affectedDates = (removed + inserted + changed).compactMap(\.creationDate)
        metadataAssets = updatedAssets
        excludedAssetCount = max((libraryFetchResult?.count ?? updatedAssets.count) - updatedAssets.count, 0)

        let visibleAssets = updatedAssets.filter {
            visualAnalyses[$0.localIdentifier]?.isLikelyDocument != true
        }
        visuallyExcludedAssetCount = updatedAssets.count - visibleAssets.count
        setVisibleAssets(visibleAssets)

        guard let earliestDate = affectedDates.min(),
              let latestDate = affectedDates.max()
        else {
            await rebuildMemoryCollections()
            return
        }

        let windowStart = earliestDate.addingTimeInterval(-24 * 60 * 60)
        let windowEnd = latestDate.addingTimeInterval(24 * 60 * 60)
        let windowAssets = visibleAssets.filter {
            guard let date = $0.creationDate else { return false }
            return date >= windowStart && date <= windowEnd
        }
        let analyses = visualAnalyses
        let replacementEvents = await Task.detached(priority: .utility) {
            Self.clusterIntoEvents(windowAssets, analyses: analyses)
        }.value
        let retainedEvents = events.filter {
            $0.endDate < windowStart || $0.startDate > windowEnd
        }
        let mergedEvents = (retainedEvents + replacementEvents)
            .sorted { $0.endDate > $1.endDate }
        setEvents(mergedEvents)
        eventCache.replace(events: mergedEvents, snapshots: Self.assetSnapshots(updatedAssets))
        await rebuildTravelMemoryEvents()
    }

    private func applyVisualResults() async {
        let allAssets = metadataAssets
        let analyses = visualAnalyses
        let result = await Task.detached(priority: .utility) {
            let visibleAssets = allAssets.filter { asset in
                analyses[asset.localIdentifier]?.isLikelyDocument != true
            }
            let events = Self.clusterIntoEvents(visibleAssets, analyses: analyses)
            return (
                assets: visibleAssets,
                events: events,
                travelEvents: Self.clusterTravelEvents(events.filter { $0.assets.count >= 2 })
            )
        }.value
        visuallyExcludedAssetCount = allAssets.count - result.assets.count
        setVisibleAssets(result.assets)
        setEvents(result.events)
        eventCache.replace(events: result.events, snapshots: Self.assetSnapshots(allAssets))
        travelMemoryEvents = result.travelEvents
        resolveTravelLocationNames(for: result.travelEvents)
    }

    private func refreshLightMemoryEvents() async {
        let matches = await SemanticEmbeddingService.shared.thematicSearch(
            Self.semanticLightThemes.map { (name: $0.name, query: $0.query) },
            minimumScore: 0.08,
            maximumScoreDrop: 0.045,
            limitPerTheme: 60
        )
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        let analyses = visualAnalyses
        lightMemoryEvents = Self.semanticLightThemes.compactMap { theme in
            let matchedAssets = (matches[theme.name] ?? [])
                .compactMap { assetsByID[$0.assetID] }
                .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
            guard matchedAssets.count >= 3,
                  let newest = matchedAssets.first,
                  let oldest = matchedAssets.last,
                  let startDate = oldest.creationDate,
                  let endDate = newest.creationDate
            else {
                return nil
            }
            return PhotoEvent(
                id: "light-\(theme.name)",
                assets: matchedAssets,
                startDate: startDate,
                endDate: endDate,
                coverAsset: Self.bestCover(in: matchedAssets, analyses: analyses),
                semanticTitle: theme.name
            )
        }
        .sorted {
            if $0.assets.count == $1.assets.count { return $0.endDate > $1.endDate }
            return $0.assets.count > $1.assets.count
        }
    }

    private func setEvents(_ newEvents: [PhotoEvent]) {
        let calendar = Calendar.current
        let today = Date()
        let currentYear = calendar.component(.year, from: today)
        let currentMonth = calendar.component(.month, from: today)
        let recentCutoff = calendar.date(byAdding: .month, value: -6, to: today) ?? .distantPast
        let capsuleCutoff = calendar.date(byAdding: .year, value: -1, to: today) ?? .distantPast
        let memories = newEvents.filter { $0.assets.count >= 2 }
        let recent = memories.filter { $0.endDate >= recentCutoff }

        cachedMemoryEvents = memories
        cachedFeaturedMemoryEvents = (recent.isEmpty ? memories : recent)
            .filter { $0.assets.count >= 3 }
            .sorted { memoryInterestScore($0) > memoryInterestScore($1) }
        cachedTodayMemoryEvents = memories
            .filter {
                let components = calendar.dateComponents([.year, .month, .day], from: $0.startDate)
                return components.year != currentYear
                    && components.month == calendar.component(.month, from: today)
                    && components.day == calendar.component(.day, from: today)
                    && $0.assets.count >= 3
            }
            .sorted { $0.startDate > $1.startDate }
        cachedTimeCapsuleEvents = memories
            .filter {
                $0.endDate < capsuleCutoff
                    && calendar.component(.month, from: $0.startDate) == currentMonth
                    && $0.assets.count >= 3
            }
            .sorted { memoryInterestScore($0) > memoryInterestScore($1) }
        events = newEvents
    }

    private func setVisibleAssets(_ newAssets: [PHAsset]) {
        assetsByID = Dictionary(uniqueKeysWithValues: newAssets.map { ($0.localIdentifier, $0) })
        assets = newAssets
    }

    nonisolated private static func assetSnapshots(_ assets: [PHAsset]) -> [PhotoAssetSnapshot] {
        assets.map {
            PhotoAssetSnapshot(
                id: $0.localIdentifier,
                modifiedAt: ($0.modificationDate ?? $0.creationDate)?.timeIntervalSinceReferenceDate
            )
        }
    }

    nonisolated private static func hybridSearchDocument(
        for asset: PHAsset,
        analysis: PhotoVisualAnalysis
    ) -> HybridSearchDocument {
        let sortedLabels = analysis.classifications
            .filter { $0.value >= 0.08 }
            .sorted { $0.value > $1.value }
            .map(\.key)
        let visualTerms = sortedLabels.flatMap { label in
            [label] + hybridAliases(for: label)
        }
        let peopleTerms = hybridPeopleTerms(faceCount: analysis.faceCount, labels: sortedLabels)
        let contextTerms = hybridContextTerms(for: asset, analysis: analysis)

        return HybridSearchDocument(
            assetID: asset.localIdentifier,
            modifiedAt: VisualAnalysisService.assetModifiedAt(for: asset),
            visualText: Self.uniqueJoined(visualTerms),
            ocrText: Self.uniqueJoined(analysis.recognizedTexts),
            peopleText: Self.uniqueJoined(peopleTerms),
            contextText: Self.uniqueJoined(contextTerms)
        )
    }

    nonisolated private static func hybridAliases(for label: String) -> [String] {
        let normalized = label.lowercased()
        let mappings: [(needles: [String], aliases: [String])] = [
            (["person", "people", "portrait", "face"], ["人", "人物", "人脸", "肖像", "合照"]),
            (["selfie"], ["自拍", "人脸", "肖像"]),
            (["child", "baby", "toddler", "kid"], ["小孩", "孩子", "宝宝", "儿童"]),
            (["dog"], ["狗", "宠物", "动物"]),
            (["cat"], ["猫", "宠物", "动物"]),
            (["animal", "pet"], ["动物", "宠物"]),
            (["food", "dish", "meal"], ["食物", "美食", "吃饭", "餐桌"]),
            (["restaurant"], ["餐厅", "吃饭", "聚餐"]),
            (["coffee"], ["咖啡", "饮料"]),
            (["cake", "dessert"], ["蛋糕", "甜点", "生日"]),
            (["drink", "beverage"], ["饮料", "喝的"]),
            (["beach", "ocean", "sea", "coast"], ["海边", "海", "沙滩"]),
            (["lake", "river", "water"], ["水", "湖", "河"]),
            (["mountain"], ["山", "爬山"]),
            (["forest", "tree"], ["森林", "树", "自然"]),
            (["flower", "plant"], ["花", "植物", "自然"]),
            (["sky", "cloud"], ["天空", "云"]),
            (["sunset", "sunrise"], ["日落", "日出", "晚霞", "朝霞"]),
            (["city", "street", "building", "traffic"], ["城市", "街道", "建筑", "交通"]),
            (["night"], ["夜晚", "夜景"]),
            (["document", "text"], ["文档", "文字"]),
            (["menu"], ["菜单", "餐厅"]),
            (["poster"], ["海报"]),
            (["screenshot", "web site"], ["截图", "网页"])
        ]

        return mappings
            .filter { mapping in mapping.needles.contains { normalized.contains($0) } }
            .flatMap(\.aliases)
    }

    nonisolated private static func hybridPeopleTerms(faceCount: Int, labels: [String]) -> [String] {
        var terms: [String] = []
        if faceCount > 0 {
            terms.append(contentsOf: ["face", "person", "portrait", "人", "人脸", "肖像"])
        }
        if faceCount >= 2 {
            terms.append(contentsOf: ["people", "group", "friends", "合照", "朋友", "多人"])
        }
        if labels.contains(where: { $0.contains("selfie") }) {
            terms.append(contentsOf: ["selfie", "自拍"])
        }
        return terms
    }

    nonisolated private static func hybridContextTerms(
        for asset: PHAsset,
        analysis: PhotoVisualAnalysis
    ) -> [String] {
        var terms: [String] = []
        if analysis.textBlockCount > 0 {
            terms.append(contentsOf: ["text", "文字"])
        }
        if analysis.textBlockCount >= 3 || analysis.textAreaRatio >= 0.16 {
            terms.append(contentsOf: ["text heavy", "document", "文档", "文字多"])
        }
        if analysis.containsBarcode {
            terms.append(contentsOf: ["barcode", "qr", "二维码", "条码"])
        }
        if asset.location != nil {
            terms.append(contentsOf: ["location", "place", "地点"])
        }
        return terms
    }

    nonisolated private static func uniqueJoined(_ values: [String]) -> String {
        var seen: Set<String> = []
        return values
            .map {
                $0.lowercased()
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: " ")
    }

    nonisolated private static func restoreEvents(
        _ cachedEvents: [CachedPhotoEvent],
        assetsByID: [String: PHAsset]
    ) -> [PhotoEvent]? {
        var events: [PhotoEvent] = []
        events.reserveCapacity(cachedEvents.count)
        for cached in cachedEvents {
            let assets = cached.assetIDs.compactMap { assetsByID[$0] }
            guard assets.count == cached.assetIDs.count,
                  let coverAsset = assetsByID[cached.coverAssetID]
            else {
                return nil
            }
            events.append(
                PhotoEvent(
                    id: cached.id,
                    assets: assets,
                    startDate: cached.startDate,
                    endDate: cached.endDate,
                    coverAsset: coverAsset,
                    semanticTitle: cached.semanticTitle
                )
            )
        }
        return events.sorted { $0.endDate > $1.endDate }
    }

    private func requiresVisualAnalysis(_ asset: PHAsset) -> Bool {
        guard let analysis = visualAnalyses[asset.localIdentifier] else { return true }
        return analysis.modifiedAt != VisualAnalysisService.assetModifiedAt(for: asset)
    }

    private func rebuildHybridSearchIndex() async {
        let documents = metadataAssets.compactMap { asset -> HybridSearchDocument? in
            guard let analysis = visualAnalyses[asset.localIdentifier],
                  !analysis.isLikelyDocument
            else {
                return nil
            }
            return Self.hybridSearchDocument(for: asset, analysis: analysis)
        }
        let validAssetIDs = Set(assets.map(\.localIdentifier))
        await HybridSearchIndex.shared.reconcile(validAssetIDs: validAssetIDs)
        await HybridSearchIndex.shared.upsert(documents)
        await HybridSearchIndex.shared.flush()
    }

    private func updateHybridSearchIndex(with analyses: [PhotoVisualAnalysis]) async {
        guard !analyses.isEmpty else { return }
        let assetsByIdentifier = Dictionary(uniqueKeysWithValues: metadataAssets.map { ($0.localIdentifier, $0) })
        var deletedAssetIDs: Set<String> = []
        var documents: [HybridSearchDocument] = []

        for analysis in analyses {
            guard let asset = assetsByIdentifier[analysis.assetID] else {
                deletedAssetIDs.insert(analysis.assetID)
                continue
            }
            if analysis.isLikelyDocument {
                deletedAssetIDs.insert(analysis.assetID)
            } else {
                documents.append(Self.hybridSearchDocument(for: asset, analysis: analysis))
            }
        }

        await HybridSearchIndex.shared.delete(assetIDs: deletedAssetIDs)
        await HybridSearchIndex.shared.upsert(documents)
    }

    private func reconcileVisualAnalysisCache(validAssetIDs: Set<String>) {
        let staleIDs = visualAnalyses.keys.filter { !validAssetIDs.contains($0) }
        guard !staleIDs.isEmpty else { return }
        for assetID in staleIDs {
            visualAnalyses.removeValue(forKey: assetID)
        }
        persistVisualAnalysisCache()
    }

    private func restoreCachedVisualAnalysisState() {
        let validAssetIDs = Set(metadataAssets.map(\.localIdentifier))
        reconcileVisualAnalysisCache(validAssetIDs: validAssetIDs)
        let visibleAssets = metadataAssets.filter {
            visualAnalyses[$0.localIdentifier]?.isLikelyDocument != true
        }
        visuallyExcludedAssetCount = metadataAssets.count - visibleAssets.count
        setVisibleAssets(visibleAssets)
    }

    private func loadVisualAnalysisCache() async {
        let url = visualAnalysisCacheURL
        let version = visualAnalysisCacheVersion
        let entries = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  let document = try? PropertyListDecoder().decode(VisualAnalysisCacheDocument.self, from: data),
                  document.version == version
            else {
                return [String: PhotoVisualAnalysis]()
            }
            return document.entries
        }.value
        visualAnalyses = entries
    }

    private func persistVisualAnalysisCache() {
        let document = VisualAnalysisCacheDocument(
            version: visualAnalysisCacheVersion,
            entries: visualAnalyses
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(document) else { return }
        try? data.write(to: visualAnalysisCacheURL, options: .atomic)
    }

    private func loadInteractions() {
        guard let data = try? Data(contentsOf: interactionURL),
              let document = try? JSONDecoder().decode(PhotoInteractionDocument.self, from: data)
        else {
            return
        }
        favoriteAssetIDs = Set(document.favoriteAssetIDs)
        irrelevantAssetIDsByQuery = document.irrelevantAssetIDsByQuery.mapValues(Set.init)
        feedbackEvents = document.feedbackEvents
    }

    private func persistInteractions() {
        let document = PhotoInteractionDocument(
            favoriteAssetIDs: favoriteAssetIDs.sorted(),
            irrelevantAssetIDsByQuery: irrelevantAssetIDsByQuery.mapValues { $0.sorted() },
            feedbackEvents: feedbackEvents
        )
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: interactionURL, options: .atomic)
    }

    private static func normalizedQuery(_ query: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    nonisolated private static func isLikelyCameraPhoto(_ asset: PHAsset) -> Bool {
        guard !asset.isHidden,
              asset.creationDate != nil,
              asset.pixelWidth >= 480,
              asset.pixelHeight >= 480,
              !asset.mediaSubtypes.contains(.photoScreenshot)
        else {
            return false
        }

        return true
    }

    nonisolated private static func clusterIntoEvents(
        _ assets: [PHAsset],
        analyses: [String: PhotoVisualAnalysis]
    ) -> [PhotoEvent] {
        let chronological = assets.sorted {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }

        var groups: [[PHAsset]] = []
        var current: [PHAsset] = []

        for asset in chronological {
            guard let previous = current.last else {
                current = [asset]
                continue
            }

            if belongsToSameEvent(previous, asset, analyses: analyses) {
                current.append(asset)
            } else {
                groups.append(current)
                current = [asset]
            }
        }

        if !current.isEmpty {
            groups.append(current)
        }

        return groups.compactMap { group in
            guard let first = group.first,
                  let last = group.last,
                  let start = first.creationDate,
                  let end = last.creationDate
            else {
                return nil
            }

            return PhotoEvent(
                id: first.localIdentifier,
                assets: group,
                startDate: start,
                endDate: end,
                coverAsset: bestCover(in: group, analyses: analyses),
                semanticTitle: semanticTitle(for: group, analyses: analyses)
            )
        }
        .sorted { $0.endDate > $1.endDate }
    }

    nonisolated private static func clusterTravelEvents(_ events: [PhotoEvent]) -> [PhotoEvent] {
        struct LocatedEvent {
            let event: PhotoEvent
            let location: CLLocation
        }

        struct TravelCluster {
            var events: [PhotoEvent]
            var locations: [CLLocation]
            var startDate: Date
            var endDate: Date
        }

        let locatedEvents = events.compactMap { event -> LocatedEvent? in
            guard let location = representativeLocation(for: event.assets) else { return nil }
            return LocatedEvent(event: event, location: location)
        }
        .sorted { $0.event.startDate < $1.event.startDate }
        let residentLocations = inferredResidentLocations(from: events.flatMap(\.assets))
        let awayEvents = locatedEvents.filter { item in
            !residentLocations.contains { item.location.distance(from: $0) <= 20_000 }
        }
        var clusters: [TravelCluster] = []
        let maximumTimeGap: TimeInterval = 48 * 60 * 60
        let maximumTripDuration: TimeInterval = 14 * 24 * 60 * 60

        for item in awayEvents {
            if let index = clusters.indices.last,
               item.event.startDate.timeIntervalSince(clusters[index].endDate) <= maximumTimeGap,
               item.event.endDate.timeIntervalSince(clusters[index].startDate) <= maximumTripDuration {
                clusters[index].events.append(item.event)
                clusters[index].locations.append(item.location)
                clusters[index].endDate = max(clusters[index].endDate, item.event.endDate)
            } else {
                clusters.append(
                    TravelCluster(
                        events: [item.event],
                        locations: [item.location],
                        startDate: item.event.startDate,
                        endDate: item.event.endDate
                    )
                )
            }
        }

        return clusters.compactMap { cluster in
            let assets = cluster.events
                .flatMap(\.assets)
                .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            guard assets.count >= 6,
                  let first = assets.first,
                  let last = assets.last,
                  let startDate = first.creationDate,
                  let endDate = last.creationDate,
                  cluster.events.count >= 2 || endDate.timeIntervalSince(startDate) >= 6 * 60 * 60
            else {
                return nil
            }

            return PhotoEvent(
                id: "travel-\(first.localIdentifier)",
                assets: assets,
                startDate: startDate,
                endDate: endDate,
                coverAsset: cluster.events.max(by: { $0.assets.count < $1.assets.count })?.coverAsset ?? first,
                semanticTitle: "旅行轨迹"
            )
        }
        .sorted { $0.endDate > $1.endDate }
    }

    nonisolated private static func representativeLocation(for assets: [PHAsset]) -> CLLocation? {
        let locations = assets.compactMap(\.location)
        guard !locations.isEmpty else { return nil }
        let latitude = locations.reduce(0) { $0 + $1.coordinate.latitude } / Double(locations.count)
        let longitude = locations.reduce(0) { $0 + $1.coordinate.longitude } / Double(locations.count)
        return CLLocation(latitude: latitude, longitude: longitude)
    }

    nonisolated private static func inferredResidentLocations(from assets: [PHAsset]) -> [CLLocation] {
        struct GridKey: Hashable {
            let latitude: Int
            let longitude: Int
        }
        struct GridStats {
            var latitudeTotal = 0.0
            var longitudeTotal = 0.0
            var count = 0
            var days: Set<Date> = []
            var months: Set<Date> = []
            var firstDate = Date.distantFuture
            var lastDate = Date.distantPast
        }

        let calendar = Calendar.current
        let gridSize = 0.05
        var grids: [GridKey: GridStats] = [:]

        for asset in assets {
            guard let location = asset.location, let date = asset.creationDate else { continue }
            let coordinate = location.coordinate
            let key = GridKey(
                latitude: Int((coordinate.latitude / gridSize).rounded()),
                longitude: Int((coordinate.longitude / gridSize).rounded())
            )
            var stats = grids[key] ?? GridStats()
            stats.latitudeTotal += coordinate.latitude
            stats.longitudeTotal += coordinate.longitude
            stats.count += 1
            stats.days.insert(calendar.startOfDay(for: date))
            let month = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
            stats.months.insert(month)
            stats.firstDate = min(stats.firstDate, date)
            stats.lastDate = max(stats.lastDate, date)
            grids[key] = stats
        }

        let candidates = grids.values.compactMap { stats -> CLLocation? in
            guard stats.days.count >= 15,
                  stats.months.count >= 3,
                  stats.lastDate.timeIntervalSince(stats.firstDate) >= 90 * 24 * 60 * 60
            else {
                return nil
            }
            return CLLocation(
                latitude: stats.latitudeTotal / Double(stats.count),
                longitude: stats.longitudeTotal / Double(stats.count)
            )
        }

        return candidates.reduce(into: [CLLocation]()) { residents, candidate in
            guard !residents.contains(where: { candidate.distance(from: $0) <= 10_000 }) else { return }
            residents.append(candidate)
        }
    }

    private func resolveTravelLocationNames(for events: [PhotoEvent]) {
        travelLocationTask?.cancel()
        let unresolved = events.filter { travelLocationNames[$0.id] == nil }
        guard !unresolved.isEmpty else { return }

        travelLocationTask = Task { [weak self] in
            for event in unresolved {
                guard !Task.isCancelled,
                      let location = event.assets.compactMap(\.location).first
                else {
                    continue
                }

                let name = await Self.cityName(for: location)
                guard !Task.isCancelled else { return }
                self?.travelLocationNames[event.id] = name
            }
        }
    }

    nonisolated private static func cityName(for location: CLLocation) async -> String {
        await withCheckedContinuation { continuation in
            CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_CN")) {
                placemarks,
                _ in
                let placemark = placemarks?.first
                let name = placemark?.locality
                    ?? placemark?.subAdministrativeArea
                    ?? placemark?.administrativeArea
                continuation.resume(returning: name ?? "位置已记录")
            }
        }
    }

    nonisolated private static func semanticTitle(
        for assets: [PHAsset],
        analyses: [String: PhotoVisualAnalysis]
    ) -> String? {
        var scores: [String: Float] = [:]
        for asset in assets {
            for (label, confidence) in analyses[asset.localIdentifier]?.classifications ?? [:] {
                scores[label, default: 0] += confidence
            }
        }

        for theme in semanticThemes {
            let score = scores.reduce(Float.zero) { partial, item in
                partial + (theme.terms.contains(where: { item.key.contains($0) }) ? item.value : 0)
            }
            if score >= max(0.6, Float(assets.count) * 0.14) {
                return theme.name
            }
        }
        return nil
    }

    nonisolated private static func bestCover(
        in assets: [PHAsset],
        analyses: [String: PhotoVisualAnalysis]
    ) -> PHAsset {
        let centerIndex = assets.count / 2
        return assets.enumerated().min { lhs, rhs in
            coverPenalty(lhs, centerIndex: centerIndex, analyses: analyses)
                < coverPenalty(rhs, centerIndex: centerIndex, analyses: analyses)
        }?.element ?? assets[centerIndex]
    }

    nonisolated private static func coverPenalty(
        _ candidate: (offset: Int, element: PHAsset),
        centerIndex: Int,
        analyses: [String: PhotoVisualAnalysis]
    ) -> CGFloat {
        let analysis = analyses[candidate.element.localIdentifier]
        let textPenalty = (analysis?.textAreaRatio ?? 0) * 4
        let centerPenalty = CGFloat(abs(candidate.offset - centerIndex)) / CGFloat(max(centerIndex, 1))
        return textPenalty + centerPenalty * 0.2
    }

    nonisolated private static func belongsToSameEvent(
        _ lhs: PHAsset,
        _ rhs: PHAsset,
        analyses: [String: PhotoVisualAnalysis]
    ) -> Bool {
        guard let lhsDate = lhs.creationDate, let rhsDate = rhs.creationDate else {
            return false
        }

        let gap = rhsDate.timeIntervalSince(lhsDate)
        if gap > 8 * 60 * 60 {
            return false
        }

        if let lhsLocation = lhs.location, let rhsLocation = rhs.location {
            let distance = lhsLocation.distance(from: rhsLocation)
            if distance > 50_000 {
                return false
            }
            if distance > 5_000 && gap > 60 * 60 {
                return false
            }
        }

        if gap <= 90 * 60 {
            return true
        }

        guard gap <= 4 * 60 * 60,
              let lhsFeature = analyses[lhs.localIdentifier]?.featurePrint,
              let rhsFeature = analyses[rhs.localIdentifier]?.featurePrint
        else {
            return false
        }

        var distance: Float = 0
        do {
            try lhsFeature.computeDistance(&distance, to: rhsFeature)
            return distance < 0.42
        } catch {
            return false
        }
    }

    nonisolated private static let semanticThemes: [(name: String, terms: [String])] = [
        ("城市夜色", ["night", "street", "city", "road", "traffic", "building"]),
        ("自然之间", ["mountain", "forest", "tree", "flower", "plant", "landscape", "sky"]),
        ("餐桌时光", ["food", "dish", "meal", "restaurant", "drink", "dessert"]),
        ("海边片刻", ["beach", "ocean", "sea", "coast", "water"]),
        ("和动物相遇", ["dog", "cat", "animal", "pet", "bird"]),
        ("小朋友", ["child", "baby", "toddler", "kid"]),
        ("人与相聚", ["person", "people", "group", "portrait", "face"])
    ]

    nonisolated private static let semanticLightThemes: [(name: String, query: String)] = [
        ("晚霞漫天", "晚霞 日落 sunset colorful sky"),
        ("城市夜景", "城市夜景 city at night"),
        ("蓝调时刻", "蓝调时刻 blue hour twilight"),
        ("日出晨光", "日出 晨光 sunrise morning light"),
        ("黄金时刻", "黄金时刻 golden hour sunlight"),
        ("雨夜霓虹", "雨夜霓虹 rainy night neon street"),
        ("月夜与星空", "月亮 星空 moon and stars night sky"),
        ("雾中清晨", "雾中清晨 misty foggy morning"),
        ("逆光剪影", "逆光剪影 silhouette backlight"),
        ("云层与天光", "云层 天光 clouds and rays of light")
    ]

    private static let minimumSearchSimilarity: Float = 0.08
    private static let maximumScoreDrop: Float = 0.055

    private func memoryInterestScore(_ event: PhotoEvent) -> Double {
        let ageInDays = max(0, Date().timeIntervalSince(event.endDate) / 86_400)
        let recency = max(0, 1 - ageInDays / 365)
        let semantic = event.semanticTitle == nil ? 0 : 1.8
        let location = event.assets.contains { $0.location != nil } ? 0.8 : 0
        let size = min(log2(Double(event.assets.count) + 1), 4) * 0.55
        let duration = event.endDate.timeIntervalSince(event.startDate)
        let coherentDuration = duration <= 12 * 60 * 60 ? 0.5 : 0
        return recency * 1.4 + semantic + location + size + coherentDuration
    }

}

final class PhotoThumbnailPipeline {
    static let shared = PhotoThumbnailPipeline()

    private let manager = PHCachingImageManager()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 500
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func cachedImage(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    @discardableResult
    func requestImage(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        normalizedCropRect: CGRect?,
        key: String,
        completion: @escaping (UIImage) -> Void
    ) -> PHImageRequestID {
        if let cached = cachedImage(for: key) {
            completion(cached)
            return PHInvalidImageRequestID
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        if let normalizedCropRect {
            options.normalizedCropRect = normalizedCropRect
        }
        options.isNetworkAccessAllowed = false

        return manager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode,
            options: options
        ) { [weak self] image, info in
            guard let image,
                  (info?[PHImageCancelledKey] as? Bool) != true,
                  info?[PHImageErrorKey] == nil
            else {
                return
            }

            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if !isDegraded {
                let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
                self?.cache.setObject(image, forKey: key as NSString, cost: cost)
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    func cancel(_ requestID: PHImageRequestID?) {
        guard let requestID, requestID != PHInvalidImageRequestID else { return }
        manager.cancelImageRequest(requestID)
    }

    func preheat(_ assets: [PHAsset], targetSize: CGSize) {
        guard !assets.isEmpty else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        manager.startCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        )
    }

    func stopPreheating() {
        manager.stopCachingImagesForAllAssets()
    }
}

struct PhotoAssetImage: View {
    let asset: PHAsset
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.06)

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .clipped()
            .task(id: requestKey(for: proxy.size)) {
                requestImage(size: proxy.size)
            }
        }
        .onDisappear {
            PhotoThumbnailPipeline.shared.cancel(requestID)
            requestID = nil
        }
    }

    private func requestKey(for size: CGSize) -> String {
        let target = targetSize(for: size)
        return "\(asset.localIdentifier)-\(Int(target.width))x\(Int(target.height))-\(contentMode == .fill ? "fill" : "fit")"
    }

    private func requestImage(size: CGSize) {
        PhotoThumbnailPipeline.shared.cancel(requestID)
        let targetSize = targetSize(for: size)
        let key = requestKey(for: size)
        if let cached = PhotoThumbnailPipeline.shared.cachedImage(for: key) {
            image = cached
            return
        }

        requestID = PhotoThumbnailPipeline.shared.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode == .fill ? .aspectFill : .aspectFit,
            normalizedCropRect: normalizedCropRect(for: size),
            key: key
        ) { requestedImage in
            image = requestedImage
        }
    }

    private func targetSize(for size: CGSize) -> CGSize {
        let scale = UIScreen.main.scale
        let width = max(ceil(size.width * scale / 64) * 64, 256)
        let height = max(ceil(size.height * scale / 64) * 64, 256)
        return CGSize(width: width, height: height)
    }

    private func normalizedCropRect(for size: CGSize) -> CGRect? {
        guard contentMode == .fill,
              asset.pixelWidth > 0,
              asset.pixelHeight > 0,
              size.width > 0,
              size.height > 0
        else {
            return nil
        }

        let sourceAspectRatio = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
        let targetAspectRatio = size.width / size.height

        if sourceAspectRatio > targetAspectRatio {
            let cropWidth = targetAspectRatio / sourceAspectRatio
            return CGRect(x: (1 - cropWidth) / 2, y: 0, width: cropWidth, height: 1)
        }

        let cropHeight = sourceAspectRatio / targetAspectRatio
        return CGRect(x: 0, y: (1 - cropHeight) / 2, width: 1, height: cropHeight)
    }
}

struct SquarePhotoAssetImage: View {
    let asset: PHAsset

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                PhotoAssetImage(asset: asset, contentMode: .fill)
            }
            .clipped()
            .contentShape(Rectangle())
    }
}
