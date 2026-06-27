import CoreLocation
import ImageIO
import Photos
import SwiftUI
import UIKit

struct PhotoBrowserSelection: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

struct PhotoDetailView: View {
    let assets: [PHAsset]
    let initialAssetID: String
    let query: String?
    let photoLibrary: PhotoLibraryStore
    var onMarkedIrrelevant: ((String) -> Void)?
    private let assetIndexByID: [String: Int]

    @Environment(\.dismiss) private var dismiss
    @State private var currentAssetID: String
    @State private var currentAssetIsFavorite: Bool
    @State private var metadataPresented = false
    @State private var shareImage: ShareImage?

    init(
        assets: [PHAsset],
        initialAssetID: String,
        query: String? = nil,
        photoLibrary: PhotoLibraryStore,
        onMarkedIrrelevant: ((String) -> Void)? = nil
    ) {
        self.assets = assets
        self.initialAssetID = initialAssetID
        self.query = query
        self.photoLibrary = photoLibrary
        self.onMarkedIrrelevant = onMarkedIrrelevant
        assetIndexByID = Dictionary(
            uniqueKeysWithValues: assets.enumerated().map { ($0.element.localIdentifier, $0.offset) }
        )
        _currentAssetID = State(initialValue: initialAssetID)
        _currentAssetIsFavorite = State(
            initialValue: assets.first(where: { $0.localIdentifier == initialAssetID })
                .map(photoLibrary.isFavorite) ?? false
        )
    }

    private var currentAsset: PHAsset {
        assets[currentIndex]
    }

    private var currentIndex: Int {
        assetIndexByID[currentAssetID] ?? 0
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(assets.indices, id: \.self) { index in
                        let asset = assets[index]
                        OriginalPhotoPage(
                            asset: asset,
                            isActive: index == currentIndex,
                            shouldLoadDetailedImage: abs(index - currentIndex) <= 1
                        )
                        .containerRelativeFrame(.horizontal)
                        .id(asset.localIdentifier)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(
                id: Binding(
                    get: { Optional(currentAssetID) },
                    set: { if let assetID = $0 { currentAssetID = assetID } }
                )
            )
            .scrollClipDisabled(false)
            .simultaneousGesture(verticalMetadataGesture)

            VStack {
                topBar
                Spacer()
                if !metadataPresented {
                    actionBar
                }
            }
            .padding(20)

            if metadataPresented {
                PhotoMetadataPanel(asset: currentAsset) {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        metadataPresented = false
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $shareImage) { item in
            ActivityView(items: [item.image])
        }
        .onAppear {
            currentAssetID = initialAssetID
            photoLibrary.beginPhotoBrowsing()
        }
        .onChange(of: initialAssetID) { _, assetID in
            currentAssetID = assetID
        }
        .onChange(of: currentAssetID) { _, _ in
            currentAssetIsFavorite = photoLibrary.isFavorite(currentAsset)
        }
        .onDisappear {
            photoLibrary.endPhotoBrowsing()
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.down")
                    .detailControl()
            }
            Spacer()
            Text("\(currentIndex + 1) / \(assets.count)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var actionBar: some View {
        HStack(spacing: 18) {
            detailAction(
                title: currentAssetIsFavorite ? "已收藏" : "收藏",
                icon: currentAssetIsFavorite ? "heart.fill" : "heart"
            ) {
                photoLibrary.toggleFavorite(currentAsset)
                currentAssetIsFavorite.toggle()
            }

            detailAction(title: "分享", icon: "square.and.arrow.up") {
                Task {
                    if let image = await PhotoOriginalLoader.image(for: currentAsset) {
                        shareImage = ShareImage(image: image)
                    }
                }
            }

            detailAction(title: "信息", icon: "info.circle") {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    metadataPresented = true
                }
            }

            if let query {
                detailAction(title: "不相关", icon: "hand.thumbsdown") {
                    let assetID = currentAsset.localIdentifier
                    photoLibrary.markIrrelevant(currentAsset, for: query)
                    onMarkedIrrelevant?(assetID)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.18), lineWidth: 0.7) }
    }

    private var verticalMetadataGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                if value.translation.height < -55 {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        metadataPresented = true
                    }
                }
            }
    }

    private func detailAction(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(minWidth: 48)
        }
        .buttonStyle(.plain)
    }
}

private struct OriginalPhotoPage: View {
    let asset: PHAsset
    let isActive: Bool
    let shouldLoadDetailedImage: Bool
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var livePhotoZoomRequest: PhotoZoomRequest?
    @State private var isPhotoZoomed = false

