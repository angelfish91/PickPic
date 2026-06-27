import SwiftUI

struct ProfileView: View {
    @ObservedObject var photoLibrary: PhotoLibraryStore
    @State private var clearPreferencesConfirmation = false
    @State private var clearCacheConfirmation = false
    @State private var rebuildIndexConfirmation = false
    @State private var showsOrganizationDetails = false

    private enum Insight {
        case searchable
        case pending
        case refined
        case memories
        case analyzed
        case filtered
    }

    private var searchablePhotoCount: Int {
        min(photoLibrary.indexedPhotoCount, photoLibrary.assets.count)
    }

    private var pendingPhotoCount: Int {
        max(photoLibrary.assets.count - searchablePhotoCount, 0)
    }

    private var isOrganizing: Bool {
        photoLibrary.isVisualScanning || photoLibrary.isSemanticIndexing
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 22) {
                header
                understandingCard
                preferencesSection
                privacyAndAboutSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 112)
        }
        .sheet(isPresented: $showsOrganizationDetails) {
            organizationDetails
        }
        .confirmationDialog(
            "清除搜索偏好？",
            isPresented: $clearPreferencesConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除搜索偏好", role: .destructive) {
                photoLibrary.clearSearchPreferences()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清除你标记为“不相关”的搜索反馈，不会删除照片或语义索引。")
        }
        .confirmationDialog(
            "清除本地缓存？",
            isPresented: $clearCacheConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除缓存", role: .destructive) {
                Task { await photoLibrary.clearCaches() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清除视觉分析、回忆聚类和语义索引缓存。不会删除照片、收藏或搜索偏好。")
        }
        .confirmationDialog(
            "重建语义索引？",
            isPresented: $rebuildIndexConfirmation,
            titleVisibility: .visible
        ) {
            Button("重建索引", role: .destructive) {
                Task { await photoLibrary.rebuildSemanticIndex() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清除当前语义索引并重新构建。视觉分析与回忆整理结果会保留。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("照片理解与整理")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PickPicTheme.secondaryInk)
            Text("我的")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
        }
    }

    private var understandingCard: some View {
        Button {
            showsOrganizationDetails = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(PickPicTheme.accentWash.opacity(0.72))
                    Image(systemName: organizationIcon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(PickPicTheme.ink)
                        .symbolEffect(.pulse, isActive: isOrganizing && !photoLibrary.isIndexingPaused)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 6) {
                    Text(indexingTitle)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(organizationSummary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(PickPicTheme.secondaryInk)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(PickPicTheme.secondaryInk.opacity(0.55))
            }
            .padding(16)
            .background(.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(PickPicTheme.hairline, lineWidth: 0.7)
            }
        }
        .buttonStyle(.plain)
    }

    private var organizationDetails: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 22) {
                    detailStatusCard
                    insightGrid
                    activitySection
                    indexingSection
                    storageSection
                }
                .padding(18)
                .padding(.bottom, 24)
            }
            .background(PickPicTheme.canvas.ignoresSafeArea())
            .navigationTitle("照片整理详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        showsOrganizationDetails = false
                    }
                }
            }
        }
        .presentationBackground(PickPicTheme.canvas)
    }

    private var detailStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: organizationIcon)
                    .font(.system(size: 18, weight: .semibold))
                Text(indexingTitle)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                Spacer()
            }
            Text(organizationSummary)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
            Text("截图、文档和二维码等内容被收起后，不会计入搜索索引的待完成数量。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(PickPicTheme.ink, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var activitySection: some View {
        settingsSection(title: "当前活动") {
            if photoLibrary.isVisualScanning {
                activityRow(
                    icon: "viewfinder",
                    title: "正在检查照片内容",
                    detail: "\(photoLibrary.visualScanProgress) / \(photoLibrary.visualScanTotal) 项",
                    value: Double(photoLibrary.visualScanProgress),
                    total: Double(max(photoLibrary.visualScanTotal, 1))
                )
            }
            if photoLibrary.isSemanticIndexing {
                activityRow(
                    icon: "sparkles",
                    title: photoLibrary.semanticIndexPhase == "快速索引"
                        ? "整理可搜索照片"
                        : photoLibrary.semanticIndexPhase,
                    detail: "\(photoLibrary.semanticIndexProcessedCount) / \(photoLibrary.semanticIndexTotal) 张",
                    value: Double(photoLibrary.semanticIndexProcessedCount),
                    total: Double(max(photoLibrary.semanticIndexTotal, 1))
                )
            }
            if !isOrganizing {
                settingLabel(
                    icon: "checkmark.circle.fill",
                    title: "当前没有整理任务",
                    subtitle: photoLibrary.semanticModelStatus
                )
            }
            Divider().opacity(0.35)
            Button {
                photoLibrary.setIndexingPaused(!photoLibrary.isIndexingPaused)
            } label: {
                Label(
                    photoLibrary.isIndexingPaused ? "继续后台整理" : "暂停后台整理",
                    systemImage: photoLibrary.isIndexingPaused ? "play.fill" : "pause.fill"
                )
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(PickPicTheme.accentWash.opacity(0.65), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func activityRow(
        icon: String,
        title: String,
        detail: String,
        value: Double,
        total: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(detail)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(PickPicTheme.secondaryInk)
            }
            ProgressView(value: value, total: total)
                .tint(PickPicTheme.ink)
        }
    }

    private var insightGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            insightCard(.searchable)
            insightCard(.pending)
            insightCard(.refined)
            insightCard(.memories)
            insightCard(.analyzed)
            insightCard(.filtered)
        }
    }

    private func insightCard(_ insight: Insight) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: insightIcon(insight))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(PickPicTheme.secondaryInk)
            Text(insightValue(insight))
                .font(.system(size: 27, weight: .semibold, design: .rounded))
            Text(insightTitle(insight))
                .font(.system(size: 12, weight: .semibold))
            Text(insightDescription(insight))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(PickPicTheme.secondaryInk)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .padding(16)
        .background(.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func insightTitle(_ insight: Insight) -> String {
        switch insight {
        case .searchable: "可搜索照片"
        case .pending: "待整理照片"
        case .refined: "精细索引"
        case .memories: "回忆片段"
        case .analyzed: "已分析内容"
        case .filtered: "已收起内容"
        }
    }

    private func insightValue(_ insight: Insight) -> String {
        switch insight {
        case .searchable: "\(searchablePhotoCount)"
        case .pending: "\(pendingPhotoCount)"
        case .refined: "\(photoLibrary.refinedPhotoCount)"
        case .memories: "\(photoLibrary.memoryEvents.count)"
        case .analyzed: "\(photoLibrary.analyzedPhotoCount)"
        case .filtered: "\(photoLibrary.visuallyExcludedAssetCount)"
        }
    }

    private func insightIcon(_ insight: Insight) -> String {
        switch insight {
        case .searchable: "magnifyingglass"
        case .pending: "clock"
        case .refined: "wand.and.stars"
        case .memories: "rectangle.stack.fill"
        case .analyzed: "viewfinder"
        case .filtered: "line.3.horizontal.decrease.circle"
        }
    }

    private func insightDescription(_ insight: Insight) -> String {
        switch insight {
        case .searchable:
            "已完成快速索引、现在可以参与语义搜索的普通照片。"
        case .pending:
            "尚未完成快速索引的普通照片，不包含已经收起的内容。"
        case .refined:
            "使用更高质量图片生成语义索引的照片数量。它们仍属于可搜索照片，但搜索匹配会更准确。"
        case .memories:
            "按拍摄时间整理出的照片事件数量，例如一次聚会、一段出游或同一时段的连续拍摄。"
        case .analyzed:
            "已完成视觉内容检查的照片数量，用于识别文档、二维码等内容，并辅助整理回忆。"
        case .filtered:
            "视觉检查后被识别为文档、截图、二维码等内容并从图库中收起的数量。"
        }
    }

    private var indexingSection: some View {
        settingsSection(title: "索引与 iCloud") {
            settingRow(
                icon: "icloud.and.arrow.down",
                title: "继续精细索引",
                subtitle: refinedIndexSubtitle
            ) {
                Task { await photoLibrary.continueRefinedIndexing() }
            }
            .disabled(photoLibrary.isSemanticIndexing || photoLibrary.isVisualScanning)

            Divider().opacity(0.35)

            Toggle(isOn: $photoLibrary.downloadsICloudOnWiFiOnly) {
                settingLabel(
                    icon: "wifi",
                    title: "仅在 Wi-Fi 下拉取 iCloud",
                    subtitle: photoLibrary.isOnWiFi ? "当前已连接 Wi-Fi" : "当前未连接 Wi-Fi"
                )
            }
            .tint(PickPicTheme.ink)

            Divider().opacity(0.35)

            settingRow(
                icon: "arrow.clockwise",
                title: "重试未完成照片",
                subtitle: photoLibrary.semanticIndexFailed > 0
                    ? "还有 \(photoLibrary.semanticIndexFailed) 张等待重试"
                    : "当前没有失败任务"
            ) {
                Task { await photoLibrary.retryFailedIndexing() }
            }
            .disabled(photoLibrary.semanticIndexFailed == 0)
        }
    }

    private var storageSection: some View {
        settingsSection(title: "存储与数据") {
            HStack(spacing: 13) {
                settingLabel(
                    icon: "internaldrive",
                    title: "本地缓存",
                    subtitle: "索引、视觉分析与回忆整理数据"
                )
                Spacer()
                Text(formattedCacheSize)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(PickPicTheme.secondaryInk)
            }

            Divider().opacity(0.35)

            settingRow(
                icon: "trash",
                title: "清除缓存",
                subtitle: "保留照片、收藏与搜索偏好"
            ) {
                clearCacheConfirmation = true
            }
            .disabled(photoLibrary.isManagingCache || photoLibrary.isSemanticIndexing || photoLibrary.isVisualScanning)

            Divider().opacity(0.35)

            settingRow(
                icon: "arrow.triangle.2.circlepath",
                title: "重建语义索引",
                subtitle: "保留视觉分析和回忆整理结果"
            ) {
                rebuildIndexConfirmation = true
            }
            .disabled(photoLibrary.isManagingCache || photoLibrary.isSemanticIndexing || photoLibrary.isVisualScanning)
        }
        .task {
            await photoLibrary.refreshCacheUsage()
        }
    }

    private var preferencesSection: some View {
        settingsSection(title: "偏好") {
            settingRow(
                icon: "eraser",
                title: "清除搜索偏好",
                subtitle: "清除“不相关”反馈，不影响照片"
            ) {
                clearPreferencesConfirmation = true
            }
        }
    }

    private var privacyAndAboutSection: some View {
        settingsSection(title: "隐私与关于") {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 20, weight: .semibold))
                VStack(alignment: .leading, spacing: 5) {
                    Text("照片理解在本机完成")
                        .font(.system(size: 14, weight: .semibold))
                    Text("照片、索引与搜索内容保存在这台设备上。精细索引可能按你的网络设置拉取 iCloud 照片。")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PickPicTheme.secondaryInk)
                }
            }

            Divider().opacity(0.35)

            HStack(spacing: 11) {
                PickPicBrandMark(size: 34, cornerRadius: 10)
                Text("PickPic")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("版本 \(appVersion)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PickPicTheme.secondaryInk)
            }
        }
    }

    private func settingLabel(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 25)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PickPicTheme.secondaryInk)
            }
        }
    }

    private func settingsSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PickPicTheme.secondaryInk)
                .padding(.leading, 4)
            VStack(spacing: 14) {
                content()
            }
            .padding(16)
            .background(.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private func settingRow(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                settingLabel(icon: icon, title: title, subtitle: subtitle)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(PickPicTheme.secondaryInk.opacity(0.55))
            }
        }
        .buttonStyle(.plain)
    }

    private var indexingTitle: String {
        if photoLibrary.isIndexingPaused {
            return "后台整理已暂停"
        }
        if photoLibrary.isSemanticIndexing || photoLibrary.isVisualScanning {
            return photoLibrary.semanticIndexPhase
        }
        return "照片理解已就绪"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var refinedIndexSubtitle: String {
        let remaining = max(photoLibrary.assets.count - photoLibrary.refinedPhotoCount, 0)
        if photoLibrary.downloadsICloudOnWiFiOnly && !photoLibrary.isOnWiFi {
            return "约 \(remaining) 张待处理，连接 Wi-Fi 后可继续"
        }
        return "约 \(remaining) 张待处理，可能拉取 iCloud 照片"
    }

    private var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: photoLibrary.cacheByteCount, countStyle: .file)
    }

    private var organizationIcon: String {
        if photoLibrary.isIndexingPaused { return "pause.fill" }
        return isOrganizing ? "sparkles" : "checkmark"
    }

    private var organizationSummary: String {
        if photoLibrary.isVisualScanning {
            return "已检查 \(photoLibrary.visualScanProgress) / \(photoLibrary.visualScanTotal) 项 · 已收起 \(photoLibrary.visuallyExcludedAssetCount) 项"
        }
        if photoLibrary.isSemanticIndexing {
            return "已整理 \(photoLibrary.semanticIndexProcessedCount) / \(photoLibrary.semanticIndexTotal) 张 · 现有结果可搜索"
        }
        return "\(searchablePhotoCount) 张可搜索 · \(photoLibrary.visuallyExcludedAssetCount) 项已收起"
    }
}
