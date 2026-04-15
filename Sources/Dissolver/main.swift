import AppKit
import MetalKit
import ScreenCaptureKit
import simd

// MARK: - Metal shader

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VSOut {
    float4 position [[position]];
    float2 uv;
    float2 localUV;
    float  alpha;
    float  glow;
    float  local;
};

struct WindowUniforms {
    float2 origin;
    float2 size;
    float  progress;
    uint   cols;
    uint   rows;
};

static float hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hash(i);
    float b = hash(i + float2(1, 0));
    float c = hash(i + float2(0, 1));
    float d = hash(i + float2(1, 1));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

static float fbm(float2 p) {
    return valueNoise(p * 4.0)  * 0.55
         + valueNoise(p * 12.0) * 0.30
         + valueNoise(p * 36.0) * 0.15;
}

// 2D curl of a scalar noise field — divergence-free, so grains swirl rather
// than stagnate or converge.
static float2 curlNoise(float2 p) {
    const float eps = 0.015;
    float n_yp = valueNoise((p + float2(0.0,  eps)) * 5.0);
    float n_yn = valueNoise((p - float2(0.0,  eps)) * 5.0);
    float n_xp = valueNoise((p + float2(eps,  0.0)) * 5.0);
    float n_xn = valueNoise((p - float2(eps,  0.0)) * 5.0);
    return float2((n_yp - n_yn) / (2.0 * eps),
                 -(n_xp - n_xn) / (2.0 * eps));
}

vertex VSOut particleVertex(uint vid [[vertex_id]],
                            uint iid [[instance_id]],
                            constant WindowUniforms& u [[buffer(0)]]) {
    uint col = iid % u.cols;
    uint row = iid / u.cols;

    float fcol = float(col), frow = float(row);
    float fcols = float(u.cols), frows = float(u.rows);

    float2 cellLocal      = float2((fcol + 0.5) / fcols, (frow + 0.5) / frows);
    float2 cellSizeLocal  = float2(1.0 / fcols, 1.0 / frows);
    float2 cellScreen     = u.origin + cellLocal * u.size;
    float2 cellSizeScreen = cellSizeLocal * u.size;

    float h1 = hash(cellScreen * 173.0);
    float h2 = hash(cellScreen * 173.0 + float2(17.3, -8.1));
    float h3 = hash(cellScreen * 173.0 + float2(-4.7, 33.7));
    float h4 = hash(cellScreen * 173.0 + float2(91.1, 12.4));

    // Wavy dissolve front: fbm + top-goes-first bias + per-grain jitter.
    float frontField = fbm(cellScreen) * 0.55 + cellScreen.y * 0.45;
    float delay = frontField * 0.85 + h1 * 0.15;
    float local = clamp((u.progress - delay) / max(0.001, 1.0 - delay), 0.0, 1.5);

    float2 driftPos = cellScreen + float2(h2 * 0.1, -local * 0.15);
    float2 curl = curlNoise(driftPos);
    float2 velocity = float2(curl.x * 0.55,
                             -(0.18 + h3 * 0.22) + curl.y * 0.35);
    float2 gravity = float2(0.0, 0.05);
    float2 displacement = velocity * local + 0.5 * gravity * local * local;

    float angle = (h4 - 0.5) * 2.5 * local;
    float cs = cos(angle), sn = sin(angle);

    float ignite = smoothstep(0.0, 0.05, local);
    float sizeJitter = mix(1.0, 0.7 + h4 * 0.7, ignite);
    float scale = max(0.0, sizeJitter * (1.0 - local * 0.3));

    float2 corners[6] = {
        float2(-0.5, -0.5), float2( 0.5, -0.5), float2(-0.5,  0.5),
        float2(-0.5,  0.5), float2( 0.5, -0.5), float2( 0.5,  0.5)
    };
    float2 cornerUVs[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(0, 1), float2(1, 0), float2(1, 1)
    };
    float2 corner = corners[vid];
    float2 cuv    = cornerUVs[vid];
    float2 rotated = float2(cs * corner.x - sn * corner.y,
                            sn * corner.x + cs * corner.y);

    float2 posUV = cellScreen + rotated * cellSizeScreen * scale + displacement;
    float2 clip = float2(posUV.x * 2.0 - 1.0, 1.0 - posUV.y * 2.0);

    VSOut out;
    out.position = float4(clip, 0, 1);
    out.uv = cellLocal + (cuv - 0.5) * cellSizeLocal;
    out.localUV = cuv;
    out.alpha = 1.0 - smoothstep(0.30, 1.0, local);
    out.glow  = exp(-local * 10.0) * smoothstep(0.0, 0.04, local);
    out.local = local;
    return out;
}

