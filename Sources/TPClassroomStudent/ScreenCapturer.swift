import Foundation
import ScreenCaptureKit
import CoreImage
import CoreMedia
import CoreVideo
import ImageIO
import ClassroomKit

enum CaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? { "No display was found to capture." }
}

/// Captures the main display with ScreenCaptureKit and turns frames into JPEGs.
/// ScreenCaptureKit only delivers a frame when something on screen changes,
/// so an idle screen uses almost no network.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Called on a background queue with each new JPEG frame.
    var frameHandler: (@Sendable (Data) -> Void)?
    /// Called if macOS stops the capture (display change, permission removed…).
    var stopHandler: (@Sendable () -> Void)?

    private let sampleQueue = DispatchQueue(label: "tpclassroom.capture", qos: .userInitiated)
    private let ciContext = CIContext()
    private let lock = NSLock()
    private var quality: Double = 0.5        // guarded by lock
    private var streamBroken = false         // guarded by lock

    // Only touched from apply()/stop(), which the agent runs one at a time.
    private var activeStream: SCStream?
    private var activeDisplayID: CGDirectDisplayID?

    func apply(_ settings: StreamSettings) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let configuration = SCStreamConfiguration()
        // Retina screens have more pixels than points: allow capturing up to the real pixels for the best picture.
        var pixelScale = 1.0
        if let mode = CGDisplayCopyDisplayMode(display.displayID), mode.width > 0 {
            pixelScale = max(1.0, Double(mode.pixelWidth) / Double(mode.width))
        }
        let scale = min(pixelScale, Double(settings.maxWidth) / Double(max(display.width, 1)))
        configuration.width = max(2, Int(Double(display.width) * scale) / 2 * 2)
        configuration.height = max(2, Int(Double(display.height) * scale) / 2 * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, settings.fps)))
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let broken: Bool = locked {
            quality = settings.quality
            return streamBroken
        }

        if let current = activeStream, activeDisplayID == display.displayID, !broken {
            try await current.updateConfiguration(configuration)
            return
        }

        await stop()
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        locked { streamBroken = false }
        activeStream = stream
        activeDisplayID = display.displayID
    }

    func stop() async {
        guard let current = activeStream else { return }
        activeStream = nil
        activeDisplayID = nil
        try? await current.stopCapture()
    }

    // MARK: - SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[SCStreamFrameInfo.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let jpegQuality: Double = locked { quality }
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): jpegQuality,
        ]
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else { return }
        frameHandler?(jpeg)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        locked { streamBroken = true }
        stopHandler?()
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
