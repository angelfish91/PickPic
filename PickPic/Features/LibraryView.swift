import Photos
import SwiftUI

struct LibraryView: View {
    @ObservedObject var photoLibrary: PhotoLibraryStore
    @State private var selectedPhoto: PhotoBrowserSelection?
    @State private var visiblePhotoCount = 50

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
    private let pageSize = 50

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("你的照片")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PickPicTheme.secondaryInk)
                        Text("图库")
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(photoLibrary.assets.count) 张照片")
                        if photoLibrary.excludedAssetCount > 0 {
                            Text("已过滤 \(photoLibrary.excludedAssetCount) 张非照片内容")
                                .opacity(0.72)
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PickPicTheme.secondaryInk)
                }
                .padding(.horizontal, 18)

                if photoLibrary.isVisualScanning || photoLibrary.visualScanProgress > 0 {
                    visualScanStatus
                        .padding(.horizontal, 18)
                }

                if photoLibrary.assets.isEmpty {
                    PhotoPermissionState(photoLibrary: photoLibrary)
                        .padding(.horizontal, 18)
                } else {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(photoLibrary.assets.prefix(visiblePhotoCount), id: \.localIdentifier) { asset in
                            Button {
                                selectedPhoto = PhotoBrowserSelection(asset: asset)
                            } label: {
                                ZStack(alignment: .topLeading) {
                                    SquarePhotoAssetImage(asset: asset)
                                    LivePhotoBadge(asset: asset)
                                }
                            }
                            .buttonStyle(.plain)
                            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                        }
                    }

                    if visiblePhotoCount < photoLibrary.assets.count {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .onAppear {
                                visiblePhotoCount = min(
                                    visiblePhotoCount + pageSize,
                                    photoLibrary.assets.count
                                )
                            }
                    }
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 112)
        }
        .fullScreenCover(item: $selectedPhoto) { selection in
            PhotoDetailView(
                assets: photoLibrary.assets,
                initialAssetID: selection.asset.localIdentifier,
                photoLibrary: photoLibrary
            )
        }
        .onAppear {
            photoLibrary.beginPhotoBrowsing()
        }
        .onDisappear {
            photoLibrary.endPhotoBrowsing()
        }
    }

    private var visualScanStatus: some View {
        HStack(spacing: 12) {
            Image(systemName: photoLibrary.isVisualScanning ? "viewfinder" : "checkmark.circle.fill")
                .font(.system(size: 19, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(photoLibrary.isVisualScanning ? "正在理解照片内容" : "视觉扫描完成")
                    .font(.system(size: 14, weight: .semibold))
                Text("增量分析 \(photoLibrary.visualScanProgress)/\(photoLibrary.visualScanTotal)，过滤 \(photoLibrary.visuallyExcludedAssetCount) 张文档或二维码")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PickPicTheme.secondaryInk)
                Text(photoLibrary.semanticModelStatus)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PickPicTheme.secondaryInk)
                if photoLibrary.isSemanticIndexing {
                    Text("\(photoLibrary.semanticIndexPhase) \(photoLibrary.semanticIndexProgress + photoLibrary.semanticIndexFailed)/\(photoLibrary.semanticIndexTotal)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PickPicTheme.secondaryInk)
                    ProgressView(
                        value: Double(photoLibrary.semanticIndexProgress + photoLibrary.semanticIndexFailed),
                        total: Double(max(photoLibrary.semanticIndexTotal, 1))
                    )
                    .tint(PickPicTheme.ink)
                } else if photoLibrary.semanticIndexFailed > 0 {
                    Button("重试 \(photoLibrary.semanticIndexFailed) 张未完成照片") {
                        Task { await photoLibrary.retryFailedIndexing() }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                }
                if photoLibrary.isVisualScanning {
                    ProgressView(
                        value: Double(photoLibrary.visualScanProgress),
                        total: Double(max(photoLibrary.visualScanTotal, 1))
                    )
                    .tint(PickPicTheme.ink)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct PhotoPermissionState: View {
    @ObservedObject var photoLibrary: PhotoLibraryStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: photoLibrary.isLoading ? "hourglass" : "photo.on.rectangle.angled")
                .font(.system(size: 38, weight: .light))
            Text(photoLibrary.isLoading ? "正在读取照片" : "允许访问照片后，这里会显示你的图库")
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
            Button("请求照片权限") {
                Task { await photoLibrary.start() }
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(PickPicTheme.secondaryInk)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(.white.opacity(0.38), in: RoundedRectangle(cornerRadius: 25, style: .continuous))
    }
}
