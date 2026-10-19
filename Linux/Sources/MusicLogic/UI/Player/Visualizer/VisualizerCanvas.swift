import CEpoxy
import CGtk
import Foundation

/// Draws the chosen program into a GtkGLArea: the phone's `VisualizerRenderer`, in GL.
///
/// The four textures are tiny (the largest is 64×32 half floats), so they are written
/// whole every frame. Each program draws at its own `pixels` across, as Plexamp's do and
/// as their shapes were tuned for, into a texture that is then scaled up to fill the
/// area; Higher Quality Visualizers draws at the area's full resolution instead.
///
/// GTK composites the area as premultiplied alpha over what is behind it, which is what
/// the programs' `vizOutput` produces, so the cover's colour shows through the way it
/// does through Plexamp's canvas.
@MainActor
final class VisualizerCanvas {
    let area: Widget
    let feed: VisualizerFeed

    var program: VisualizerProgram {
        didSet { feed.select(program.data) }
    }
    var highQuality = false
    /// Called once, from realize, when there is no GL to draw with.
    var onFailure: (() -> Void)?
    private(set) var hasFailed = false

    private struct Compiled {
        let id: GLuint
        let resolution: GLint
        let time: GLint
        let progress: GLint
        let crossfade: GLint
        let pixelRatio: GLint
        let historyIndex: GLint
    }

    private var compiled: [String: Compiled] = [:]
    /// Programs this context would not compile, so they are not retried every frame.
    private var broken: Set<String> = []
    private var isES = false
    private var vertexArray: GLuint = 0
    private var palette: GLuint = 0
    private var frequencies: GLuint = 0
    private var loudness: GLuint = 0
    private var history: GLuint = 0
    private var framebuffer: GLuint = 0
    private var target: GLuint = 0
    private var targetSize = (width: GLint(0), height: GLint(0))

    /// Seconds since the first canvas, so `u.time` stays small enough for the shaders'
    /// `sin`s to stay smooth. Plexamp's is seconds since the page loaded.
    private static let epoch = g_get_monotonic_time()

    init(feed: VisualizerFeed, program: VisualizerProgram) {
        self.feed = feed
        self.program = program
        area = Widget(gtk_gl_area_new()!)
        area.hexpand().vexpand()
        gtk_gl_area_set_auto_render(area.widget.cast(), 0)
        feed.select(program.data)

        let reference = WeakReference(self)
        Signal.connect(area.widget, "realize") { reference.value?.realize() }
        Signal.connect(area.widget, "unrealize") { reference.value?.unrealize() }
        Signal.connectHandled(area.widget, "render", pointer: { _ in
            reference.value?.render()
            return true
        })
        area.keep(self)
    }

    func queueRender() {
        guard !hasFailed else { return }
        gtk_gl_area_queue_render(area.widget.cast())
    }

    // MARK: - Context

    private func realize() {
        let gl: UnsafeMutablePointer<GtkGLArea> = area.widget.cast()
        gtk_gl_area_make_current(gl)
        if let error = gtk_gl_area_get_error(gl) {
            fail(String(cString: error.pointee.message))
            return
        }
        guard let context = gtk_gl_area_get_context(gl) else {
            fail("no GL context")
            return
        }
        isES = gdk_gl_context_get_use_es(context) != 0

        vertexArray = cgl_vertex_array()
        palette = makeTexture(GL_RGBA8, VisualizerPalette.size, 2, format: GL_RGBA, type: GL_UNSIGNED_BYTE, filter: GL_LINEAR)
        frequencies = makeTexture(GL_R16F, VisualizerHostState.bands, 2, format: GL_RED, type: GL_FLOAT, filter: GL_LINEAR)
        // Nearest, as Plexamp's loudness DataTexture is: the spokes are steps, not a slope.
        loudness = makeTexture(GL_R16F, VisualizerLoudness.texels, 2, format: GL_RED, type: GL_FLOAT, filter: GL_NEAREST)
        history = makeTexture(
            GL_R16F, VisualizerHostState.bands, VisualizerHostState.historyRows,
            format: GL_RED, type: GL_FLOAT, filter: GL_LINEAR
        )
        framebuffer = cgl_framebuffer()
    }

