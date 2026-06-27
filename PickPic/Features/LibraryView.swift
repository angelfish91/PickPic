import Photos
import SwiftUI

struct LibraryView: View {
    @ObservedObject var photoLibrary: PhotoLibraryStore
    @State private var selectedPhoto: PhotoBrowserSelection?
    @State private var visiblePhotoCount = 50

    private let columns = Array(repeating: GridItem(.flexible(), spacing: PickPicTheme.Spacing.xs), count: 3)
    private let pageSize = 50

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: PickPicTheme.Spacing.l) {
                libraryHeader
                    .padding(.horizontal, PickPicTheme.Spacing.m)

                if photoLibrary.assets.isEmpty {
                    PhotoPermissionState(photoLibrary: photoLibrary)
                        .padding(.horizontal, PickPicTheme.Spacing.m)
                } else {
                    LazyVGrid(columns: columns, spacing: PickPicTheme.Spacing.xs) {
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
                            .clipShape(RoundedRectangle(cornerRadius: PickPicTheme.Spacing.xs, style: .continuous))
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
            .padding(.top, PickPicTheme.Spacing.m)
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
            PhotoThumbnailPipeline.shared.stopPreheating()
        }
        .task(id: visiblePhotoCount) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }

            let start = min(
                visiblePhotoCount == pageSize ? 30 : visiblePhotoCount,
                photoLibrary.assets.count
            )
            let preheatCount = visiblePhotoCount == pageSize ? 60 : pageSize * 2
            let end = min(start + preheatCount, photoLibrary.assets.count)
            guard start < end else { return }
            PhotoThumbnailPipeline.shared.preheatLibraryGrid(
                Array(photoLibrary.assets[start..<end])
            )
        }
    }

    private var libraryHeader: some View {
        VStack(alignment: .leading, spacing: PickPicTheme.Spacing.l) {
            HStack(alignment: .top, spacing: PickPicTheme.Spacing.m) {
                VStack(alignment: .leading, spacing: PickPicTheme.Spacing.xs) {
                    Text("你的照片")
                        .font(PickPicTheme.AppFont.caption)
                        .foregroundStyle(PickPicTheme.secondaryInk)
                    Text("图库")
                        .font(PickPicTheme.AppFont.display)
                        .foregroundStyle(PickPicTheme.ink)
                }

                Spacer(minLength: PickPicTheme.Spacing.m)

                libraryPreviewStack
            }

            HStack(spacing: PickPicTheme.Spacing.s) {
                LibraryMetricPill(value: "\(photoLibrary.assets.count)", label: "可浏览")
                if photoLibrary.excludedAssetCount > 0 {
                    LibraryMetricPill(value: "\(photoLibrary.excludedAssetCount)", label: "已收起")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(PickPicTheme.Spacing.m)
        .background(PickPicTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: PickPicTheme.Radius.xl, style: .continuous))
        .overlay(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: PickPicTheme.Radius.xl, style: .continuous)
                .stroke(PickPicTheme.hairline, lineWidth: 0.7)
        }
    }

    @ViewBuilder
    private var libraryPreviewStack: some View {
        if photoLibrary.assets.isEmpty {
            ZStack {
                Circle()
                    .fill(PickPicTheme.accentWash.opacity(0.55))
                Image(systemName: "photo.stack")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(PickPicTheme.accent)
            }
            .frame(width: 72, height: 72)
        } else {
            ZStack {
                ForEach(Array(photoLibrary.assets.prefix(3).enumerated()), id: \.element.localIdentifier) { index, asset in
                    PhotoAssetImage(asset: asset)
                        .frame(width: 56, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: PickPicTheme.Radius.m, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: PickPicTheme.Radius.m, style: .continuous)
                                .stroke(.white.opacity(0.68), lineWidth: 1)
                        }
                        .rotationEffect(.degrees(Double(index - 1) * 7))
                        .offset(x: CGFloat(index - 1) * 18, y: CGFloat(abs(index - 1)) * 3)
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
                }
            }
            .frame(width: 112, height: 82)
        }
    }

}

struct PhotoPermissionState: View {
    @ObservedObject var photoLibrary: PhotoLibraryStore

    var body: some View {
        VStack(spacing: PickPicTheme.Spacing.m) {
            ZStack {
                Circle()
                    .fill(PickPicTheme.accentWash.opacity(0.55))
                Image(systemName: photoLibrary.isLoading ? "hourglass" : "photo.on.rectangle.angled")
                    .font(.system(size: 34, weight: .light))
            }
            .frame(width: 88, height: 88)

            VStack(spacing: PickPicTheme.Spacing.xs) {
                Text(photoLibrary.isLoading ? "正在读取照片" : "允许访问照片")
                    .font(PickPicTheme.AppFont.heading)
                Text(photoLibrary.isLoading ? "PickPic 正在准备你的本机照片索引" : "这里会显示可浏览、可搜索、已过滤后的照片图库")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PickPicTheme.secondaryInk)
                    .multilineTextAlignment(.center)
            }

            Button("请求照片权限") {
                Task { await photoLibrary.start() }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(minWidth: 144, minHeight: 44)
            .background(PickPicTheme.ink, in: Capsule())
            .buttonStyle(.plain)
        }
        .foregroundStyle(PickPicTheme.ink)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PickPicTheme.Spacing.l)
        .padding(.vertical, 56)
        .background(PickPicTheme.surface.opacity(0.58), in: RoundedRectangle(cornerRadius: PickPicTheme.Radius.xl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PickPicTheme.Radius.xl, style: .continuous)
                .stroke(PickPicTheme.hairline, lineWidth: 0.7)
        }
    }
}

private struct LibraryMetricPill: View {
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: PickPicTheme.Spacing.xs) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(PickPicTheme.ink)
            Text(label)
                .font(PickPicTheme.AppFont.micro)
                .foregroundStyle(PickPicTheme.secondaryInk)
        }
        .padding(.horizontal, PickPicTheme.Spacing.s)
        .frame(minHeight: 32)
        .background(PickPicTheme.surfaceRaised.opacity(0.72), in: Capsule())
    }
}
