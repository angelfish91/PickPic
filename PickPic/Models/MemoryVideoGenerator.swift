import AVFoundation
import CoreImage
import Photos
import UIKit

enum MemoryMusicStyle: Int, CaseIterable {
    case warm
    case journey
    case night
    case bright
    case calm
    case playful

    var name: String {
        switch self {
        case .warm: "暖阳"
        case .journey: "远行"
        case .night: "夜色"
        case .bright: "晴空"
        case .calm: "微风"
        case .playful: "雀跃"
        }
    }

    var next: MemoryMusicStyle {
        MemoryMusicStyle(rawValue: (rawValue + 1) % Self.allCases.count) ?? .warm
    }
}

enum MemoryVideoGenerator {
    private static let outputSize = CGSize(width: 720, height: 1280)
    private static let frameRate: Int32 = 30
    private static let secondsPerPhoto = 2.4
    private static let transitionDuration = 0.45

    private enum TransitionStyle: CaseIterable {
        case dissolve
        case slideFromLeft
        case slideFromRight
        case slideFromTop
        case slideFromBottom
        case zoomIn
        case zoomOut
    }

    static func generate(
        from assets: [PHAsset],
        musicStyle: MemoryMusicStyle = MemoryMusicStyle.allCases.randomElement() ?? .warm,
        progress: @escaping @MainActor (Double, String) -> Void
    ) async throws -> URL {
        let selectedAssets = selectAssets(from: assets)
        guard !selectedAssets.isEmpty else {
            throw MemoryVideoError.noPhotos
        }

        await progress(0.02, "正在准备照片")
        var images: [CIImage] = []
        for (index, asset) in selectedAssets.enumerated() {
            try Task.checkCancellation()
            if let image = await requestImage(for: asset),
               let ciImage = CIImage(image: image) {
                images.append(ciImage)
            }
            if asset.mediaSubtypes.contains(.photoLive) {
                images.append(contentsOf: await livePhotoFrames(for: asset))
            }
            await progress(
                0.05 + Double(index + 1) / Double(selectedAssets.count) * 0.25,
                "正在读取第 \(index + 1) 张照片"
            )
        }
        guard !images.isEmpty else {
            throw MemoryVideoError.photosUnavailable
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PickPic-\(UUID().uuidString).mp4")
        var cleanupURLs = [outputURL]
        defer {
            for url in cleanupURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(outputSize.width),
                AVVideoHeightKey: Int(outputSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 4_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height)
            ]
        )
        guard writer.canAdd(input) else {
            throw MemoryVideoError.writerUnavailable
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let framesPerPhoto = Int(secondsPerPhoto * Double(frameRate))
        let totalFrames = framesPerPhoto * images.count
        let transitionFrames = Int(transitionDuration * Double(frameRate))
        let transitions = (0..<max(images.count - 1, 0)).map { _ in
            TransitionStyle.allCases.randomElement() ?? .dissolve
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        let background = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: outputSize))

        for frameIndex in 0..<totalFrames {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(8))
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw MemoryVideoError.writerUnavailable
            }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer else {
                throw MemoryVideoError.writerUnavailable
            }

            let imageIndex = frameIndex / framesPerPhoto
            let localFrame = frameIndex % framesPerPhoto
            let localProgress = CGFloat(localFrame) / CGFloat(max(framesPerPhoto - 1, 1))
            var frame = fittedImage(images[imageIndex], progress: localProgress)
                .composited(over: background)

            if localFrame >= framesPerPhoto - transitionFrames, imageIndex + 1 < images.count {
                let opacity = CGFloat(localFrame - (framesPerPhoto - transitionFrames))
                    / CGFloat(max(transitionFrames, 1))
                let next = fittedImage(images[imageIndex + 1], progress: 0)
                switch transitions[imageIndex] {
                case .dissolve:
                    frame = next
                        .applyingFilter("CIColorMatrix", parameters: [
                            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
                        ])
                        .composited(over: frame)
                case .slideFromLeft:
                    let offset = -outputSize.width * (1 - opacity)
                    frame = next
                        .transformed(by: CGAffineTransform(translationX: offset, y: 0))
                        .composited(over: frame)
                case .slideFromRight:
                    let offset = outputSize.width * (1 - opacity)
                    frame = next
                        .transformed(by: CGAffineTransform(translationX: offset, y: 0))
                        .composited(over: frame)
                case .slideFromTop:
                    let offset = outputSize.height * (1 - opacity)
                    frame = next
                        .transformed(by: CGAffineTransform(translationX: 0, y: offset))
                        .composited(over: frame)
                case .slideFromBottom:
                    let offset = -outputSize.height * (1 - opacity)
                    frame = next
                        .transformed(by: CGAffineTransform(translationX: 0, y: offset))
                        .composited(over: frame)
                case .zoomIn:
                    frame = scaledTransitionImage(next, scale: 1.25 - opacity * 0.25)
                        .applyingFilter("CIColorMatrix", parameters: [
                            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
                        ])
                        .composited(over: frame)
                case .zoomOut:
                    frame = scaledTransitionImage(next, scale: 0.78 + opacity * 0.22)
                        .applyingFilter("CIColorMatrix", parameters: [
                            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
                        ])
                        .composited(over: frame)
                }
            }