fragment float4 particleFragment(VSOut in [[stage_in]],
                                 texture2d<float> screen [[texture(0)]]) {
    float r = length(in.localUV - 0.5);
    float ignite = smoothstep(0.0, 0.05, in.local);
    float threshold = mix(0.71, 0.50, ignite);
    if (r > threshold) discard_fragment();
    float disc = 1.0 - smoothstep(threshold - 0.02, threshold, r);

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 color = screen.sample(s, in.uv);

    float3 ember = float3(1.0, 0.72, 0.42);
    float3 rgb = mix(color.rgb, ember, in.glow * 0.25);

    return float4(rgb, color.a * in.alpha * disc);
}
"""

// MARK: - Screen capture

private struct CapturedWindow {
    let image: CGImage
    let originUV: CGPoint   // top-left in main-display UV space
    let sizeUV: CGSize
}

private func captureWindows() async throws -> (displaySize: CGSize, windows: [CapturedWindow]) {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    guard let display = content.displays.first else {
        throw NSError(domain: "Dissolver", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
    }
    let displaySize = display.frame.size
    let myPid = ProcessInfo.processInfo.processIdentifier

    let candidates = content.windows.filter { w in
        w.windowLayer == 0
            && w.isOnScreen
            && w.frame.width >= 50 && w.frame.height >= 50
            && (w.owningApplication?.processID).map { $0 != myPid } ?? false
    }

    let captured = await withTaskGroup(of: CapturedWindow?.self) { group in
        for w in candidates {
            let frame = w.frame
            let filter = SCContentFilter(desktopIndependentWindow: w)
            group.addTask {
                let config = SCStreamConfiguration()
                config.width  = Int(frame.width  * 2)
                config.height = Int(frame.height * 2)
                config.showsCursor = false
                config.capturesAudio = false
                guard let img = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config
                ) else { return nil }
                return CapturedWindow(
                    image: img,
                    originUV: CGPoint(x: frame.minX / displaySize.width,
                                      y: frame.minY / displaySize.height),
                    sizeUV: CGSize(width:  frame.width  / displaySize.width,
                                   height: frame.height / displaySize.height)
                )
            }
        }
        var result: [CapturedWindow] = []
        for await item in group { if let item { result.append(item) } }
        return result
    }

    return (displaySize, captured)
}

private func hideAllOtherApps() {
    let me = NSRunningApplication.current.processIdentifier
    for app in NSWorkspace.shared.runningApplications {
        guard app.activationPolicy == .regular, app.processIdentifier != me else { continue }
        app.hide()
    }
}

// MARK: - Renderer

private final class DissolveRenderer: NSObject, MTKViewDelegate {
    private struct Entry {
        let texture: MTLTexture
        let originUV: simd_float2
        let sizeUV: simd_float2
        let cols: UInt32
        let rows: UInt32
    }
    private struct Uniforms {
        var origin: simd_float2
        var size: simd_float2
        var progress: Float
        var cols: UInt32
        var rows: UInt32
    }

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let entries: [Entry]
    private let startTime = CACurrentMediaTime()
    private let duration: CFTimeInterval
    private let onComplete: () -> Void
    private var finished = false

    init(device: MTLDevice,
         windows: [CapturedWindow],
         displaySize: CGSize,
         duration: CFTimeInterval,
         onComplete: @escaping () -> Void) {
        self.commandQueue = device.makeCommandQueue()!
        self.duration = duration
        self.onComplete = onComplete

        let library = try! device.makeLibrary(source: shaderSource, options: nil)
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
        let particlePts: CGFloat = 1.5
        self.entries = windows.map { w in
            let tex = try! loader.newTexture(cgImage: w.image, options: [
                .SRGB: false,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            ])
            let widthPts  = w.sizeUV.width  * displaySize.width
            let heightPts = w.sizeUV.height * displaySize.height
            return Entry(
                texture: tex,
                originUV: simd_float2(Float(w.originUV.x), Float(w.originUV.y)),
                sizeUV: simd_float2(Float(w.sizeUV.width), Float(w.sizeUV.height)),
                cols: UInt32(max(8, Int(widthPts  / particlePts))),
                rows: UInt32(max(8, Int(heightPts / particlePts)))
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
            var uniforms = Uniforms(
                origin: entry.originUV, size: entry.sizeUV,
                progress: progress, cols: entry.cols, rows: entry.rows
            )
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
            encoder.setFragmentTexture(entry.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
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

// MARK: - App

private final class TransparentMTKView: MTKView {
    override var isOpaque: Bool { false }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var renderer: DissolveRenderer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                let capture = try await captureWindows()
                guard let screen = NSScreen.main, !capture.windows.isEmpty else {
                    NSApp.terminate(nil); return
                }

                let device = MTLCreateSystemDefaultDevice()!
                let view = TransparentMTKView(frame: screen.frame, device: device)
                view.colorPixelFormat = .bgra8Unorm
                view.framebufferOnly = true
                view.layer?.isOpaque = false
                view.layer?.backgroundColor = .clear
                view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                view.preferredFramesPerSecond = 60
                view.enableSetNeedsDisplay = false
                view.isPaused = false

                let renderer = DissolveRenderer(
                    device: device,
                    windows: capture.windows,
                    displaySize: capture.displaySize,
                    duration: 2.5
                ) { [weak self] in
                    self?.window?.orderOut(nil)
                    NSApp.terminate(nil)
                }
                view.delegate = renderer
                self.renderer = renderer

                let win = NSWindow(contentRect: screen.frame,
                                   styleMask: .borderless,
                                   backing: .buffered,
                                   defer: false,
                                   screen: screen)
                // AppKit may animate a newly shown borderless window; that makes the
                // replacement screenshot appear to scale in before the real window hides.
                win.animationBehavior = .none
                win.isOpaque = false
                win.backgroundColor = .clear
                win.hasShadow = false
                win.level = .screenSaver
                win.ignoresMouseEvents = true
                win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                win.contentView = view
                win.orderFrontRegardless()
                self.window = win

                // Let the overlay paint a frame before we hide the real windows underneath.
                try? await Task.sleep(nanoseconds: 33_000_000)
                hideAllOtherApps()
            } catch {
                FileHandle.standardError.write(Data("dissolver failed: \(error)\n".utf8))
                NSApp.terminate(nil)
            }
        }
    }
}

// MARK: - Entry point

let args = CommandLine.arguments
let runFlag = "--__run"

// Re-exec ourselves detached so the caller's shell returns immediately.
if !args.contains(runFlag) {
    let child = Process()
    child.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: args[0])
    child.arguments = [runFlag]
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    do { try child.run() } catch {
        FileHandle.standardError.write(Data("dissolver: failed to spawn: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

// Ignore SIGHUP so we survive the parent shell closing its tty mid-animation.
signal(SIGHUP, SIG_IGN)

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
