import SwiftUI

struct AmbientSearchBar: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 18, weight: .medium))

                Text("描述一段你想找的回忆")
                    .font(.system(size: 15.5, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.34), in: Circle())
            }
            .foregroundStyle(PickPicTheme.ink.opacity(0.7))
            .padding(.leading, 17)
            .padding(.trailing, 10)
            .frame(height: 54)
            .materialSurface(radius: 19, shadow: 0.07)
        }
        .buttonStyle(.plain)
    }
}

struct SearchView: View {
    @ObservedObject var photoLibrary: PhotoLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SemanticSearchResult] = []
    @State private var isSearching = false
    @State private var isDebouncing = false
    @State private var searchProgress: SemanticSearchProgress?
    @State private var selectedResult: SemanticSearchResult?
    @FocusState private var focused: Bool

    private let suggestions = ["去年夏天的海边", "和朋友吃饭", "下雨天散步", "有橘色晚霞的照片"]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.20, green: 0.26, blue: 0.27),
                    Color(red: 0.09, green: 0.10, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 12) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 38, height: 38)
                            .background(.white.opacity(0.1), in: Circle())
                    }

                    HStack(spacing: 11) {
                        Image(systemName: "text.magnifyingglass")
                        TextField("描述一段回忆", text: $query)
                            .focused($focused)
                            .submitLabel(.search)
                        if !query.isEmpty {
                            Button(action: { query = "" }) {
                                Image(systemName: "xmark.circle.fill")
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 56)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(.white.opacity(0.22), lineWidth: 0.7)
                    }
                }
                .foregroundStyle(.white)

                Text(query.isEmpty ? "可以这样找" : results.isEmpty ? "没有找到相似回忆" : "找到了这些回忆")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                if query.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                query = suggestion
                            } label: {
                                HStack {
                                    Text(suggestion)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "arrow.up.left")
                                        .opacity(0.45)
                                }
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.white.opacity(0.82))
                                .padding(.vertical, 17)
                            }
                            Divider().overlay(.white.opacity(0.12))
                        }
                    }
                } else {
                    semanticResults
                }

                Spacer()
            }
            .padding(20)
        }
        .onAppear { focused = true }
        .fullScreenCover(item: $selectedResult) { result in
            PhotoDetailView(
                assets: results.map(\.asset),
                initialAssetID: result.asset.localIdentifier,
                query: query,
                photoLibrary: photoLibrary
            ) { assetID in
                results.removeAll { $0.id == assetID }
            }
        }
        .task(id: query) {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                results = []
                isSearching = false
                isDebouncing = false
                searchProgress = nil
                return
            }

            isDebouncing = true
            isSearching = false
            searchProgress = nil
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            isDebouncing = false
            isSearching = true
            let activeQuery = query
            results = await photoLibrary.search(activeQuery) { progress in
                await MainActor.run {
                    guard query == activeQuery else { return }
                    searchProgress = progress
                }
            }
            guard !Task.isCancelled, query == activeQuery else { return }
            isSearching = false
        }
    }

    private var semanticResults: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isSearching || isDebouncing {
                SearchProgressCard(
                    isDebouncing: isDebouncing,
                    progress: searchProgress
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack {
                Text("\(results.count) 个匹配结果")
                Spacer()
                if isSearching || isDebouncing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.7))
                    Text(isDebouncing ? "等待输入完成" : "正在搜索")
                } else if photoLibrary.isVisualScanning {
                    Text("增量扫描中 \(photoLibrary.visualScanProgress)/\(photoLibrary.visualScanTotal)")
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.58))

            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                    ForEach(results) { result in
                        Button {
                            focused = false
                            selectedResult = result
                        } label: {
                            SquarePhotoAssetImage(asset: result.asset)
                                .overlay(alignment: .topTrailing) {
                                    if photoLibrary.isFavorite(result.asset) {
                                        Image(systemName: "heart.fill")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(7)
                                            .background(.black.opacity(0.42), in: Circle())
                                            .padding(5)
                                    }
                                }
                                .overlay(alignment: .bottomLeading) {
                                    Text(result.reason)
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(6)
                                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                                        .padding(5)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isSearching)
        .animation(.easeInOut(duration: 0.25), value: isDebouncing)
    }
}

private struct SearchProgressCard: View {
    let isDebouncing: Bool
    let progress: SemanticSearchProgress?

    private let phases: [(SemanticSearchProgress.Phase, String, String)] = [
        (.understanding, "理解描述", "text.bubble"),
        (.comparing, "比对照片", "photo.stack"),
        (.ranking, "整理结果", "sparkles")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: currentIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .symbolEffect(.pulse, isActive: true)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(currentTitle)
                        .font(.system(size: 14, weight: .semibold))
                    Text(currentDetail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                }
            }

            HStack(spacing: 7) {
                ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                    Capsule()
                        .fill(color(for: phase.0))
                        .frame(height: 4)
                    if index < phases.count - 1 {
                        Circle()
                            .fill(.white.opacity(0.18))
                            .frame(width: 4, height: 4)
                    }
                }
            }

            HStack {
                ForEach(phases, id: \.0) { phase in
                    Label(phase.1, systemImage: phase.2)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(labelColor(for: phase.0))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.13), lineWidth: 0.7)
        }
    }

    private var currentTitle: String {
        if isDebouncing { return "等待你完成描述" }
        switch progress?.phase {
        case .understanding: return "正在理解你的描述"
        case .comparing: return "正在照片中寻找相似画面"
        case .ranking: return "正在整理最相关的回忆"
        case nil: return "正在准备语义搜索"
        }
    }

    private var currentDetail: String {
        guard !isDebouncing else { return "输入停顿后会自动开始搜索" }
        guard let progress else { return "正在唤醒本地语义模型" }
        if progress.phase == .comparing {
            return "已比对 \(progress.completed) / \(progress.total) 张已索引照片"
        }
        return progress.phase == .understanding
            ? "将文字转换为可比较的语义特征"
            : "按相似程度排列候选照片"
    }

    private var currentIcon: String {
        if isDebouncing { return "ellipsis" }
        switch progress?.phase {
        case .understanding: return "text.bubble"
        case .comparing: return "photo.stack"
        case .ranking: return "sparkles"
        case nil: return "brain"
        }
    }

    private func color(for phase: SemanticSearchProgress.Phase) -> Color {
        guard !isDebouncing, let progress else { return .white.opacity(0.16) }
        if phase == progress.phase, progress.total > 0 {
            return .white.opacity(0.4 + 0.6 * Double(progress.completed) / Double(progress.total))
        }
        return phaseOrder(phase) < phaseOrder(progress.phase) ? .white : .white.opacity(0.16)
    }

    private func labelColor(for phase: SemanticSearchProgress.Phase) -> Color {
        guard !isDebouncing, let progress else { return .white.opacity(0.3) }
        return phaseOrder(phase) <= phaseOrder(progress.phase) ? .white.opacity(0.78) : .white.opacity(0.3)
    }

    private func phaseOrder(_ phase: SemanticSearchProgress.Phase) -> Int {
        switch phase {
        case .understanding: return 0
        case .comparing: return 1
        case .ranking: return 2
        }
    }
}
