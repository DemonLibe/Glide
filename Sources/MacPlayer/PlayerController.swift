import AppKit
import Combine
import UniformTypeIdentifiers

/// Fast-changing playback position lives in its own object so that only the
/// timeline and time label re-render 20 times a second, not the whole UI.
final class PlaybackClock: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
}

final class PlayerController: ObservableObject {
    static let shared = PlayerController()
    static let rates: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    /// AVFoundation handles these best (lowest power, native HDR/EDR);
    /// everything else — and anything AVFoundation can't decode — goes to mpv.
    private static let nativeExtensions: Set<String> = ["mp4", "m4v", "mov", "qt", "m3u8"]
    static let extraExtensions: Set<String> = [
        "mkv", "mk3d", "webm", "avi", "flv", "f4v", "wmv", "asf", "ts", "m2ts", "mts", "m2t",
        "mpg", "mpeg", "vob", "ogv", "ogm", "3gp", "3g2", "rm", "rmvb", "divx", "mxf", "nut",
        "y4m", "ivf", "hevc", "h264", "264", "265", "av1",
    ]

    let clock = PlaybackClock()

    @Published private(set) var engineView: NSView?
    @Published private(set) var engineName = ""
    @Published private(set) var isPlaying = false
    @Published private(set) var playlist: [URL] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var videoInfo: VideoInfo?
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []
    @Published private(set) var selectedAudioID: String?
    @Published private(set) var selectedSubtitleID: String?
    @Published private(set) var rate: Float = 1
    @Published private(set) var stats = PlaybackStats()
    @Published private(set) var displayHz: Double = 0
    @Published var errorMessage: String?
    @Published var loopEnabled = false
    @Published var volume: Float = 1 {
        didSet { if volume > 0 { isMuted = false }; applyVolume() }
    }
    @Published var isMuted = false {
        didSet { applyVolume() }
    }
    @Published var showStats = false {
        didSet { engine?.setStatsEnabled(showStats) }
    }

    weak var window: NSWindow?
    private(set) var isScrubbing = false

    private var engine: PlaybackEngine?
    private lazy var nativeEngine: AVEngine = connect(AVEngine())
    private lazy var mpvEngine: MPVEngine = connect(MPVEngine())
    private var triedFallback = false
    private var didResizeWindow = false
    private var wasPlayingBeforeScrub = false

    var title: String {
        playlist.indices.contains(currentIndex) ? playlist[currentIndex].lastPathComponent : "MacPlayer"
    }

    private init() {}

    private func connect<E: PlaybackEngine>(_ newEngine: E) -> E {
        newEngine.onEvent = { [weak self, unowned newEngine] event in
            guard let self, self.engine === newEngine else { return }
            self.handle(event)
        }
        return newEngine
    }

