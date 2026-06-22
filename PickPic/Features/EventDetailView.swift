import AVKit
import Photos
import SwiftUI

struct EventDetailView: View {
    let event: PhotoEvent
    let photoLibrary: PhotoLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhoto: PhotoBrowserSelection?
    @State private var isSlideshowPresented = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PickPicTheme.canvas.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 20) {
                    hero

                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title)
                                .font(.system(size: 32, weight: .semibold, design: .serif))
                            Text(event.subtitle)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(PickPicTheme.secondaryInk)
                        }
                        Spacer()
                        Button {
                            isSlideshowPresented = true
                        } label: {
                            Label("预览回忆", systemImage: "play.rectangle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(PickPicTheme.ink, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 18)

                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(event.assets, id: \.localIdentifier) { asset in
                            Button {
                                selectedPhoto = PhotoBrowserSelection(asset: asset)
                            } label: {
                                ZStack(alignment: .topLeading) {
                                    PhotoAssetImage(asset: asset)
                                        .aspectRatio(1, contentMode: .fit)
                                    LivePhotoBadge(asset: asset)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.bottom, 28)
            }
            .ignoresSafeArea(edges: .top)

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle().stroke(.white.opacity(0.35), lineWidth: 0.7)
                    }
            }
            .foregroundStyle(.white)
            .padding(18)
        }
        .fullScreenCover(item: $selectedPhoto) { selection in
            PhotoDetailView(
                assets: event.assets,
                initialAssetID: selection.asset.localIdentifier,
                photoLibrary: photoLibrary
            )
        }
        .fullScreenCover(isPresented: $isSlideshowPresented) {
            LiveMemorySlideshow(assets: event.assets)
        }
        .onAppear {
            photoLibrary.beginPhotoBrowsing()
        }
        .onDisappear {
            photoLibrary.endPhotoBrowsing()
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            PhotoAssetImage(asset: event.coverAsset)
            LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .center, endPoint: .bottom)
            Text(event.startDate.formatted(.dateTime.year().month(.wide).day()))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .padding(20)
        }
        .frame(height: 330)
        .frame(maxWidth: .infinity)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 28, bottomTrailingRadius: 28))
    }

}

private struct LiveMemorySlideshow: View {
    private enum TransitionStyle: CaseIterable {
        case dissolve
        case fromLeft
        case fromRight
        case fromTop
        case fromBottom
        case scaleUp
        case scaleDown
    }

    let assets: [PHAsset]
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex = 0
    @State private var previousIndex = 0
    @State private var transitionStyle = TransitionStyle.dissolve
    @State private var transitionProgress = 1.0
    @State private var previewImages: [String: UIImage] = [:]
    @State private var musicPlayer: AVAudioPlayer?
    @State private var musicStyle = MemoryMusicStyle.warm
    @State private var videoProgress = 0.0
    @State private var videoStatus = ""
    @State private var isGeneratingVideo = false
    @State private var exportSucceeded = false
    @State private var errorMessage: String?
    @State private var musicTask: Task<Void, Never>?
    @State private var videoTask: Task<Void, Never>?

