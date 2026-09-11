import MetalKit
import MetalPerformanceShaders
import CoreVideo
import KoffeeLidCore

public struct PlaneUniforms {
    var angle: Float
    var blurStrength: Float
    var zoom: Float
    var perspective: Float
    var edgeSoftness: Float
    var shading: Float
    var voidColor: SIMD4<Float>
}

/// Full-screen Metal view that draws the captured desktop as the "inner screen" behind the folding display.
///
/// The angle is pulled every frame from `angleProvider` (main thread) so motion is as smooth as
/// the display, not as the 30 Hz sensor. Blur levels are rendered at 1, 1/2, 1/4 and 1/8 of the
/// source size and only when a new frame arrived, which keeps a 4K capture cheap enough for 120 Hz.
public final class PlaneRenderer: MTKView, MTKViewDelegate {
    public var angleProvider: (() -> Float)?
    public var parameters: EffectParameters = .default
    public var onFirstFrameRendered: (() -> Void)?
    public private(set) var hasContent = false

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private lazy var loader = MTKTextureLoader(device: device!)
    private let lock = NSLock()
    private var pending: CVPixelBuffer?
    private var pendingImage: CGImage?
    private var source: MTLTexture?
    private var scaled: [MTLTexture] = []
    private var blurred: [MTLTexture] = []
    private var scalers: [MPSImageBilinearScale] = []
    private var blurs: [MPSImageGaussianBlur] = []
    private var blurredForSize: (Int, Int) = (0, 0)
    private var firstFrameReported = false
    private let inflight = DispatchSemaphore(value: 2)
    private static let levelDivisors = [1, 2, 4, 8]
    private static let levelSigmasPer1000px: [Float] = [2, 3, 4, 5]   // = 2, 6, 16, 40 in full-res pixels

    public init?(frame: CGRect, metalDevice: MTLDevice? = nil) {
        guard let device = metalDevice ?? MTLCreateSystemDefaultDevice(), let q = device.makeCommandQueue() else { return nil }
        queue = q
        do {
            let lib = try device.makeLibrary(source: PlaneShader.source, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "planeVertex")
            desc.fragmentFunction = lib.makeFunction(name: "planeFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("PlaneRenderer: pipeline failed: \(error)")
            return nil
        }
        super.init(frame: frame, device: device)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        colorPixelFormat = .bgra8Unorm
        // The capture is tagged sRGB; tag the layer the same so the compositor colour-matches it to the
        // panel and the overlay is indistinguishable from the real desktop at fold 0.
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        framebufferOnly = true
        preferredFramesPerSecond = 120
        layer?.isOpaque = true
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("unsupported") }

    /// Called from the capture queue.
    public func submit(pixelBuffer: CVPixelBuffer) {
        lock.lock(); pending = pixelBuffer; lock.unlock()
    }

    /// A still to show until the stream delivers its first frame.
    public func submit(image: CGImage) {
        lock.lock(); if pending == nil { pendingImage = image }; lock.unlock()
    }

    /// Forget the current desktop image; the next session reports its first frame again.
    public func clearContent() {
        lock.lock(); pending = nil; pendingImage = nil; lock.unlock()
        source = nil; hasContent = false; firstFrameReported = false
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        lock.lock(); let buffer = pending; let image = pendingImage; pending = nil; pendingImage = nil; lock.unlock()
        var fresh = false
        if let buffer, let tex = makeTexture(from: buffer) { source = tex; fresh = true }
        else if let image, let tex = try? loader.newTexture(cgImage: image, options: [.SRGB: false, .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)]) { source = tex; fresh = true }
        guard let source, let drawable = currentDrawable, let rpd = currentRenderPassDescriptor else { return }
        hasContent = true
        let angle = angleProvider?() ?? 0

        inflight.wait()
        guard let cmd = queue.makeCommandBuffer() else { inflight.signal(); return }
        cmd.addCompletedHandler { [inflight] _ in inflight.signal() }

        ensureBlurTextures(width: source.width, height: source.height)
        let blurActive = parameters.blurStrength > 0 && abs(angle) > 0.002 && blurred.count == 4
        if blurred.count == 4, fresh {
            for i in 0..<4 {
                scalers[i].encode(commandBuffer: cmd, sourceTexture: source, destinationTexture: scaled[i])
                blurs[i].encode(commandBuffer: cmd, sourceTexture: scaled[i], destinationTexture: blurred[i])
            }
        }
        var u = PlaneUniforms(angle: angle,
                              blurStrength: blurActive ? Float(parameters.blurStrength) : 0,
                              zoom: Float(parameters.zoomStrength),
                              perspective: Float(parameters.perspectiveStrength),
                              edgeSoftness: Float(parameters.edgeSoftness),
                              shading: Float(parameters.shading),
                              voidColor: SIMD4(0, 0, 0, 1))
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { inflight.signal(); return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(source, index: 0)
        for i in 0..<4 { enc.setFragmentTexture(blurActive ? blurred[i] : source, index: i + 1) }
        enc.setFragmentBytes(&u, length: MemoryLayout<PlaneUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()

        if !firstFrameReported { firstFrameReported = true; DispatchQueue.main.async { self.onFirstFrameRendered?() } }
    }

    private func makeTexture(from buffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        var cvTex: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard r == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        return tex
    }

    private func ensureBlurTextures(width: Int, height: Int) {
        guard blurredForSize != (width, height), let device else { return }
        var s: [MTLTexture] = [], b: [MTLTexture] = []
        for d in Self.levelDivisors {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: max(1, width / d), height: max(1, height / d), mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .private
            if let t1 = device.makeTexture(descriptor: desc), let t2 = device.makeTexture(descriptor: desc) { s.append(t1); b.append(t2) }
        }
        if s.count == 4 {
            scaled = s; blurred = b
            let scale = Float(height) / 1000
            scalers = Self.levelDivisors.map { _ in MPSImageBilinearScale(device: device) }
            blurs = Self.levelSigmasPer1000px.map { MPSImageGaussianBlur(device: device, sigma: $0 * scale) }
            blurs.forEach { $0.edgeMode = .clamp }
        } else {
            scaled = []; blurred = []; scalers = []; blurs = []
            NSLog("PlaneRenderer: failed to allocate blur textures (\(s.count)/4 at \(width)x\(height)); blur disabled")
        }
        blurredForSize = (width, height)
    }
}
