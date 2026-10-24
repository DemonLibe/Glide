import AppKit
import Cmpv
import VideoToolbox

/// libmpv backend: MKV, WebM, AVI, TS, FLV… with FFmpeg demuxers and
/// VideoToolbox hardware decoding (HEVC, H.264, VP9, AV1 on M3+, ProRes).
/// Frames are rendered through the libmpv OpenGL render API into a
/// CAOpenGLLayer that is drawn in sync with the display (up to 120 Hz ProMotion).
final class MPVEngine: PlaybackEngine {
    var onEvent: ((EngineEvent) -> Void)?
    let view: NSView

    let handle: OpaquePointer
    private(set) var renderContext: OpaquePointer?
    private let videoLayer: MPVLayer
    private let eventQueue = DispatchQueue(label: "glide.mpv.events")

    // Main thread state
    private var pendingURL: URL?
    private var seeking = false
    private var lastTimeSent = -1.0
    private var statsTimer: Timer?
    private var statsWindowStart: CFTimeInterval = 0

    // Event-queue state
    private var paused = false
    private var eof = false
    private var idle = true

    init() {
        setlocale(LC_NUMERIC, "C") // required by libmpv
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)

        guard let handle = mpv_create() else { fatalError("mpv_create failed") }
        self.handle = handle
        videoLayer = MPVLayer()
        view = MPVView(videoLayer: videoLayer)
        videoLayer.engine = self

        let options: [(String, String)] = [
            ("vo", "libmpv"),
            ("hwdec", "videotoolbox"),
            ("hwdec-codecs", "all"),
            ("keep-open", "yes"),
            ("idle", "yes"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("hr-seek", "yes"),
            ("sub-auto", "fuzzy"),
            ("demuxer-max-bytes", "512MiB"),
            ("demuxer-max-back-bytes", "128MiB"),
            // Render as soon as the layer asks (it asks on every vsync).
            ("video-timing-offset", "0"),
            ("audio-client-name", "Glide"),
            ("terminal", "yes"),
            ("msg-level", "all=warn"),
        ]
        for (name, value) in options { mpv_set_option_string(handle, name, value) }
        mpv_initialize(handle)

        mpv_observe_property(handle, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "idle-active", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "track-list", MPV_FORMAT_NONE)
        mpv_observe_property(handle, 0, "video-params", MPV_FORMAT_NONE)
        mpv_observe_property(handle, 0, "hwdec-current", MPV_FORMAT_NONE)

        mpv_set_wakeup_callback(handle, { context in
            let engine = Unmanaged<MPVEngine>.fromOpaque(context!).takeUnretainedValue()
            engine.eventQueue.async { engine.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: - PlaybackEngine

    func load(_ url: URL) {
        // libmpv's video output needs the render context, which is created
        // when the layer first draws; until then remember the file.
        guard renderContext != nil else {
            pendingURL = url
            videoLayer.requestRedraw()
            return
        }
        pendingURL = nil
        seeking = false
        lastTimeSent = -1
        mpvCommand(handle, ["loadfile", url.isFileURL ? url.path : url.absoluteString, "replace"])
        mpv_set_property_string(handle, "pause", "no")
    }

    func stop() {
        pendingURL = nil
        mpvCommand(handle, ["stop"])
    }

    func play() { mpv_set_property_string(handle, "pause", "no") }

    func pause() { mpv_set_property_string(handle, "pause", "yes") }

    func seek(to seconds: Double) {
        seeking = true
        mpvCommand(handle, ["seek", String(seconds), "absolute+exact"], async: true)
    }

    func step(frames: Int) {
        let command = frames >= 0 ? "frame-step" : "frame-back-step"
        for _ in 0..<max(1, abs(frames)) { mpvCommand(handle, [command], async: true) }
    }

    func setRate(_ rate: Float) { mpv_set_property_string(handle, "speed", String(rate)) }

    func setVolume(_ volume: Float, muted: Bool) {
        mpv_set_property_string(handle, "volume", String(Int((volume * 100).rounded())))
        mpv_set_property_string(handle, "mute", muted ? "yes" : "no")
    }

    func selectAudio(id: String) { mpv_set_property_string(handle, "aid", id) }

    func selectSubtitle(id: String?) { mpv_set_property_string(handle, "sid", id ?? "no") }

    func setStatsEnabled(_ enabled: Bool) {
        statsTimer?.invalidate()
        statsTimer = nil
        guard enabled else { return }
        _ = videoLayer.takePresentedFrameCount()
        statsWindowStart = CACurrentMediaTime()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.emitStats()
        }
    }

    // MARK: - Rendering

    /// Called by the layer on its render thread with its GL context current.
    func createRenderContext() {
        guard renderContext == nil else { return }
        var glParams = mpv_opengl_init_params(get_proc_address: mpvGetProcAddress, get_proc_address_ctx: nil)
        var context: OpaquePointer?
        let result: Int32 = "opengl".withCString { api in
            withUnsafeMutablePointer(to: &glParams) { glPointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: api)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: glPointer),
                    mpv_render_param(),
                ]
                return mpv_render_context_create(&context, handle, &params)
            }
        }
        guard result >= 0, let context else {
            let message = String(cString: mpv_error_string(result))
            DispatchQueue.main.async { self.onEvent?(.failed("Ошибка инициализации OpenGL: \(message)")) }
            return
        }
        renderContext = context
        DispatchQueue.main.async {
            if let url = self.pendingURL { self.load(url) }
        }
    }