    private var previewAssets: [PHAsset] {
        MemoryVideoGenerator.previewAssets(from: assets)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let previousImage = image(at: previousIndex),
               let currentImage = image(at: currentIndex) {
                slideshowImage(previousImage)
                    .ignoresSafeArea()
                slideshowImage(currentImage)
                    .ignoresSafeArea()
                    .opacity(currentOpacity)
                    .scaleEffect(currentScale)
                    .offset(currentOffset)
            } else {
                ProgressView("正在准备回忆")
                    .tint(.white)
                    .foregroundStyle(.white.opacity(0.75))
            }

            LinearGradient(
                colors: [.black.opacity(0.28), .clear, .black.opacity(0.38)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 42, height: 42)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    Button(action: generateVideo) {
                        Label(
                            isGeneratingVideo ? "导出中" : "导出视频",
                            systemImage: "square.and.arrow.up"
                        )
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 42)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .disabled(isGeneratingVideo)
                    Button(action: changeMusic) {
                        Label("换一首", systemImage: "music.note.list")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .frame(height: 42)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                Spacer()
                if isGeneratingVideo {
                    VStack(spacing: 8) {
                        ProgressView(value: videoProgress)
                            .tint(.white)
                            .frame(width: 210)
                        Text("\(videoStatus) \(Int(videoProgress * 100))%")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(16)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                }
            }
        }
        .persistentSystemOverlays(.hidden)
        .task {
            await preloadPreviewImages()
            await startMusic()
            guard availableAssets.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.4))
                transitionStyle = TransitionStyle.allCases.randomElement() ?? .dissolve
                previousIndex = currentIndex
                currentIndex = (currentIndex + 1) % availableAssets.count
                transitionProgress = 0
                withAnimation(.smooth(duration: 0.85)) {
                    transitionProgress = 1
                }
            }
        }
        .onDisappear {
            musicTask?.cancel()
            videoTask?.cancel()
            musicPlayer?.stop()
            musicPlayer = nil
        }
        .alert("无法导出视频", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("视频已保存", isPresented: $exportSucceeded) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("回忆视频已经保存到你的照片图库。")
        }
    }

    private var currentOpacity: Double {
        switch transitionStyle {
        case .dissolve, .scaleUp, .scaleDown:
            transitionProgress
        default:
            min(transitionProgress * 2, 1)
        }
    }

    private var currentScale: CGFloat {
        switch transitionStyle {
        case .scaleUp: 0.78 + transitionProgress * 0.22
        case .scaleDown: 1.22 - transitionProgress * 0.22
        default: 1
        }
    }

    private var currentOffset: CGSize {
        let remaining = 1 - transitionProgress
        switch transitionStyle {
        case .fromLeft: return CGSize(width: -UIScreen.main.bounds.width * remaining, height: 0)
        case .fromRight: return CGSize(width: UIScreen.main.bounds.width * remaining, height: 0)
        case .fromTop: return CGSize(width: 0, height: -UIScreen.main.bounds.height * remaining)
        case .fromBottom: return CGSize(width: 0, height: UIScreen.main.bounds.height * remaining)
        default: return .zero
        }
    }

    private var availableAssets: [PHAsset] {
        previewAssets.filter { previewImages[$0.localIdentifier] != nil }
    }

    private func image(at index: Int) -> UIImage? {
        guard availableAssets.indices.contains(index) else { return nil }
        return previewImages[availableAssets[index].localIdentifier]
    }

    private func slideshowImage(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }

    private func preloadPreviewImages() async {
        let targetSize = CGSize(
            width: UIScreen.main.bounds.width * UIScreen.main.scale,
            height: UIScreen.main.bounds.height * UIScreen.main.scale
        )
        for asset in previewAssets {
            guard !Task.isCancelled else { return }
            if let image = await requestSlideshowImage(for: asset, targetSize: targetSize) {
                previewImages[asset.localIdentifier] = image
            }
        }
        currentIndex = 0
        previousIndex = 0
    }

    private func requestSlideshowImage(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await PhotoRequest.image(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        )
    }

    private func startMusic() async {
        guard !previewAssets.isEmpty else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            let duration = Double(previewAssets.count) * 2.4
            let url = try await MemoryVideoGenerator.previewMusic(duration: duration, style: musicStyle)
            try Task.checkCancellation()
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 1
            player.play()
            musicPlayer = player
        } catch {
            // The slideshow remains usable if preview music cannot be prepared.
        }
    }

    private func changeMusic() {
        musicStyle = musicStyle.next
        musicTask?.cancel()
        musicPlayer?.stop()
        musicPlayer = nil
        musicTask = Task { await startMusic() }
    }

    private func generateVideo() {
        videoTask?.cancel()
        isGeneratingVideo = true
        videoProgress = 0
        videoStatus = "正在准备"
        videoTask = Task {
            var generatedVideoURL: URL?
            defer {
                if let generatedVideoURL {
                    try? FileManager.default.removeItem(at: generatedVideoURL)
                }
            }

            do {
                let videoURL = try await MemoryVideoGenerator.generate(
                    from: assets,
                    musicStyle: musicStyle
                ) { progress, status in
                    videoProgress = progress
                    videoStatus = status
                }
                generatedVideoURL = videoURL
                videoStatus = "正在保存到相册"
                try await MemoryVideoGenerator.saveToPhotoLibrary(videoURL)
                exportSucceeded = true
            } catch is CancellationError {
                videoStatus = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            isGeneratingVideo = false
            videoTask = nil
        }
    }
}

private struct MemoryVideoPreview: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer
    @State private var isSaving = false
    @State private var saved = false
    @State private var errorMessage: String?

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player)
                .ignoresSafeArea()
                .onAppear {
                    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                    try? AVAudioSession.sharedInstance().setActive(true)
                    player.isMuted = false
                    player.volume = 1
                    player.play()
                }

            VStack {
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 42, height: 42)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    Button(action: saveVideo) {
                        Label(saved ? "已保存" : (isSaving ? "保存中" : "保存"), systemImage: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .frame(height: 42)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .disabled(isSaving || saved)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                Spacer()
            }
        }
        .persistentSystemOverlays(.hidden)
        .alert("保存失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func saveVideo() {
        isSaving = true
        Task {
            do {
                try await MemoryVideoGenerator.saveToPhotoLibrary(url)
                saved = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
