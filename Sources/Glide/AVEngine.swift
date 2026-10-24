import AVFoundation
import AppKit
import Combine

/// AVFoundation backend. The AVPlayerLayer is the view's backing layer, so
/// frames go from VideoToolbox straight to the compositor (zero-copy IOSurface)
/// independently of SwiftUI and the main thread.
final class AVEngine: PlaybackEngine {
    var onEvent: ((EngineEvent) -> Void)?
    var view: NSView { playerView }

    private let player = AVPlayer()
    private let playerView = AVPlayerNSView()
    private let frameCounter = FrameCounter()
    private var statsEnabled = false
    private var expectedFPS: Double = 0

    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var itemCancellables = Set<AnyCancellable>()
    private var infoTask: Task<Void, Never>?

    // Seek "chasing": while a seek is in flight, newer targets replace each
    // other and only the latest one is issued. Keeps scrubbing through
    // long-GOP 4K HEVC responsive instead of queueing dozens of exact seeks.
    private var isSeeking = false
    private var pendingSeek: CMTime?

    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?

    init() {
        playerView.playerLayer.player = player
        playerView.onTick = { [weak self] link in self?.displayTick(link) }
        player.preventsDisplaySleepDuringVideoPlayback = true
        player.actionAtItemEnd = .pause

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20), queue: .main
        ) { [weak self] time in
            guard let self, !self.isSeeking, self.pendingSeek == nil else { return }
            self.onEvent?(.time(time.seconds.isFinite ? time.seconds : 0))
        }

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.onEvent?(.playing(status != .paused)) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.onEvent?(.ended)
            }
            .store(in: &cancellables)
    }

    func load(_ url: URL) {
        pendingSeek = nil
        audioGroup = nil
        subtitleGroup = nil
        expectedFPS = 0

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        // Local files decode faster than real time, so start instantly; give
        // network streams a buffer so 4K120 bitrates don't stall.
        item.preferredForwardBufferDuration = url.isFileURL ? 0 : 10
        player.automaticallyWaitsToMinimizeStalling = !url.isFileURL

        itemCancellables.removeAll()
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self, let item, item === self.player.currentItem else { return }
                switch status {
                case .readyToPlay:
                    self.player.play()
                case .failed:
                    self.onEvent?(.failed(item.error?.localizedDescription ?? "Не удалось открыть файл"))
                default:
                    break
                }
            }
            .store(in: &itemCancellables)

        player.replaceCurrentItem(with: item)
        frameCounter.attach(to: statsEnabled ? item : nil)

        infoTask?.cancel()
        infoTask = Task { [weak self] in await self?.loadInfo(asset: asset, item: item) }
    }

    func stop() {
        infoTask?.cancel()
        itemCancellables.removeAll()
        frameCounter.attach(to: nil)
        player.replaceCurrentItem(with: nil)
    }

    func play() { player.play() }

    func pause() { player.pause() }

    func seek(to seconds: Double) {
        guard player.currentItem != nil else { return }
        pendingSeek = CMTime(seconds: seconds, preferredTimescale: 90_000)
        chaseSeek()
    }

    private func chaseSeek() {
        guard !isSeeking, let target = pendingSeek else { return }
        pendingSeek = nil
        isSeeking = true
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isSeeking = false
                self?.chaseSeek()
            }
        }
    }

    func step(frames: Int) {
        guard let item = player.currentItem else { return }
        player.pause()
        item.step(byCount: frames)
    }

    func setRate(_ rate: Float) {
        player.defaultRate = rate
        if player.rate != 0 { player.rate = rate }
    }

    func setVolume(_ volume: Float, muted: Bool) {
        player.volume = volume
        player.isMuted = muted
    }

    func selectAudio(id: String) {
        guard let group = audioGroup, let index = Int(id), group.options.indices.contains(index) else { return }
        player.currentItem?.select(group.options[index], in: group)
        emitTracks()
    }

    func selectSubtitle(id: String?) {
        guard let group = subtitleGroup else { return }
        let option = id.flatMap { Int($0) }.flatMap { group.options.indices.contains($0) ? group.options[$0] : nil }
        player.currentItem?.select(option, in: group)
        emitTracks()
    }

    func setStatsEnabled(_ enabled: Bool) {
        statsEnabled = enabled
        playerView.tickEnabled = enabled
        frameCounter.attach(to: enabled ? player.currentItem : nil)
    }

    // MARK: - Private

    @MainActor
    private func loadInfo(asset: AVURLAsset, item: AVPlayerItem) async {
        do {
            let duration = try await asset.load(.duration)
            guard item === player.currentItem else { return }
            onEvent?(.duration(duration.seconds.isFinite ? duration.seconds : 0))

            var info = VideoInfo()
            info.decoder = "VideoToolbox (AVFoundation)"
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                // e.g. AV1 on M1/M2 or VP9 in MP4: let the controller fall back to mpv.
                guard try await track.load(.isPlayable) else {
                    onEvent?(.failed("AVFoundation не умеет декодировать это видео"))
                    return
                }
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                info.width = Int(abs(rect.width).rounded())
                info.height = Int(abs(rect.height).rounded())
                info.frameRate = try await track.load(.nominalFrameRate)
                let dataRate = try await track.load(.estimatedDataRate)
                info.bitrateMbps = Double(dataRate) / 1_000_000
                if let desc = try await track.load(.formatDescriptions).first {
                    info.codec = Self.codecName(CMFormatDescriptionGetMediaSubType(desc))
                    info.isHDR = Self.isHDR(desc)
                }
            }
            if let audio = try await asset.loadTracks(withMediaType: .audio).first,
               let desc = try await audio.load(.formatDescriptions).first {
                info.audioCodec = Self.codecName(CMFormatDescriptionGetMediaSubType(desc))
            }

            let audible = try await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try await asset.loadMediaSelectionGroup(for: .legible)
            guard item === player.currentItem else { return }

            audioGroup = audible
            subtitleGroup = legible
            expectedFPS = Double(info.frameRate)
            onEvent?(.info(info))
            emitTracks()
        } catch {
            if item === player.currentItem { onEvent?(.failed(error.localizedDescription)) }
        }
    }

    private func emitTracks() {
        guard let item = player.currentItem else { return }
        func tracks(_ group: AVMediaSelectionGroup?) -> ([MediaTrack], String?) {
            guard let group else { return ([], nil) }
            let list = group.options.enumerated().map { MediaTrack(id: String($0.offset), title: $0.element.displayName) }
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
                .flatMap { group.options.firstIndex(of: $0) }
                .map { String($0) }
            return (list, selected)
        }
        let (audio, selectedAudio) = tracks(audioGroup)
        let (subtitles, selectedSubtitle) = tracks(subtitleGroup)
        onEvent?(.tracks(audio: audio, subtitles: subtitles,
                         selectedAudio: selectedAudio, selectedSubtitle: selectedSubtitle))
    }

    private func displayTick(_ link: CADisplayLink) {
        let screenHz = Double(playerView.window?.screen?.maximumFramesPerSecond ?? 60)
        if let stats = frameCounter.tick(targetTimestamp: link.targetTimestamp, screenHz: screenHz,
                                         expectedFPS: expectedFPS, rate: player.rate) {
            onEvent?(.stats(stats))
        }
    }

    private static let codecNames: [String: String] = [
        "hvc1": "HEVC", "hev1": "HEVC", "avc1": "H.264", "avc3": "H.264", "av01": "AV1",
        "dvh1": "Dolby Vision", "dvhe": "Dolby Vision", "vp09": "VP9",
        "apco": "ProRes 422 Proxy", "apcs": "ProRes 422 LT", "apcn": "ProRes 422",
        "apch": "ProRes 422 HQ", "ap4h": "ProRes 4444", "ap4x": "ProRes 4444 XQ", "aprn": "ProRes RAW",
        "aac ": "AAC", "mp4a": "AAC", ".mp3": "MP3", "ac-3": "Dolby Digital", "ec-3": "Dolby Digital+",
        "alac": "ALAC", "lpcm": "PCM", "opus": "Opus", "fLaC": "FLAC",
    ]

    static func codecName(_ code: FourCharCode) -> String {
        let fourCC = String([24, 16, 8, 0].map {
            Character(UnicodeScalar(UInt8(truncatingIfNeeded: code >> UInt32($0))))
        })
        return codecNames[fourCC] ?? fourCC.trimmingCharacters(in: .whitespaces)
    }

    static func isHDR(_ desc: CMFormatDescription) -> Bool {
        if codecName(CMFormatDescriptionGetMediaSubType(desc)) == "Dolby Vision" { return true }
        let transfer = CMFormatDescriptionGetExtension(
            desc, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        return transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
    }
}

