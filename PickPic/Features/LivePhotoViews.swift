import Photos
import PhotosUI
import SwiftUI

struct LivePhotoBadge: View {
    let asset: PHAsset

    var body: some View {
        if asset.mediaSubtypes.contains(.photoLive) {
            Label("LIVE", systemImage: "livephoto")
                .font(.system(size: 8, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .foregroundStyle(.white)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(6)
        }
    }
}

struct InlineLivePhotoView: UIViewRepresentable {
    let asset: PHAsset
    let onDoubleTap: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.22
        longPress.cancelsTouchesInView = false
        longPress.delegate = context.coordinator
        view.addGestureRecognizer(longPress)

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = context.coordinator
        view.addGestureRecognizer(doubleTap)

        context.coordinator.view = view
        context.coordinator.assetID = asset.localIdentifier
        context.coordinator.onDoubleTap = onDoubleTap
        requestLivePhoto(for: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        context.coordinator.onDoubleTap = onDoubleTap
        if context.coordinator.assetID != asset.localIdentifier {
            context.coordinator.assetID = asset.localIdentifier
            view.livePhoto = nil
            requestLivePhoto(for: view, coordinator: context.coordinator)
        }
    }

    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) {
        view.stopPlayback()
        if coordinator.requestID != PHInvalidImageRequestID {
            PHImageManager.default().cancelImageRequest(coordinator.requestID)
        }
    }

    private func requestLivePhoto(for view: PHLivePhotoView, coordinator: Coordinator) {
        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        coordinator.requestID = PHImageManager.default().requestLivePhoto(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { livePhoto, info in
            guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
            guard let livePhoto else { return }
            DispatchQueue.main.async {
                guard coordinator.assetID == asset.localIdentifier else { return }
                view.livePhoto = livePhoto
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var view: PHLivePhotoView?
        var requestID = PHInvalidImageRequestID
        var assetID = ""
        var onDoubleTap: ((CGPoint) -> Void)?

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let view, view.livePhoto != nil else { return }
            switch gesture.state {
            case .began:
                view.startPlayback(with: .full)
            case .ended, .cancelled, .failed:
                view.stopPlayback()
            default:
                break
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let view, view.bounds.width > 0, view.bounds.height > 0 else { return }
            let point = gesture.location(in: view)
            onDoubleTap?(
                CGPoint(
                    x: min(max(point.x / view.bounds.width, 0), 1),
                    y: min(max(point.y / view.bounds.height, 0), 1)
                )
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
