import MetalKit
import simd

final class DissolveRenderer: NSObject, MTKViewDelegate {
    private struct WindowEntry {
        let texture: MTLTexture
        let originUV: simd_float2
        let sizeUV: simd_float2
        let cols: UInt32
        let rows: UInt32
    }

    private struct WindowUniforms {
        var origin: simd_float2
        var size: simd_float2
        var progress: Float
        var cols: UInt32
        var rows: UInt32
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let entries: [WindowEntry]
    private let startTime: CFTimeInterval = CACurrentMediaTime()
    private let duration: CFTimeInterval
    private let onComplete: () -> Void
    private var finished = false

    init(device: MTLDevice,
         windows: [CapturedWindow],
         displaySize: CGSize,
         duration: CFTimeInterval,
         onComplete: @escaping () -> Void) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.duration = duration
        self.onComplete = onComplete

        let shaderURL = Bundle.module.url(forResource: "Shaders", withExtension: "metal")!
        let source = try! String(contentsOf: shaderURL, encoding: .utf8)
        let library = try! device.makeLibrary(source: source, options: nil)

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction   = library.makeFunction(name: "particleVertex")
        desc.fragmentFunction = library.makeFunction(name: "particleFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.pipeline = try! device.makeRenderPipelineState(descriptor: desc)

        let loader = MTKTextureLoader(device: device)
        let particlePts: CGFloat = 1.5    // fine grains

        self.entries = windows.map { w in
            let tex = try! loader.newTexture(cgImage: w.image, options: [
                .SRGB: false,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            ])
            let widthPts  = w.sizeUV.width  * displaySize.width
            let heightPts = w.sizeUV.height * displaySize.height
            let cols = max(8, Int(widthPts  / particlePts))
            let rows = max(8, Int(heightPts / particlePts))
            return WindowEntry(
                texture: tex,
                originUV: simd_float2(Float(w.originUV.x), Float(w.originUV.y)),
                sizeUV: simd_float2(Float(w.sizeUV.width), Float(w.sizeUV.height)),
                cols: UInt32(cols),
                rows: UInt32(rows)
            )
        }

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        let progress = Float(min(1.0, (CACurrentMediaTime() - startTime) / duration))

        encoder.setRenderPipelineState(pipeline)

        for entry in entries {
            var uniforms = WindowUniforms(
                origin: entry.originUV,
                size: entry.sizeUV,
                progress: progress,
                cols: entry.cols,
                rows: entry.rows
            )
            encoder.setVertexBytes(&uniforms,
                                   length: MemoryLayout<WindowUniforms>.size,
                                   index: 0)
            encoder.setFragmentTexture(entry.texture, index: 0)
            encoder.drawPrimitives(type: .triangle,
                                   vertexStart: 0,
                                   vertexCount: 6,
                                   instanceCount: Int(entry.cols * entry.rows))
        }

        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        if progress >= 1.0 && !finished {
            finished = true
            DispatchQueue.main.async { [onComplete] in onComplete() }
        }
    }
}