    var body: some View {
        Group {
            if let image {
                ZStack {
                    ZoomablePhotoView(
                        image: image,
                        externalZoomRequest: livePhotoZoomRequest,
                        onZoomChange: { isPhotoZoomed = $0 }
                    )
                    if asset.mediaSubtypes.contains(.photoLive), isActive, !isPhotoZoomed {
                        InlineLivePhotoView(asset: asset) { normalizedPoint in
                            livePhotoZoomRequest = PhotoZoomRequest(
                                id: UUID(),
                                normalizedPoint: normalizedPoint
                            )
                        }
                    }
                }
            } else if isLoading {
                ProgressView("正在读取原图")
                    .tint(.white)
                    .foregroundStyle(.white.opacity(0.72))
            } else if loadFailed {
                ContentUnavailableView(
                    "无法读取原图",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text("照片可能尚未从 iCloud 下载完成")
                )
                .foregroundStyle(.white)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: asset.localIdentifier) {
            isLoading = true
            loadFailed = false
            let preview = await PhotoDisplayLoader.preview(for: asset)
            guard !Task.isCancelled else { return }
            image = preview
            isLoading = false
            loadFailed = preview == nil
        }
        .task(id: "\(asset.localIdentifier)-detail-\(shouldLoadDetailedImage)") {
            guard shouldLoadDetailedImage else { return }

            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            if let detailed = await PhotoDisplayLoader.detailedImage(for: asset),
               !Task.isCancelled {
                image = detailed
            }
        }
    }
}

private struct PhotoZoomRequest: Equatable {
    let id: UUID
    let normalizedPoint: CGPoint
}

private struct ZoomablePhotoView: UIViewRepresentable {
    let image: UIImage
    let externalZoomRequest: PhotoZoomRequest?
    let onZoomChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onZoomChange: onZoomChange)
    }

    func makeUIView(context: Context) -> ZoomScrollView {
        let scrollView = ZoomScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.panGestureRecognizer.isEnabled = false

        let imageView = context.coordinator.imageView
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        scrollView.addSubview(imageView)
        scrollView.zoomImageView = imageView

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: ZoomScrollView, context: Context) {
        context.coordinator.onZoomChange = onZoomChange
        let imageView = context.coordinator.imageView
        if imageView.image !== image {
            imageView.image = image
            scrollView.setZoomScale(1, animated: false)
        }
        imageView.frame = scrollView.bounds
        scrollView.contentSize = scrollView.bounds.size
        context.coordinator.centerImage()

        if let externalZoomRequest,
           context.coordinator.lastExternalZoomRequestID != externalZoomRequest.id {
            context.coordinator.lastExternalZoomRequestID = externalZoomRequest.id
            let point = CGPoint(
                x: externalZoomRequest.normalizedPoint.x * scrollView.bounds.width,
                y: externalZoomRequest.normalizedPoint.y * scrollView.bounds.height
            )
            context.coordinator.toggleZoom(at: point)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        weak var scrollView: UIScrollView?
        var lastExternalZoomRequestID: UUID?
        var onZoomChange: (Bool) -> Void
        private var lastReportedZoomState = false

        init(onZoomChange: @escaping (Bool) -> Void) {
            self.onZoomChange = onZoomChange
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let isZoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            scrollView.panGestureRecognizer.isEnabled = isZoomed
            if isZoomed != lastReportedZoomState {
                lastReportedZoomState = isZoomed
                let onZoomChange = onZoomChange
                DispatchQueue.main.async {
                    onZoomChange(isZoomed)
                }
            }
            centerImage()
        }

        func centerImage() {
            guard let scrollView else { return }
            let horizontal = max(0, (scrollView.bounds.width - imageView.frame.width) / 2)
            let vertical = max(0, (scrollView.bounds.height - imageView.frame.height) / 2)
            scrollView.contentInset = UIEdgeInsets(
                top: vertical,
                left: horizontal,
                bottom: vertical,
                right: horizontal
            )
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            toggleZoom(at: gesture.location(in: imageView))
        }

        func toggleZoom(at point: CGPoint) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.1 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }

            let targetScale: CGFloat = 2.5
            let width = scrollView.bounds.width / targetScale
            let height = scrollView.bounds.height / targetScale
            let zoomRect = CGRect(
                x: point.x - width / 2,
                y: point.y - height / 2,
                width: width,
                height: height
            )
            scrollView.zoom(to: zoomRect, animated: true)
        }
    }
}

private final class ZoomScrollView: UIScrollView {
    weak var zoomImageView: UIImageView?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard zoomScale <= minimumZoomScale + 0.01, let zoomImageView else { return }
        zoomImageView.frame = bounds
        contentSize = bounds.size
    }
}

