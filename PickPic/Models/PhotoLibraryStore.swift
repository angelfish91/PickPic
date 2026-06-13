import BackgroundTasks
import Photos
import CoreLocation
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

struct PhotoFeedbackEvent: Codable {
    let query: String
    let assetID: String
    let kind: String
    let createdAt: Date
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
    private var metadataAssets: [PHAsset] = []
    private var visualAnalyses: [String: PhotoVisualAnalysis] = [:]
    private var pendingLibraryRefresh = false
    private let interactionURL: URL
    private let visualAnalysisCacheURL: URL
    private var irrelevantAssetIDsByQuery: [String: Set<String>] = [:]
    private var feedbackEvents: [PhotoFeedbackEvent] = []
    private let visualAnalysisCacheVersion = 1
    private var activePhotoBrowsers = 0
    private var isApplicationActive = true
    private var isBackgroundProcessingAllowed = false
    private var scenePhaseGeneration = 0
    private var travelLocationTask: Task<Void, Never>?

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("PickPic", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        interactionURL = directory.appendingPathComponent("photo-interactions-v1.json")
        visualAnalysisCacheURL = directory.appendingPathComponent("visual-analysis-cache-v1.plist")
        super.init()
        loadInteractions()
        PHPhotoLibrary.shared().register(self)
        registerBackgroundIndexTask()
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    var heroEvent: PhotoEvent? {
        events.first(where: { $0.assets.count >= 3 }) ?? events.first
    }

    var memoryEvents: [PhotoEvent] {
        events.filter { $0.assets.count >= 2 }
    }

    var featuredMemoryEvents: [PhotoEvent] {
        let recentCutoff = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? .distantPast
        let recent = memoryEvents.filter { $0.endDate >= recentCutoff }
        return (recent.isEmpty ? memoryEvents : recent)
            .filter { $0.assets.count >= 3 }
            .sorted { memoryInterestScore($0) > memoryInterestScore($1) }
    }

    var todayMemoryEvents: [PhotoEvent] {
        let calendar = Calendar.current
        let today = Date()
        let currentYear = calendar.component(.year, from: today)
        return memoryEvents
            .filter {
                let components = calendar.dateComponents([.year, .month, .day], from: $0.startDate)
                return components.year != currentYear
                    && components.month == calendar.component(.month, from: today)
                    && components.day == calendar.component(.day, from: today)
                    && $0.assets.count >= 3
            }
            .sorted { $0.startDate > $1.startDate }
    }

    var timeCapsuleEvents: [PhotoEvent] {
        let calendar = Calendar.current
        let today = Date()
        let currentMonth = calendar.component(.month, from: today)
        let cutoff = calendar.date(byAdding: .year, value: -1, to: today) ?? .distantPast
        return memoryEvents
            .filter {
                $0.endDate < cutoff
                    && calendar.component(.month, from: $0.startDate) == currentMonth
                    && $0.assets.count >= 3
            }
            .sorted { memoryInterestScore($0) > memoryInterestScore($1) }
    }

    var analyzedPhotoCount: Int {
        visualAnalyses.count
    }

    func search(
        _ query: String,
        progress: (@Sendable (SemanticSearchProgress) async -> Void)? = nil
    ) async -> [SemanticSearchResult] {
        let semanticMatches = await SemanticEmbeddingService.shared.search(query, progress: progress)
        guard let bestScore = semanticMatches.first?.score else { return [] }

        let similarityThreshold = max(Self.minimumSearchSimilarity, bestScore - Self.maximumScoreDrop)
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        let irrelevantIDs = irrelevantAssetIDsByQuery[Self.normalizedQuery(query)] ?? []
        return semanticMatches
            .prefix { $0.score >= similarityThreshold }
            .filter { !irrelevantIDs.contains($0.assetID) }
            .compactMap { match in
                guard let asset = assetsByID[match.assetID] else { return nil }
                return SemanticSearchResult(asset: asset, score: match.score, reason: "语义相似")
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
            assets = []
            events = []
            isPreparingSearch = false
            return
        }

        isPreparingSearch = true
        searchPreparationStatus = "正在恢复照片理解数据"
        await loadVisualAnalysisCache()
        searchPreparationStatus = "正在读取照片图库"
        await loadAssets()
        searchPreparationStatus = "正在载入已有搜索索引"

        // Let the first screen render before loading a potentially large vector database.
        try? await Task.sleep(for: .milliseconds(250))
        let indexedCount = await Task.detached(priority: .utility) {
            await SemanticEmbeddingService.shared.indexedCount
        }.value
        indexedPhotoCount = indexedCount
        semanticModelStatus = indexedCount > 0
            ? "已有 \(indexedCount) 张照片可搜索"
            : "正在建立首批可搜索照片"
        searchPreparationStatus = "正在启动照片理解引擎"
        await SemanticEmbeddingService.shared.prepare()
        semanticModelStatus = await SemanticEmbeddingService.shared.status
        searchPreparationStatus = "正在检查新增照片"
        await scanAllAssets(dismissPreparationAfterPlanning: true)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            await self?.refreshAfterLibraryChange()
        }
    }

