import SwiftUI

struct ProfileView: View {
    @ObservedObject var photoLibrary: PhotoLibraryStore
    @State private var clearPreferencesConfirmation = false

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
                organizationSection
                privacySection
                aboutSection
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
            insightCard(title: "精细索引", value: "\(photoLibrary.refinedPhotoCount)", icon: "wand.and.stars")
            insightCard(title: "回忆片段", value: "\(photoLibrary.memoryEvents.count)", icon: "rectangle.stack.fill")
            insightCard(title: "已分析内容", value: "\(photoLibrary.analyzedPhotoCount)", icon: "viewfinder")
            insightCard(title: "已过滤内容", value: "\(photoLibrary.visuallyExcludedAssetCount)", icon: "line.3.horizontal.decrease.circle")
        }
    }

    private func insightCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(PickPicTheme.secondaryInk)
            Text(value)
                .font(.system(size: 27, weight: .semibold, design: .rounded))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PickPicTheme.secondaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var organizationSection: some View {
        settingsSection(title: "整理与维护") {
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

            Divider().opacity(0.35)

            settingRow(
                icon: "eraser",
                title: "清除搜索偏好",
                subtitle: "清除“不相关”反馈，不影响照片"
            ) {
                clearPreferencesConfirmation = true
            }
        }
    }

    private var privacySection: some View {
        settingsSection(title: "隐私") {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 20, weight: .semibold))
                VStack(alignment: .leading, spacing: 5) {
                    Text("照片理解在本机完成")
                        .font(.system(size: 14, weight: .semibold))
                    Text("照片、索引与搜索内容保存在这台设备上。只有精细化 iCloud 照片时，系统照片框架可能下载原图。")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PickPicTheme.secondaryInk)
                }
            }
        }
    }

    private var aboutSection: some View {
        settingsSection(title: "关于") {
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
}