private struct PhotoMetadataPanel: View {
    let asset: PHAsset
    let onDismiss: () -> Void
    @State private var metadata: PhotoMetadata?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 16) {
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(width: 42, height: 5)
                    .frame(maxWidth: .infinity)

                HStack {
                    Text("照片信息")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Spacer()
                }

                if let metadata {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        metadataCell("拍摄时间", metadata.date, "calendar")
                        metadataCell("地点", metadata.location, "location")
                        metadataCell("设备", metadata.camera, "camera")
                        metadataCell("镜头", metadata.lens, "camera.aperture")
                        metadataCell("拍摄参数", metadata.exposure, "dial.medium")
                        metadataCell("分辨率", metadata.resolution, "rectangle.expand.vertical")
                    }
                } else {
                    ProgressView("正在读取照片信息")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .background(.ultraThinMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
            .overlay {
                UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
                    .stroke(.white.opacity(0.16), lineWidth: 0.7)
            }
            .contentShape(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
            .onTapGesture(perform: onDismiss)
        }
        .ignoresSafeArea(edges: .bottom)
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height > 55 { onDismiss() }
            }
        )
        .task(id: asset.localIdentifier) {
            metadata = await PhotoMetadataLoader.metadata(for: asset)
        }
    }

    private func metadataCell(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.white.opacity(0.58))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.48))
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PhotoMetadata {
    let date: String
    let location: String
    let camera: String
    let lens: String
    let exposure: String
    let resolution: String
}

private enum PhotoMetadataLoader {
    static func metadata(for asset: PHAsset) async -> PhotoMetadata {
        let properties = await imageProperties(for: asset)
        let exif = properties?[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties?[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]

        let make = tiff[kCGImagePropertyTIFFMake as String] as? String
        let model = tiff[kCGImagePropertyTIFFModel as String] as? String
        let lens = exif[kCGImagePropertyExifLensModel as String] as? String
        let focal = (exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue
        let aperture = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue
        let exposureTime = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
        let isoValues = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber]

        var exposure: [String] = []
        if let focal { exposure.append(String(format: "%.0f mm", focal)) }
        if let aperture { exposure.append(String(format: "ƒ/%.1f", aperture)) }
        if let exposureTime, exposureTime > 0 {
            exposure.append(exposureTime < 1 ? "1/\(Int((1 / exposureTime).rounded())) s" : String(format: "%.1f s", exposureTime))
        }
        if let iso = isoValues?.first { exposure.append("ISO \(iso.intValue)") }

        return PhotoMetadata(
            date: asset.creationDate?.formatted(.dateTime.year().month(.wide).day().hour().minute()) ?? "未知",
            location: await locationText(asset.location),
            camera: [make, model].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "未知设备",
            lens: lens ?? "未知镜头",
            exposure: exposure.joined(separator: " · ").nilIfEmpty ?? "无拍摄参数",
            resolution: "\(asset.pixelWidth) × \(asset.pixelHeight)"
        )
    }

    private static func locationText(_ location: CLLocation?) async -> String {
        guard let coordinate = location?.coordinate else { return "无位置信息" }
        let coordinateText = String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
        guard let location else { return coordinateText }

        return await withCheckedContinuation { continuation in
            CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
                let placemark = placemarks?.first
                let name = [
                    placemark?.locality,
                    placemark?.administrativeArea,
                    placemark?.country
                ]
                .compactMap { $0 }
                .reduce(into: [String]()) { result, component in
                    if !result.contains(component) { result.append(component) }
                }
                .joined(separator: " · ")
                continuation.resume(returning: name.nilIfEmpty ?? coordinateText)
            }
        }
    }

    private static func imageProperties(for asset: PHAsset) async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.version = .current
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard let data,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: properties)
            }
        }
    }
}

private struct ShareImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private enum PhotoDisplayLoader {
    private static let manager = PHCachingImageManager()
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        cache.totalCostLimit = 160 * 1024 * 1024
        return cache
    }()

    @MainActor
    static func preview(for asset: PHAsset) async -> UIImage? {
        let screen = UIScreen.main.bounds.size
        let scale = UIScreen.main.scale
        let longestSide = max(screen.width, screen.height) * scale * 1.25
        return await image(for: asset, longestSide: longestSide, quality: "preview")
    }

    static func detailedImage(for asset: PHAsset) async -> UIImage? {
        await image(for: asset, longestSide: 3072, quality: "detail")
    }

    private static func image(
        for asset: PHAsset,
        longestSide: CGFloat,
        quality: String
    ) async -> UIImage? {
        let key = "\(asset.localIdentifier)-\(quality)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.version = .current
        options.isNetworkAccessAllowed = true

        let image = await PhotoRequest.image(
            manager: manager,
            for: asset,
            targetSize: CGSize(width: longestSide, height: longestSide),
            contentMode: .aspectFit,
            options: options
        )
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }
}

private enum PhotoOriginalLoader {
    static func image(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .none
            options.version = .current
            options.isNetworkAccessAllowed = true

            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) {
                data, _, _, _ in
                continuation.resume(returning: data.flatMap(UIImage.init(data:)))
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        guard !isEmpty else { return nil }
        return self
    }
}

private extension View {
    func detailControl() -> some View {
        self
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(.ultraThinMaterial, in: Circle())
            .overlay { Circle().stroke(.white.opacity(0.18), lineWidth: 0.7) }
    }
}