    // MARK: - Events (event queue)

    private func drainEvents() {
        while let event = mpv_wait_event(handle, 0)?.pointee {
            switch event.event_id {
            case MPV_EVENT_NONE, MPV_EVENT_SHUTDOWN:
                return
            case MPV_EVENT_PROPERTY_CHANGE:
                handleProperty(event.data.assumingMemoryBound(to: mpv_event_property.self).pointee)
            case MPV_EVENT_FILE_LOADED:
                eof = false
                refreshTracks()
                refreshInfo()
            case MPV_EVENT_PLAYBACK_RESTART:
                DispatchQueue.main.async { self.seeking = false }
            case MPV_EVENT_END_FILE:
                let end = event.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if end.reason == MPV_END_FILE_REASON_ERROR {
                    let message = String(cString: mpv_error_string(end.error))
                    emit(.failed("mpv не смог воспроизвести файл: \(message)"))
                }
            default:
                break
            }
        }
    }

    private func handleProperty(_ property: mpv_event_property) {
        let name = String(cString: property.name)
        let double = property.format == MPV_FORMAT_DOUBLE ? property.data?.load(as: Double.self) : nil
        let flag = property.format == MPV_FORMAT_FLAG ? property.data.map { $0.load(as: Int32.self) != 0 } : nil

        switch name {
        case "time-pos":
            guard let time = double else { return }
            DispatchQueue.main.async {
                // time-pos changes on every frame; 20 updates/s is plenty for the UI.
                guard !self.seeking, abs(time - self.lastTimeSent) >= 0.05 else { return }
                self.lastTimeSent = time
                self.onEvent?(.time(time))
            }
        case "duration":
            emit(.duration(double ?? 0))
        case "pause":
            paused = flag ?? false
            emitPlaying()
        case "idle-active":
            idle = flag ?? true
            emitPlaying()
        case "eof-reached":
            let reached = flag ?? false
            let finished = reached && !eof
            eof = reached
            emitPlaying()
            if finished { emit(.ended) }
        case "track-list":
            refreshTracks()
        case "video-params", "hwdec-current":
            refreshInfo()
        default:
            break
        }
    }

    private func emitPlaying() { emit(.playing(!paused && !eof && !idle)) }

    private func emit(_ event: EngineEvent) {
        DispatchQueue.main.async { self.onEvent?(event) }
    }

    private func refreshInfo() {
        var info = VideoInfo()
        info.width = Int(string("video-params/dw") ?? "") ?? 0
        info.height = Int(string("video-params/dh") ?? "") ?? 0
        info.frameRate = Float(string("current-tracks/video/demux-fps") ?? string("container-fps") ?? "") ?? 0
        info.codec = string("current-tracks/video/codec").map(Self.prettyCodec) ?? "—"
        let gamma = string("video-params/gamma")
        info.isHDR = gamma == "pq" || gamma == "hlg"
        info.bitrateMbps = (Double(string("video-bitrate") ?? "") ?? 0) / 1_000_000
        info.audioCodec = string("current-tracks/audio/codec").map(Self.prettyCodec)
        switch string("hwdec-current") {
        case nil, "", "no": info.decoder = "Программный (CPU)"
        case let hw?: info.decoder = hw.hasPrefix("videotoolbox") ? "VideoToolbox (аппаратный)" : hw
        }
        emit(.info(info))
    }

    private func refreshTracks() {
        var audio: [MediaTrack] = []
        var subtitles: [MediaTrack] = []
        var selectedAudio: String?
        var selectedSubtitle: String?

        let count = Int(string("track-list/count") ?? "") ?? 0
        for index in 0..<count {
            let prefix = "track-list/\(index)/"
            guard let type = string(prefix + "type"), let id = string(prefix + "id") else { continue }
            let parts = [string(prefix + "lang"), string(prefix + "title"), string(prefix + "codec").map(Self.prettyCodec)]
            let title = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let track = MediaTrack(id: id, title: title.isEmpty ? "Дорожка \(id)" : title)
            let selected = string(prefix + "selected") == "yes"
            switch type {
            case "audio":
                audio.append(track)
                if selected { selectedAudio = id }
            case "sub":
                subtitles.append(track)
                if selected { selectedSubtitle = id }
            default:
                break
            }
        }
        emit(.tracks(audio: audio, subtitles: subtitles,
                     selectedAudio: selectedAudio, selectedSubtitle: selectedSubtitle))
    }