final class AVPlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    var onTick: ((CADisplayLink) -> Void)?
    var tickEnabled = false {
        didSet { link?.isPaused = !tickEnabled }
    }
    private var link: CADisplayLink?

    override init(frame: NSRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer { playerLayer }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(displayTick(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = !tickEnabled
        self.link = link
    }

    @objc private func displayTick(_ link: CADisplayLink) { onTick?(link) }
}

/// Counts distinct frames reaching the screen: an AVPlayerItemVideoOutput
/// (native pixel format, no conversion) is polled on every display refresh,
/// each new pixel buffer is one presented frame. Attached only while stats are shown.
private final class FrameCounter {
    private var output: AVPlayerItemVideoOutput?
    private weak var item: AVPlayerItem?
    private var frameCount = 0
    private var windowStart: CFTimeInterval = 0
    private var dropped = 0

    func attach(to newItem: AVPlayerItem?) {
        if let output, let item { item.remove(output) }
        output = nil
        item = nil
        frameCount = 0
        windowStart = 0
        dropped = 0
        guard let newItem else { return }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        newItem.add(output)
        self.output = output
        item = newItem
    }

    /// Returns fresh stats once per second.
    func tick(targetTimestamp: CFTimeInterval, screenHz: Double, expectedFPS: Double, rate: Float) -> PlaybackStats? {
        guard let output else { return nil }
        let itemTime = output.itemTime(forHostTime: targetTimestamp)
        if output.hasNewPixelBuffer(forItemTime: itemTime) {
            _ = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
            frameCount += 1
        }

        let now = CACurrentMediaTime()
        if windowStart == 0 { windowStart = now; frameCount = 0; return nil }
        let elapsed = now - windowStart
        guard elapsed >= 1 else { return nil }

        if rate > 0, expectedFPS > 0 {
            // A 60 Hz screen can't show 120 fps — that's a display limit, not a drop.
            let expected = min(expectedFPS * Double(rate), screenHz > 0 ? screenHz : .infinity)
            let missed = Int((expected * elapsed - Double(frameCount)).rounded())
            if missed > 1 { dropped += missed }
        }
        let stats = PlaybackStats(presentedFPS: Double(frameCount) / elapsed, droppedFrames: dropped)
        frameCount = 0
        windowStart = now
        return stats
    }
}
