import AppKit
import Cmpv
import OpenGL.GL3

/// OpenGL layer that libmpv renders into. `isAsynchronous` makes Core
/// Animation ask `canDraw` on every display refresh (120 Hz on ProMotion);
/// we draw only when mpv has a new frame, so frames land exactly on vsync.
/// VideoToolbox frames reach GL as IOSurface textures — no copies.
final class MPVLayer: CAOpenGLLayer {
    weak var engine: MPVEngine?

    private let lock = NSLock()
    private var forceRender = true
    private var presentedFrames = 0

    override init() {
        super.init()
        isAsynchronous = true
        isOpaque = true
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.black.cgColor
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    }

    override init(layer: Any) { super.init(layer: layer) }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var bounds: CGRect {
        didSet { requestRedraw() }
    }

    func requestRedraw() {
        lock.withLock { forceRender = true }
    }

    func takePresentedFrameCount() -> Int {
        lock.withLock {
            defer { presentedFrames = 0 }
            return presentedFrames
        }
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
            kCGLPFADoubleBuffer,
            kCGLPFAAccelerated,
            kCGLPFAAllowOfflineRenderers,
            kCGLPFASupportsAutomaticGraphicsSwitching,
            _CGLPixelFormatAttribute(rawValue: 0),
        ]
        var pixelFormat: CGLPixelFormatObj?
        var count: GLint = 0
        CGLChoosePixelFormat(attributes, &pixelFormat, &count)
        return pixelFormat ?? super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    override func copyCGLContext(forPixelFormat pixelFormat: CGLPixelFormatObj) -> CGLContextObj {
        let context = super.copyCGLContext(forPixelFormat: pixelFormat)
        var swapInterval: GLint = 1
        CGLSetParameter(context, kCGLCPSwapInterval, &swapInterval)
        CGLEnable(context, kCGLCEMPEngine)
        CGLSetCurrentContext(context)
        engine?.createRenderContext()
        return context
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        guard let renderContext = engine?.renderContext else { return false }
        let hasFrame = mpv_render_context_update(renderContext) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0
        let forced = lock.withLock {
            defer { forceRender = false }
            return forceRender
        }
        return hasFrame || forced
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        guard let renderContext = engine?.renderContext else { return }

        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &framebuffer)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)

        var fbo = mpv_opengl_fbo(fbo: Int32(framebuffer), w: Int32(viewport[2]), h: Int32(viewport[3]),
                                 internal_format: 0)
        var flipY: CInt = 1
        var blockForTargetTime: CInt = 0
        withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flipY) { flipPointer in
                withUnsafeMutablePointer(to: &blockForTargetTime) { blockPointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPointer),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPointer),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: blockPointer),
                        mpv_render_param(),
                    ]
                    _ = mpv_render_context_render(renderContext, &params)
                }
            }
        }
        glFlush()
        mpv_render_context_report_swap(renderContext)
        lock.withLock { presentedFrames += 1 }
    }
}

/// Layer-hosting view for `MPVLayer`.
final class MPVView: NSView {
    init(videoLayer: MPVLayer) {
        super.init(frame: .zero)
        layer = videoLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }
}