    // MARK: - Stats (main thread)

    private func emitStats() {
        let now = CACurrentMediaTime()
        let elapsed = max(now - statsWindowStart, 0.001)
        statsWindowStart = now
        let frames = videoLayer.takePresentedFrameCount()
        let dropped = (Int(string("frame-drop-count") ?? "") ?? 0)
            + (Int(string("decoder-frame-drop-count") ?? "") ?? 0)
        onEvent?(.stats(PlaybackStats(presentedFPS: Double(frames) / elapsed, droppedFrames: dropped)))
        eventQueue.async { self.refreshInfo() } // bitrate changes over time
    }

    private func string(_ name: String) -> String? { mpvString(handle, name) }

    private static let codecNames: [String: String] = [
        "hevc": "HEVC", "h264": "H.264", "av1": "AV1", "vp9": "VP9", "vp8": "VP8",
        "mpeg2video": "MPEG-2", "mpeg4": "MPEG-4", "prores": "ProRes", "vc1": "VC-1",
        "aac": "AAC", "opus": "Opus", "vorbis": "Vorbis", "flac": "FLAC", "mp3": "MP3",
        "ac3": "Dolby Digital", "eac3": "Dolby Digital+", "truehd": "Dolby TrueHD",
        "dts": "DTS", "alac": "ALAC", "subrip": "SRT", "ass": "ASS", "webvtt": "WebVTT",
        "hdmv_pgs_subtitle": "PGS", "dvd_subtitle": "VobSub", "mov_text": "TX3G",
    ]

    static func prettyCodec(_ codec: String) -> String {
        codecNames[codec] ?? (codec.hasPrefix("pcm") ? "PCM" : codec.uppercased())
    }

    // MARK: - Self-test

    /// `Glide --selftest [files…]`: checks that the bundled libmpv loads and
    /// can demux/decode the given files. Used by CI on the packaged app.
    static func selfTest(files: [String]) -> Bool {
        setlocale(LC_NUMERIC, "C")
        guard let mpv = mpv_create() else { print("FAIL mpv_create"); return false }
        for (name, value) in [("vo", "null"), ("ao", "null"), ("terminal", "yes"), ("msg-level", "all=warn")] {
            mpv_set_option_string(mpv, name, value)
        }
        guard mpv_initialize(mpv) >= 0 else { print("FAIL mpv_initialize"); return false }
        print(mpvString(mpv, "mpv-version") ?? "mpv ?", "/ FFmpeg", mpvString(mpv, "ffmpeg-version") ?? "?")

        var allPassed = true
        for file in files {
            mpvCommand(mpv, ["loadfile", file])
            var codec: String?
            waiting: while true {
                guard let event = mpv_wait_event(mpv, 60)?.pointee else { break }
                switch event.event_id {
                case MPV_EVENT_FILE_LOADED:
                    codec = mpvString(mpv, "current-tracks/video/codec")
                case MPV_EVENT_END_FILE:
                    let end = event.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    let passed = end.reason == MPV_END_FILE_REASON_EOF && codec != nil
                    print(passed ? "OK  " : "FAIL", file, "[\(codec ?? "нет видео")]")
                    allPassed = allPassed && passed
                    break waiting
                case MPV_EVENT_NONE:
                    print("FAIL", file, "(таймаут)")
                    allPassed = false
                    break waiting
                default:
                    continue
                }
            }
        }
        mpv_terminate_destroy(mpv)
        return allPassed
    }
}

// MARK: - libmpv helpers

@discardableResult
func mpvCommand(_ handle: OpaquePointer, _ args: [String], async: Bool = false) -> Int32 {
    var cArgs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
    cArgs.append(nil)
    defer { for arg in cArgs { free(UnsafeMutablePointer(mutating: arg)) } }
    return async ? mpv_command_async(handle, 0, &cArgs) : mpv_command(handle, &cArgs)
}

func mpvString(_ handle: OpaquePointer, _ name: String) -> String? {
    guard let value = mpv_get_property_string(handle, name) else { return nil }
    defer { mpv_free(value) }
    return String(cString: value)
}

private func mpvGetProcAddress(_ context: UnsafeMutableRawPointer?,
                               _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name else { return nil }
    let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
    let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
    return CFBundleGetFunctionPointerForName(bundle, symbol)
}
