import SwiftUI

struct ProfileView: View {
    @ObservedObject var photoLibrary: PhotoLibraryStore
    @State private var clearPreferencesConfirmation = false
    @State private var clearCacheConfirmation = false
    @State private var rebuildIndexConfirmation = false
    @State private var selectedInsight: Insight?

    private enum Insight: String, Identifiable {
        case refined
        case memories
        case analyzed
        case filtered

        var id: String { rawValue }
    }

    private var totalPhotoCount: Int {
        photoLibrary.assets.count + photoLibrary.visuallyExcludedAssetCount
    }

    private var understoodCount: Int {
        min(photoLibrary.indexedPhotoCount, totalPhotoCount)
    }

    private var understandingProgress: Double {
        guard totalPhotoCount > 0 else { return 0 }
        return Double(understoodCount) / Double(totalPhotoCount)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 22) {
                header
                understandingCard
                insightGrid
                indexingSection
                storageSection
                preferencesSection
                privacyAndAboutSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 112)
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
        .sheet(item: $selectedInsight) { insight in
            insightExplanation(insight)
                .presentationDetents([.height(270)])
                .presentationDragIndicator(.visible)
                .presentationBackground(PickPicTheme.canvas)
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(indexingTitle)
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text(photoLibrary.semanticModelStatus)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                }
                Spacer()
                Image(systemName: photoLibrary.isIndexingPaused ? "pause.fill" : "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .symbolEffect(.pulse, isActive: photoLibrary.isSemanticIndexing && !photoLibrary.isIndexingPaused)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("\(understoodCount) / \(totalPhotoCount) 张可搜索")
                    Spacer()
                    Text(understandingProgress, format: .percent.precision(.fractionLength(0)))
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))

                ProgressView(value: understandingProgress)
                    .tint(.white)
            }

            Button {
                photoLibrary.setIndexingPaused(!photoLibrary.isIndexingPaused)
            } label: {
                Label(
                    photoLibrary.isIndexingPaused ? "继续后台整理" : "暂停后台整理",
                    systemImage: photoLibrary.isIndexingPaused ? "play.fill" : "pause.fill"
                )
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(.white.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(
            LinearGradient(
                colors: [PickPicTheme.ink, PickPicTheme.ink.opacity(0.78)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .shadow(color: .black.opacity(0.16), radius: 24, y: 12)
    }

    private var insightGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            insightCard(.refined)
            insightCard(.memories)
            insightCard(.analyzed)
            insightCard(.filtered)
        }
    }

    private func insightCard(_ insight: Insight) -> some View {
        Button {
            selectedInsight = insight
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: insightIcon(insight))
                        .font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .opacity(0.55)
                }
                .foregroundStyle(PickPicTheme.secondaryInk)
                Text(insightValue(insight))
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                Text(insightTitle(insight))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PickPicTheme.secondaryInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func insightExplanation(_ insight: Insight) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: insightIcon(insight))
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.55), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(insightTitle(insight))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(insightValue(insight))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PickPicTheme.secondaryInk)
                }
            }

            Text(insightDescription(insight))
                .font(.system(size: 14, weight: .medium))
                .lineSpacing(3)

            Text(insightRule(insight))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PickPicTheme.secondaryInk)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.48), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func insightTitle(_ insight: Insight) -> String {
        switch insight {
        case .refined: "精细索引"
        case .memories: "回忆片段"
        case .analyzed: "已分析内容"
        case .filtered: "已过滤内容"
        }
    }

    private func insightValue(_ insight: Insight) -> String {
        switch insight {
        case .refined: "\(photoLibrary.refinedPhotoCount)"
        case .memories: "\(photoLibrary.memoryEvents.count)"
        case .analyzed: "\(photoLibrary.analyzedPhotoCount)"
        case .filtered: "\(photoLibrary.visuallyExcludedAssetCount)"
        }
    }

    private func insightIcon(_ insight: Insight) -> String {
        switch insight {
        case .refined: "wand.and.stars"
        case .memories: "rectangle.stack.fill"
        case .analyzed: "viewfinder"
        case .filtered: "line.3.horizontal.decrease.circle"
        }
    }

    private func insightDescription(_ insight: Insight) -> String {
        switch insight {
        case .refined:
            "使用更高质量图片生成语义索引的照片数量。它们仍属于可搜索照片，但搜索匹配会更准确。"
        case .memories:
            "按拍摄时间整理出的照片事件数量，例如一次聚会、一段出游或同一时段的连续拍摄。"
        case .analyzed:
            "已完成视觉内容检查的照片数量，用于识别文档、二维码等内容，并辅助整理回忆。"
        case .filtered:
            "视觉检查后被识别为文档、截图、二维码等非普通照片内容的数量。"
        }
    }

    private func insightRule(_ insight: Insight) -> String {
        switch insight {
        case .refined:
            "统计口径：已完成高质量语义索引，不包含仅完成快速索引的照片。"
        case .memories:
            "统计口径：时间相近的照片聚为一组，每组至少包含 2 张未过滤照片。"
        case .analyzed:
            "统计口径：视觉分析缓存中存在有效结果的照片。"
        case .filtered:
            "统计口径：已分析内容中，被判定为文档、截图、二维码等的照片。"
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
        let remaining = max(totalPhotoCount - photoLibrary.refinedPhotoCount, 0)
        if photoLibrary.downloadsICloudOnWiFiOnly && !photoLibrary.isOnWiFi {
            return "约 \(remaining) 张待处理，连接 Wi-Fi 后可继续"
        }
        return "约 \(remaining) 张待处理，可能拉取 iCloud 照片"
    }

    private var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: photoLibrary.cacheByteCount, countStyle: .file)
    }
}
