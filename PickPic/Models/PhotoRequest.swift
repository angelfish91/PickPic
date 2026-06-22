import Photos
import UIKit

enum PhotoRequest {
    static func image(
        manager: PHImageManager = .default(),
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        options: PHImageRequestOptions,
        acceptsDegraded: Bool = false
    ) async -> UIImage? {
        let state = PhotoImageContinuationState()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.setContinuation(continuation)
                let requestID = manager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    options: options
                ) { image, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true || info?[PHImageErrorKey] != nil {
                        state.resume(returning: nil)
                        return
                    }

                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    guard acceptsDegraded || !isDegraded else { return }
                    state.resume(returning: image)
                }
                state.setRequestID(requestID, manager: manager)
            }
        } onCancel: {
            state.cancel(manager: manager)
        }
    }
}

private final class PhotoImageContinuationState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var requestID = PHInvalidImageRequestID
    private var isFinished = false

    func setContinuation(_ continuation: CheckedContinuation<UIImage?, Never>) {
        lock.lock()
        if isFinished {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }

        self.continuation = continuation
        lock.unlock()
    }

    func setRequestID(_ requestID: PHImageRequestID, manager: PHImageManager) {
        lock.lock()
        if isFinished {
            lock.unlock()
            cancel(requestID, manager: manager)
            return
        }

        self.requestID = requestID
        lock.unlock()
    }

    func resume(returning image: UIImage?) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }

        isFinished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: image)
    }

    func cancel(manager: PHImageManager) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }

        isFinished = true
        let requestID = requestID
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        cancel(requestID, manager: manager)
        continuation?.resume(returning: nil)
    }

    private func cancel(_ requestID: PHImageRequestID, manager: PHImageManager) {
        guard requestID != PHInvalidImageRequestID else { return }
        manager.cancelImageRequest(requestID)
    }
}
