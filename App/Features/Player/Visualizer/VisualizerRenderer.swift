import MetalKit
import QuartzCore
import SwiftUI

/// Field for field with `VisualizerUniforms` in VisualizerShaders.h: 32 bytes.
struct VisualizerUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var progress: Float
    var crossfade: Float
    var pixelRatio: Float
    var frequencyHistoryIndex: Float
    var unused: Float = 0
}

/// Draws the chosen program into an `MTKView`, a frame per display refresh at 60 Hz.
///
/// 60 rather than the 120 a ProMotion screen offers, because the motion is defined per
/// frame — the gravity, the smoothing, the history and the crossfade all count frames,
/// as Plexamp's do at the browser's 60.
///
/// Each frame ticks the feed once and draws. The four textures are tiny (the largest is
/// 64×32 half floats), so they are written whole every frame, into one of three sets so
/// the CPU never writes a texture the GPU may still be reading.
@MainActor
final class VisualizerRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary
    private var pipelines: [String: MTLRenderPipelineState] = [:]

    private struct Textures {
        let palette: MTLTexture
        let frequencies: MTLTexture
        let loudness: MTLTexture
        let history: MTLTexture
    }

    private static let framesInFlight = 3
    private let textureSets: [Textures]
    private var setIndex = 0
    private let inFlight = DispatchSemaphore(value: framesInFlight)

    private var halves = [Float16](repeating: 0, count: VisualizerHostState.bands * VisualizerHostState.historyRows)

    /// Seconds since the first renderer, so `u_time` stays small enough for the shaders'
    /// `sin`s to stay smooth. Plexamp's is seconds since the page loaded.
    private static let epoch = CACurrentMediaTime()

    let feed: VisualizerFeed
    var program: VisualizerProgram {
        didSet { feed.select(program) }
    }
    /// Draw at the screen's full resolution instead of the program's `pixels` across.
    /// Plexamp's Higher Quality Visualizers, off by default there too.
    var highQuality = false

    private static var instance: VisualizerRenderer?

    /// One for the app: the device, library and pipelines are made once, not every time
    /// the player opens.
    static func shared(feed: VisualizerFeed, program: VisualizerProgram) -> VisualizerRenderer? {
        if let instance {
            instance.program = program
            return instance
        }
        instance = VisualizerRenderer(feed: feed, program: program)
        return instance
    }

    private init?(feed: VisualizerFeed, program: VisualizerProgram) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary()
        else { return nil }

        func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            return device.makeTexture(descriptor: descriptor)
        }

        var sets: [Textures] = []
        for _ in 0..<Self.framesInFlight {
            guard let palette = texture(.rgba8Unorm, VisualizerPalette.size, 2),
                  let frequencies = texture(.r16Float, VisualizerHostState.bands, 2),
                  let loudness = texture(.r16Float, VisualizerLoudness.texels, 2),
                  let history = texture(.r16Float, VisualizerHostState.bands, VisualizerHostState.historyRows)
            else { return nil }
            sets.append(Textures(palette: palette, frequencies: frequencies, loudness: loudness, history: history))
        }

        self.device = device
        self.queue = queue
        self.library = library
        self.textureSets = sets
        self.feed = feed
        self.program = program
        super.init()
        feed.select(program)
    }

    /// The view the canvas hosts. Not opaque, so what is behind shows through the way it
    /// does through Plexamp's canvas; the drawable is sized here, from the program.
    func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = false
        view.enableSetNeedsDisplay = false
        view.isUserInteractionEnabled = false
        if let layer = view.layer as? CAMetalLayer {
            // The shaders' values are sRGB as they stand, as WebGL's are; nothing is
            // linearised on the way in or out.
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.magnificationFilter = .linear
        }
        view.delegate = self
        return view
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard sizeDrawable(of: view),
              let pipeline = pipeline(for: program, format: view.colorPixelFormat)
        else { return }

        inFlight.wait()
        feed.tick()

        let textures = textureSets[setIndex]
        setIndex = (setIndex + 1) % Self.framesInFlight
        upload(into: textures)

        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            inFlight.signal()
            return
        }

        let size = view.drawableSize
        var uniforms = VisualizerUniforms(
            resolution: SIMD2(Float(size.width), Float(size.height)),
            time: Float(CACurrentMediaTime() - Self.epoch),
            progress: feed.progress,
            crossfade: feed.crossfadeValue,
            pixelRatio: Float(view.bounds.width > 0 ? size.width / view.bounds.width : 1),
            frequencyHistoryIndex: Float(feed.host.historyIndex)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VisualizerUniforms>.stride, index: 0)
        encoder.setFragmentTexture(textures.palette, index: 0)
        encoder.setFragmentTexture(textures.frequencies, index: 1)
        encoder.setFragmentTexture(textures.loudness, index: 2)
        encoder.setFragmentTexture(textures.history, index: 3)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        // Explicitly `@Sendable`: Metal calls this on its own thread, and a closure
        // written here would otherwise be taken as main-actor and trap when it runs.
        let inFlight = inFlight
        commands.addCompletedHandler { @Sendable _ in inFlight.signal() }
        commands.present(drawable)
        commands.commit()
    }

    /// The program's `pixels` across, the height in proportion; or the screen's own
    /// resolution when that is smaller, or when high quality is on. The layer scales it
    /// up to fill the view.
    private func sizeDrawable(of view: MTKView) -> Bool {
        let bounds = view.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let scale = view.contentScaleFactor
        let native = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let factor = highQuality ? 1 : min(1, CGFloat(program.pixels) / native.width)
        let wanted = CGSize(
            width: max(1, (native.width * factor).rounded()),
            height: max(1, (native.height * factor).rounded())
        )
        if view.drawableSize != wanted { view.drawableSize = wanted }
        return true
    }

    private func pipeline(for program: VisualizerProgram, format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let cached = pipelines[program.function] { return cached }
        guard let vertex = library.makeFunction(name: "viz_vertex"),
              let fragment = library.makeFunction(name: program.function)
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = program.name
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        // No blending: the cleared target plus `vizOutput` already is what Plexamp's GL
        // blend produced.
        descriptor.colorAttachments[0].pixelFormat = format

        guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        pipelines[program.function] = state
        return state
    }

    private func upload(into textures: Textures) {
        feed.paletteTexels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            textures.palette.replace(
                region: MTLRegionMake2D(0, 0, VisualizerPalette.size, 2),
                mipmapLevel: 0, withBytes: base, bytesPerRow: VisualizerPalette.size * 4
            )
        }
        write(feed.host.frequencyTexels, to: textures.frequencies, width: VisualizerHostState.bands, height: 2)
        write(feed.loudnessTexels, to: textures.loudness, width: VisualizerLoudness.texels, height: 2)
        write(
            feed.host.historyTexels, to: textures.history,
            width: VisualizerHostState.bands, height: VisualizerHostState.historyRows
        )
    }

    private func write(_ values: [Float], to texture: MTLTexture, width: Int, height: Int) {
        let count = width * height
        guard values.count >= count, halves.count >= count else { return }
        for index in 0..<count { halves[index] = Float16(values[index]) }
        halves.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0, withBytes: base, bytesPerRow: width * MemoryLayout<Float16>.stride
            )
        }
    }
}

/// The renderer's view in SwiftUI. Paused rather than removed while the player is being
/// dragged, so picking it back up does not rebuild anything.
struct VisualizerCanvas: UIViewRepresentable {
    let renderer: VisualizerRenderer
    let program: VisualizerProgram
    let isPaused: Bool
    let highQuality: Bool

    func makeUIView(context: Context) -> MTKView {
        renderer.makeView()
    }

    func updateUIView(_ view: MTKView, context: Context) {
        if renderer.program != program { renderer.program = program }
        renderer.highQuality = highQuality
        view.isPaused = isPaused
    }

    static func dismantleUIView(_ view: MTKView, coordinator: ()) {
        view.isPaused = true
        view.delegate = nil
    }
}