    private func unrealize() {
        guard !hasFailed else { return }
        gtk_gl_area_make_current(area.widget.cast())
        for program in compiled.values { cgl_delete_program(program.id) }
        compiled = [:]
        broken = []
        for texture in [palette, frequencies, loudness, history, target] where texture != 0 {
            cgl_delete_texture(texture)
        }
        target = 0
        targetSize = (0, 0)
        if framebuffer != 0 { cgl_delete_framebuffer(framebuffer) }
        if vertexArray != 0 { cgl_delete_vertex_array(vertexArray) }
        framebuffer = 0
        vertexArray = 0
    }

    private func fail(_ reason: String) {
        hasFailed = true
        Task { await Diagnostics.shared.record("visualizer", "no GL: \(reason)") }
        onFailure?()
    }

    private func makeTexture(_ internalFormat: Int32, _ width: Int, _ height: Int, format: Int32, type: Int32, filter: Int32) -> GLuint {
        let texture = cgl_texture()
        cgl_bind_texture(texture)
        cgl_texture_parameter(GLenum(GL_TEXTURE_MIN_FILTER), filter)
        cgl_texture_parameter(GLenum(GL_TEXTURE_MAG_FILTER), filter)
        cgl_texture_parameter(GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        cgl_texture_parameter(GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        cgl_texture_image(internalFormat, GLsizei(width), GLsizei(height), GLenum(format), GLenum(type), nil)
        return texture
    }

    // MARK: - Drawing

    private func render() {
        guard !hasFailed else { return }
        var width: GLint = 0
        var height: GLint = 0
        cgl_viewport_size(&width, &height)
        let screen = cgl_bound_framebuffer()
        guard width > 0, height > 0, let shader = shader(for: program) else {
            cgl_clear()
            return
        }

        // The program's `pixels` across and the height in proportion, or the area's own
        // size when that is smaller or high quality is on.
        let factor = highQuality ? 1 : min(1, Double(program.pixels) / Double(width))
        let drawWidth = max(1, GLint((Double(width) * factor).rounded()))
        let drawHeight = max(1, GLint((Double(height) * factor).rounded()))
        let logicalWidth = max(1, gtk_widget_get_width(area.widget))

        upload()
        cgl_use_program(shader.id)
        cgl_uniform2f(shader.resolution, GLfloat(drawWidth), GLfloat(drawHeight))
        cgl_uniform1f(shader.time, GLfloat(Double(g_get_monotonic_time() - Self.epoch) / 1_000_000))
        cgl_uniform1f(shader.progress, feed.progress)
        cgl_uniform1f(shader.crossfade, feed.crossfadeValue)
        cgl_uniform1f(shader.pixelRatio, GLfloat(drawWidth) / GLfloat(logicalWidth))
        cgl_uniform1f(shader.historyIndex, GLfloat(feed.host.historyIndex))
        for (unit, texture) in [palette, frequencies, loudness, history].enumerated() {
            cgl_active_texture(GLenum(GL_TEXTURE0 + Int32(unit)))
            cgl_bind_texture(texture)
        }
        cgl_bind_vertex_array(vertexArray)

        if drawWidth == width, drawHeight == height {
            cgl_viewport(width, height)
            cgl_clear()
            cgl_draw_triangle()
            return
        }

        prepareTarget(width: drawWidth, height: drawHeight)
        cgl_bind_framebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        cgl_viewport(drawWidth, drawHeight)
        cgl_clear()
        cgl_draw_triangle()
        cgl_bind_framebuffer(GLenum(GL_READ_FRAMEBUFFER), framebuffer)
        cgl_bind_framebuffer(GLenum(GL_DRAW_FRAMEBUFFER), GLuint(screen))
        cgl_viewport(width, height)
        cgl_blit(drawWidth, drawHeight, width, height)
        cgl_bind_framebuffer(GLenum(GL_FRAMEBUFFER), GLuint(screen))
    }

    /// The offscreen texture the program draws into before it is scaled up.
    private func prepareTarget(width: GLint, height: GLint) {
        guard targetSize != (width, height) else { return }
        if target == 0 { target = cgl_texture() }
        cgl_bind_texture(target)
        cgl_texture_parameter(GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        cgl_texture_parameter(GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        cgl_texture_parameter(GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        cgl_texture_parameter(GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        cgl_texture_image(GL_RGBA8, width, height, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
        cgl_bind_framebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        cgl_framebuffer_texture(target)
        targetSize = (width, height)
    }

    private func upload() {
        cgl_bind_texture(palette)
        feed.paletteTexels.withUnsafeBytes {
            cgl_texture_update(GLsizei(VisualizerPalette.size), 2, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), $0.baseAddress)
        }
        update(frequencies, feed.host.frequencyTexels, width: VisualizerHostState.bands, height: 2)
        update(loudness, feed.loudnessTexels, width: VisualizerLoudness.texels, height: 2)
        update(history, feed.host.historyTexels, width: VisualizerHostState.bands, height: VisualizerHostState.historyRows)
    }

    private func update(_ texture: GLuint, _ values: [Float], width: Int, height: Int) {
        guard values.count >= width * height else { return }
        cgl_bind_texture(texture)
        values.withUnsafeBytes {
            cgl_texture_update(GLsizei(width), GLsizei(height), GLenum(GL_RED), GLenum(GL_FLOAT), $0.baseAddress)
        }
    }

    // MARK: - Programs

    /// Compiled on first use: twenty-one programs up front would hold up the first frame,
    /// most noticeably on a software renderer.
    private func shader(for program: VisualizerProgram) -> Compiled? {
        if let ready = compiled[program.function] { return ready }
        guard !broken.contains(program.function), let source = VisualizerShaders.fragment(program.function) else { return nil }
        let version = isES ? "#version 300 es\n" : "#version 150\n"
        guard let vertex = compile(GL_VERTEX_SHADER, version + VisualizerShaders.vertex, name: program.name),
              let fragment = compile(GL_FRAGMENT_SHADER, version + source, name: program.name)
        else {
            broken.insert(program.function)
            return nil
        }
        let id = cgl_create_program()
        cgl_attach_shader(id, vertex)
        cgl_attach_shader(id, fragment)
        cgl_link_program(id)
        cgl_delete_shader(vertex)
        cgl_delete_shader(fragment)
        guard cgl_program_status(id) != 0 else {
            report(program.name, log: { cgl_program_log(id, $0, $1) })
            cgl_delete_program(id)
            broken.insert(program.function)
            return nil
        }
        cgl_use_program(id)
        for (unit, name) in ["palette", "frequencies", "loudness", "history"].enumerated() {
            cgl_uniform1i(cgl_uniform_location(id, name), GLint(unit))
        }
        let ready = Compiled(
            id: id,
            resolution: cgl_uniform_location(id, "u.resolution"),
            time: cgl_uniform_location(id, "u.time"),
            progress: cgl_uniform_location(id, "u.progress"),
            crossfade: cgl_uniform_location(id, "u.crossfade"),
            pixelRatio: cgl_uniform_location(id, "u.pixelRatio"),
            historyIndex: cgl_uniform_location(id, "u.frequencyHistoryIndex")
        )
        compiled[program.function] = ready
        return ready
    }

    private func compile(_ type: Int32, _ source: String, name: String) -> GLuint? {
        let shader = cgl_create_shader(GLenum(type))
        cgl_shader_source(shader, source)
        cgl_compile_shader(shader)
        guard cgl_shader_status(shader) != 0 else {
            report(name, log: { cgl_shader_log(shader, $0, $1) })
            cgl_delete_shader(shader)
            return nil
        }
        return shader
    }

    private func report(_ name: String, log: (GLsizei, UnsafeMutablePointer<CChar>) -> Void) {
        var buffer = [CChar](repeating: 0, count: 4096)
        buffer.withUnsafeMutableBufferPointer { log(GLsizei($0.count), $0.baseAddress!) }
        let message = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        FileHandle.standardError.write(Data("visualizer: \(name) failed to build: \(message)\n".utf8))
        Task { await Diagnostics.shared.record("visualizer", "\(name) failed to build: \(message.prefix(300))") }
    }
}
