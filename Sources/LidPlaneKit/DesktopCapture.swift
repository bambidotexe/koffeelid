import Foundation
import ScreenCaptureKit
import CoreGraphics

public enum ScreenCapturePermission {
    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }
    /// Shows the system prompt; returns the state as it is now, which is still not-granted while the user is
    /// looking at the dialog — never read it as a refusal. The dialog is the whole flow, so nothing here opens
    /// System Settings beside it.
    @discardableResult public static func request() -> Bool { CGRequestScreenCaptureAccess() }
}

/// BGRA capture of one display, excluding our own overlay window.
///
/// `prepare()` does the slow part (enumerating shareable content) without capturing anything, so
/// that `captureStill()` and `start()` can run the instant the lid begins to close. `start()` /
/// `stop()` may be called repeatedly; a stop that lands while a start is in flight wins.
public final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    public var onFrame: ((CVPixelBuffer) -> Void)?
    public var onError: ((Error) -> Void)?

    private let displayID: CGDirectDisplayID
    private let excludedWindowNumber: Int?
    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?
    private var stream: SCStream?
    private var gate = CaptureStartGate()
    private let outputQueue = DispatchQueue(label: "dev.rubens.koffeelid.capture", qos: .userInteractive)

    public init(displayID: CGDirectDisplayID, excludingWindowNumber: Int?) {
        self.displayID = displayID; self.excludedWindowNumber = excludingWindowNumber
    }

    public func prepare() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "DesktopCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "display not shareable"])
        }
        let excluded: [SCWindow] = excludedWindowNumber.flatMap { n in n >= 0 ? UInt32(exactly: n) : nil }
            .map { id in content.windows.filter { $0.windowID == id } } ?? []
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let config = SCStreamConfiguration()
        let scale = min(1.0, 2560.0 / Double(max(display.width, display.height)))
        let backing = CGDisplayPixelsWide(displayID) > display.width ? 2.0 : 1.0
        config.width = Int(Double(display.width) * backing * scale)
        config.height = Int(Double(display.height) * backing * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        self.filter = filter; self.config = config
    }

    /// One frame, right now (~20 ms), to bridge the gap until the stream is up.
    public func captureStill() async throws -> CGImage {
        if filter == nil { try await prepare() }
        guard let filter, let config else { throw NSError(domain: "DesktopCapture", code: 2) }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    public func start() async throws {
        let token = gate.beginStart()          // before the first await: a stop during prepare() must win too
        if filter == nil { try await prepare() }
        guard let filter, let config, stream == nil else { return }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        guard gate.isCurrent(token), self.stream == nil else { try? await stream.stopCapture(); return }
        self.stream = stream
    }

    public func stop() async {
        gate.stop()
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onError?(error)
    }
}
