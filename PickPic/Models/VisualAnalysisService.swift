import Photos
import UIKit
import Vision

struct PhotoVisualAnalysis: Codable {
    let assetID: String
    let modifiedAt: TimeInterval?
    let textAreaRatio: CGFloat
    let textBlockCount: Int
    let containsBarcode: Bool
    let classifications: [String: Float]
    let featurePrint: VNFeaturePrintObservation?
    private let featurePrintData: Data?

    init(
        assetID: String,
        modifiedAt: TimeInterval?,
        textAreaRatio: CGFloat,
        textBlockCount: Int,
        containsBarcode: Bool,
        featurePrint: VNFeaturePrintObservation?,
        classifications: [String: Float]
    ) {
        self.assetID = assetID
        self.modifiedAt = modifiedAt
        self.textAreaRatio = textAreaRatio
        self.textBlockCount = textBlockCount
        self.containsBarcode = containsBarcode
        self.classifications = classifications
        self.featurePrint = featurePrint
        featurePrintData = featurePrint.flatMap {
            try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
        }
    }

    var isLikelyDocument: Bool {
        let hasNonPhotoLabel = classifications.contains { label, confidence in
            confidence >= 0.3 && Self.nonPhotoLabels.contains(label)
        }

        return containsBarcode
            || hasNonPhotoLabel
            || (textBlockCount >= 3 && textAreaRatio >= 0.16)
            || textAreaRatio >= 0.28
    }

    private static let nonPhotoLabels: Set<String> = [
        "document", "menu", "poster", "screenshot", "text", "web site"
    ]

    private enum CodingKeys: String, CodingKey {
        case assetID
        case modifiedAt
        case textAreaRatio
        case textBlockCount
        case containsBarcode
        case featurePrintData
        case classifications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assetID = try container.decode(String.self, forKey: .assetID)
        modifiedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .modifiedAt)
        textAreaRatio = try container.decode(CGFloat.self, forKey: .textAreaRatio)
        textBlockCount = try container.decode(Int.self, forKey: .textBlockCount)
        containsBarcode = try container.decode(Bool.self, forKey: .containsBarcode)
        classifications = try container.decode([String: Float].self, forKey: .classifications)
        featurePrintData = try container.decodeIfPresent(Data.self, forKey: .featurePrintData)
        featurePrint = featurePrintData.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: $0)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(assetID, forKey: .assetID)
        try container.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
        try container.encode(textAreaRatio, forKey: .textAreaRatio)
        try container.encode(textBlockCount, forKey: .textBlockCount)
        try container.encode(containsBarcode, forKey: .containsBarcode)
        try container.encodeIfPresent(featurePrintData, forKey: .featurePrintData)
        try container.encode(classifications, forKey: .classifications)
    }
}

enum VisualAnalysisService {
    static func analyze(asset: PHAsset) async -> PhotoVisualAnalysis? {
        guard let image = await requestImage(for: asset),
              let cgImage = image.cgImage
        else {
            return nil
        }

        return await Task.detached(priority: .utility) {
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .fast
            textRequest.usesLanguageCorrection = false
            textRequest.automaticallyDetectsLanguage = true
            textRequest.minimumTextHeight = 0.025

            let barcodeRequest = VNDetectBarcodesRequest()
            let featureRequest = VNGenerateImageFeaturePrintRequest()
            let classificationRequest = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try handler.perform([textRequest, barcodeRequest, featureRequest, classificationRequest])
            } catch {
                return nil
            }

            let textObservations = textRequest.results ?? []
            let textArea = textObservations.reduce(CGFloat.zero) { partial, observation in
                partial + observation.boundingBox.width * observation.boundingBox.height
            }
            let classifications = Dictionary(
                uniqueKeysWithValues: (classificationRequest.results ?? [])
                    .filter { $0.confidence >= 0.08 }
                    .prefix(12)
                    .map { ($0.identifier.lowercased(), $0.confidence) }
            )

            return PhotoVisualAnalysis(
                assetID: asset.localIdentifier,
                modifiedAt: assetModifiedAt(for: asset),
                textAreaRatio: min(textArea, 1),
                textBlockCount: textObservations.count,
                containsBarcode: !(barcodeRequest.results ?? []).isEmpty,
                featurePrint: featureRequest.results?.first,
                classifications: classifications
            )
        }.value
    }

    static func assetModifiedAt(for asset: PHAsset) -> TimeInterval? {
        (asset.modificationDate ?? asset.creationDate)?.timeIntervalSinceReferenceDate
    }

    private static func requestImage(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false

            let lock = NSLock()
            var finished = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 640, height: 640),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                continuation.resume(returning: image)
            }
        }
    }
}