    // MARK: - Opening files

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent]
            + Self.extraExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { open(panel.urls) }
    }

    func open(_ urls: [URL]) {
        let files = urls.flatMap(Self.expand).filter(Self.isPlayable)
        guard !files.isEmpty else {
            errorMessage = "Не найдено поддерживаемых видеофайлов"
            return
        }
        playlist = files
        load(index: 0)
    }

    private static func expand(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return [url] }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private static func isPlayable(_ url: URL) -> Bool {
        guard url.isFileURL else { return true }
        let ext = url.pathExtension.lowercased()
        if extraExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .audiovisualContent)
    }

    private func load(index: Int) {
        guard playlist.indices.contains(index) else { return }
        currentIndex = index
        let url = playlist[index]

        errorMessage = nil
        videoInfo = nil
        audioTracks = []
        subtitleTracks = []
        selectedAudioID = nil
        selectedSubtitleID = nil
        stats = PlaybackStats()
        clock.currentTime = 0
        clock.duration = 0
        triedFallback = false
        didResizeWindow = false

        let native = Self.nativeExtensions.contains(url.pathExtension.lowercased())
        start(url, with: native ? nativeEngine : mpvEngine)
    }

    private func start(_ url: URL, with newEngine: PlaybackEngine) {
        if let engine, engine !== newEngine {
            engine.setStatsEnabled(false)
            engine.stop()
        }
        engine = newEngine
        engineView = newEngine.view
        engineName = newEngine is MPVEngine ? "mpv" : "AVFoundation"
        newEngine.setRate(rate)
        newEngine.setVolume(volume, muted: isMuted)
        newEngine.setStatsEnabled(showStats)
        newEngine.load(url)
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .time(let time):
            if !isScrubbing { clock.currentTime = time }
        case .duration(let duration):
            clock.duration = duration
        case .playing(let playing):
            isPlaying = playing
        case .info(let info):
            videoInfo = info
            if !didResizeWindow, info.width > 0, info.height > 0 {
                didResizeWindow = true
                resizeWindow(for: CGSize(width: info.width, height: info.height))
            }
        case let .tracks(audio, subtitles, selectedAudio, selectedSubtitle):
            audioTracks = audio
            subtitleTracks = subtitles
            selectedAudioID = selectedAudio
            selectedSubtitleID = selectedSubtitle
        case .stats(let newStats):
            stats = newStats
            displayHz = Double(window?.screen?.maximumFramesPerSecond ?? 0)
        case .ended:
            itemDidFinish()
        case .failed(let message):
            if engine === nativeEngine, !triedFallback, playlist.indices.contains(currentIndex) {
                // AVFoundation can't handle it (codec/container) — retry with mpv.
                triedFallback = true
                start(playlist[currentIndex], with: mpvEngine)
            } else {
                errorMessage = message
            }
        }
    }

    // MARK: - Transport

    func togglePlay() {
        guard let engine else { showOpenPanel(); return }
        if isPlaying {
            engine.pause()
        } else {
            if clock.duration > 0, clock.currentTime >= clock.duration - 0.05 { seek(to: 0) }
            engine.play()
        }
    }

    func seek(by delta: Double) { seek(to: clock.currentTime + delta) }

    func seek(toFraction fraction: Double) { seek(to: clock.duration * fraction) }

    func seek(to seconds: Double) {
        guard let engine else { return }
        let upper = clock.duration > 0 ? clock.duration : seconds
        let target = max(0, min(seconds, upper))
        clock.currentTime = target
        engine.seek(to: target)
    }

    func beginScrubbing() {
        guard !isScrubbing else { return }
        isScrubbing = true
        wasPlayingBeforeScrub = isPlaying
        engine?.pause()
    }

    func scrub(to seconds: Double) { seek(to: seconds) }

    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        if wasPlayingBeforeScrub { engine?.play() }
    }

    /// Frame-accurate stepping (pauses playback).
    func step(frames: Int) { engine?.step(frames: frames) }

    func setRate(_ newRate: Float) {
        rate = newRate
        engine?.setRate(newRate)
    }

    func changeRate(by step: Int) {
        let index = Self.rates.firstIndex(of: rate) ?? Self.rates.firstIndex(of: 1)!
        let next = max(0, min(Self.rates.count - 1, index + step))
        setRate(Self.rates[next])
    }

    func adjustVolume(by delta: Float) {
        volume = max(0, min(1, volume + delta))
        isMuted = false
    }

    private func applyVolume() { engine?.setVolume(volume, muted: isMuted) }

    func next() {
        if currentIndex + 1 < playlist.count { load(index: currentIndex + 1) }
    }

    func previous() {
        if clock.currentTime > 3 || currentIndex == 0 { seek(to: 0) } else { load(index: currentIndex - 1) }
    }

    private func itemDidFinish() {
        if loopEnabled {
            seek(to: 0)
            engine?.play()
        } else if currentIndex + 1 < playlist.count {
            load(index: currentIndex + 1)
        }
    }

    // MARK: - Tracks

    func selectAudio(id: String) {
        engine?.selectAudio(id: id)
        selectedAudioID = id
    }

    func selectSubtitle(id: String?) {
        engine?.selectSubtitle(id: id)
        selectedSubtitleID = id
    }

    // MARK: - Window

    func toggleFullScreen() { window?.toggleFullScreen(nil) }

    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    /// Fits the window to the video (never above 1 pt per pixel, max 85% of the screen).
    private func resizeWindow(for videoSize: CGSize) {
        guard let window, !isFullScreen, videoSize.width > 0, videoSize.height > 0,
              let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let scale = min(1, visible.width * 0.85 / videoSize.width, visible.height * 0.85 / videoSize.height)
        let content = NSSize(width: (videoSize.width * scale).rounded(),
                             height: (videoSize.height * scale).rounded())
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        window.contentAspectRatio = content
        window.setFrame(frame, display: true, animate: true)
    }
}