    func loadAssets() async {
        isLoading = true

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let result = PHAsset.fetchAssets(with: .image, options: options)
        var fetched: [PHAsset] = []
        var excluded = 0
        result.enumerateObjects { asset, _, _ in
            if Self.isLikelyCameraPhoto(asset) {
                fetched.append(asset)
            } else {
                excluded += 1
            }
        }

        metadataAssets = fetched
        assets = fetched
        excludedAssetCount = excluded
        let analyses = visualAnalyses
        let collections = await Task.detached(priority: .utility) {
            let events = Self.clusterIntoEvents(fetched, analyses: analyses)
            return (
                events,
                Self.clusterTravelEvents(events.filter { $0.assets.count >= 2 })
            )
        }.value
        events = collections.0
        travelMemoryEvents = collections.1
        resolveTravelLocationNames(for: collections.1)
        await refreshLightMemoryEvents()
        isLoading = false
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

            visualScanProgress += visualBatch.count
            if !visualBatch.isEmpty
                && (visualScanProgress.isMultiple(of: 400) || visualScanProgress == visualScanTotal) {
                await applyVisualResults()
            }
            if !visualBatch.isEmpty
                && (visualScanProgress.isMultiple(of: 500) || visualScanProgress == visualScanTotal) {
                persistVisualAnalysisCache()
            }

            let semanticBatch = batch.filter {
                semanticCandidateIDs.contains($0.localIdentifier)
                    && visualAnalyses[$0.localIdentifier]?.isLikelyDocument != true
            }
            let semanticResults = await indexBatch(semanticBatch, quality: .thumbnail)
            semanticIndexProgress += semanticResults.count(where: { $0 })
            semanticIndexFailed += semanticResults.count(where: { !$0 })
            semanticModelStatus = await SemanticEmbeddingService.shared.status
            indexedPhotoCount = await SemanticEmbeddingService.shared.indexedCount
            try? await Task.sleep(for: .milliseconds(80))
        }

        let visibleIDs = Set(metadataAssets.compactMap { asset in
            visualAnalyses[asset.localIdentifier]?.isLikelyDocument == true ? nil : asset.localIdentifier
        })
        _ = await SemanticEmbeddingService.shared.reconcile(validAssetIDs: visibleIDs)
        await SemanticEmbeddingService.shared.flush()
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
        for batchStart in stride(from: 0, to: refinementCandidates.count, by: refinementBatchSize) {
            while activePhotoBrowsers > 0 || isIndexingPaused || !canRunIndexing {
                try? await Task.sleep(for: .milliseconds(350))
            }

            let batchEnd = min(batchStart + refinementBatchSize, refinementCandidates.count)
            let batch = Array(refinementCandidates[batchStart..<batchEnd])
            let results = await indexBatch(batch, quality: .refined)
            semanticIndexProgress += results.count(where: { $0 })
            semanticIndexFailed += results.count(where: { !$0 })
            semanticModelStatus = await SemanticEmbeddingService.shared.status
            indexedPhotoCount = await SemanticEmbeddingService.shared.indexedCount
            refinedPhotoCount = await SemanticEmbeddingService.shared.refinedCount
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

    private func indexBatch(_ assets: [PHAsset], quality: SemanticIndexQuality) async -> [Bool] {
        await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for asset in assets {
                group.addTask {
                    await SemanticEmbeddingService.shared.index(asset: asset, quality: quality)
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

    private func refreshAfterLibraryChange() async {
        guard authorizationStatus == .authorized || authorizationStatus == .limited else { return }
        if isVisualScanning || isSemanticIndexing {
            pendingLibraryRefresh = true
            return
        }
        await loadAssets()
        await scanAllAssets()
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
        assets = result.assets
        events = result.events
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

    private func requiresVisualAnalysis(_ asset: PHAsset) -> Bool {
        guard let analysis = visualAnalyses[asset.localIdentifier] else { return true }
        return analysis.modifiedAt != VisualAnalysisService.assetModifiedAt(for: asset)
    }

    private func reconcileVisualAnalysisCache(validAssetIDs: Set<String>) {
        let staleIDs = visualAnalyses.keys.filter { !validAssetIDs.contains($0) }
        guard !staleIDs.isEmpty else { return }
        for assetID in staleIDs {
            visualAnalyses.removeValue(forKey: assetID)
        }
        persistVisualAnalysisCache()
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

    private static func isLikelyCameraPhoto(_ asset: PHAsset) -> Bool {
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

    private static let minimumSearchSimilarity: Float = 0.10
    private static let maximumScoreDrop: Float = 0.035

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

private final class PhotoThumbnailPipeline {
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
        options.resizeMode = normalizedCropRect == nil ? .fast : .exact
        if let normalizedCropRect {
            options.normalizedCropRect = normalizedCropRect
        }
        options.isNetworkAccessAllowed = true

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