            context.render(
                frame,
                to: pixelBuffer,
                bounds: CGRect(origin: .zero, size: outputSize),
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: frameRate)
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? MemoryVideoError.writerUnavailable
            }

            if frameIndex.isMultiple(of: 8) {
                await progress(
                    0.3 + Double(frameIndex + 1) / Double(totalFrames) * 0.55,
                    "正在制作回忆视频"
                )
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? MemoryVideoError.writerUnavailable
        }
        await progress(0.88, "正在生成背景音乐")
        let musicURL = try createMusicFile(
            duration: Double(totalFrames) / Double(frameRate),
            style: musicStyle
        )
        cleanupURLs.append(musicURL)
        await progress(0.94, "正在合成声音与画面")
        let finalURL = try await combine(videoURL: outputURL, musicURL: musicURL)
        await progress(1, "视频已生成")
        return finalURL
    }

    static func previewAssets(from assets: [PHAsset]) -> [PHAsset] {
        selectAssets(from: assets)
    }

    static func previewMusic(duration: Double, style: MemoryMusicStyle) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try createMusicFile(duration: duration, style: style)
        }.value
    }

    static func saveToPhotoLibrary(_ url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    private static func selectAssets(from assets: [PHAsset]) -> [PHAsset] {
        let sorted = assets.sorted {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }
        guard sorted.count > 12 else { return sorted }

        return (0..<12).map { index in
            let position = Double(index) * Double(sorted.count - 1) / 11
            return sorted[Int(position.rounded())]
        }
    }

    private static func requestImage(for asset: PHAsset) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await PhotoRequest.image(
            for: asset,
            targetSize: CGSize(width: 1440, height: 2560),
            contentMode: .aspectFill,
            options: options
        )
    }

    private static func livePhotoFrames(for asset: PHAsset) async -> [CIImage] {
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: {
            $0.type == .pairedVideo || $0.type == .fullSizePairedVideo
        }) else {
            return []
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PickPic-Live-\(UUID().uuidString).mov")
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let written = await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                continuation.resume(returning: error == nil)
            }
        }
        guard written else { return [] }

        let video = AVURLAsset(url: url)
        let duration = (try? await video.load(.duration).seconds) ?? 0
        guard duration > 0 else {
            return []
        }

        let generator = AVAssetImageGenerator(asset: video)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1440, height: 2560)
        let times = [duration * 0.35, duration * 0.7]
        var frames: [CIImage] = []
        for time in times {
            if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                frames.append(CIImage(cgImage: image))
            }
        }
        return frames
    }

    private static func fittedImage(_ image: CIImage, progress: CGFloat) -> CIImage {
        let extent = image.extent
        let fillScale = max(outputSize.width / extent.width, outputSize.height / extent.height)
        let zoom = 1 + progress * 0.06
        let scale = fillScale * zoom
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = (outputSize.width - scaled.extent.width) / 2 - scaled.extent.origin.x
        let y = (outputSize.height - scaled.extent.height) / 2 - scaled.extent.origin.y
        return scaled
            .transformed(by: CGAffineTransform(translationX: x, y: y))
            .cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    private static func scaledTransitionImage(_ image: CIImage, scale: CGFloat) -> CIImage {
        image
            .transformed(by: CGAffineTransform(
                translationX: -outputSize.width / 2,
                y: -outputSize.height / 2
            ))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: outputSize.width / 2,
                y: outputSize.height / 2
            ))
            .cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    private static func createMusicFile(duration: Double, style: MemoryMusicStyle) throws -> URL {
        let sampleRate = 44_100.0
        let totalFrames = AVAudioFrameCount(duration * sampleRate)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            throw MemoryVideoError.audioUnavailable
        }
        buffer.frameLength = totalFrames
        let music = musicDefinition(for: style)
        for channel in 0..<2 {
            guard let samples = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<Int(totalFrames) {
                let time = Double(frame) / sampleRate
                let noteIndex = Int(time / music.beatLength) % music.notes.count
                let beatProgress = time.truncatingRemainder(dividingBy: music.beatLength) / music.beatLength
                let envelope = pow(sin(.pi * beatProgress), music.envelopePower)
                    * max(0, min(min(time / 1.0, (duration - time) / 1.5), 1))
                let fundamental = sin(2 * .pi * music.notes[noteIndex] * time)
                let harmony = sin(
                    2 * .pi * music.notes[(noteIndex + music.harmonyOffset) % music.notes.count]
                        * time * music.harmonyRatio
                )
                let pulse = sin(2 * .pi * music.pulseFrequency * time) * music.pulseVolume
                samples[frame] = Float(
                    (fundamental * music.leadVolume + harmony * music.harmonyVolume + pulse) * envelope
                )
            }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PickPic-Music-\(UUID().uuidString).m4a")
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
        )
        try file.write(from: buffer)
        return url
    }

    private static func musicDefinition(for style: MemoryMusicStyle) -> (
        notes: [Double],
        beatLength: Double,
        envelopePower: Double,
        harmonyOffset: Int,
        harmonyRatio: Double,
        leadVolume: Double,
        harmonyVolume: Double,
        pulseFrequency: Double,
        pulseVolume: Double
    ) {
        switch style {
        case .warm:
            return ([261.63, 329.63, 392.00, 523.25], 1.2, 1.0, 2, 0.5, 0.27, 0.15, 1.2, 0.015)
        case .journey:
            return ([293.66, 440.00, 369.99, 587.33, 493.88], 0.72, 1.8, 3, 0.5, 0.24, 0.12, 2.8, 0.028)
        case .night:
            return ([220.00, 261.63, 329.63, 196.00], 1.8, 0.7, 1, 0.5, 0.20, 0.18, 0.5, 0.012)
        case .bright:
            return ([523.25, 659.25, 783.99, 659.25, 587.33], 0.48, 2.4, 2, 0.5, 0.20, 0.10, 4.0, 0.022)
        case .calm:
            return ([174.61, 220.00, 261.63, 329.63], 2.4, 0.55, 2, 1.0, 0.18, 0.14, 0.25, 0.008)
        case .playful:
            return ([392.00, 523.25, 659.25, 493.88, 587.33, 783.99], 0.36, 3.0, 3, 0.5, 0.18, 0.09, 5.5, 0.025)
        }
    }

    private static func combine(videoURL: URL, musicURL: URL) async throws -> URL {
        let videoAsset = AVURLAsset(url: videoURL)
        let musicAsset = AVURLAsset(url: musicURL)
        let videoDuration = try await videoAsset.load(.duration)
        let composition = AVMutableComposition()

        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let sourceMusic = try await musicAsset.loadTracks(withMediaType: .audio).first,
              let videoTrack = composition.addMutableTrack(
                  withMediaType: .video,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              ),
              let audioTrack = composition.addMutableTrack(
                  withMediaType: .audio,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else {
            throw MemoryVideoError.audioUnavailable
        }

        let range = CMTimeRange(start: .zero, duration: videoDuration)
        try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)
        try audioTrack.insertTimeRange(range, of: sourceMusic, at: .zero)

        let finalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PickPic-Final-\(UUID().uuidString).mp4")
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw MemoryVideoError.audioUnavailable
        }
        try await exporter.export(to: finalURL, as: .mp4)
        let finalAsset = AVURLAsset(url: finalURL)
        guard !(try await finalAsset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw MemoryVideoError.audioUnavailable
        }
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: musicURL)
        return finalURL
    }
}

enum MemoryVideoError: LocalizedError {
    case noPhotos
    case photosUnavailable
    case writerUnavailable
    case audioUnavailable

    var errorDescription: String? {
        switch self {
        case .noPhotos: "这组回忆中没有可用照片"
        case .photosUnavailable: "暂时无法读取这些照片，请检查网络后重试"
        case .writerUnavailable: "视频生成失败，请稍后重试"
        case .audioUnavailable: "背景音乐生成失败，请稍后重试"
        }
    }
}
