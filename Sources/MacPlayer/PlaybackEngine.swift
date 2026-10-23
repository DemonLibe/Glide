import AppKit

struct VideoInfo: Equatable {
    var width = 0
    var height = 0
    var frameRate: Float = 0
    var codec = "—"
    var bitrateMbps: Double = 0
    var isHDR = false
    var audioCodec: String?
    var decoder: String?
}

struct MediaTrack: Identifiable, Hashable {
    let id: String
    let title: String
}

struct PlaybackStats: Equatable {
    var presentedFPS: Double = 0
    var droppedFrames = 0
}

enum EngineEvent {
    case time(Double)
    case duration(Double)
    case playing(Bool)
    case info(VideoInfo)
    case tracks(audio: [MediaTrack], subtitles: [MediaTrack], selectedAudio: String?, selectedSubtitle: String?)
    case stats(PlaybackStats)
    case ended
    case failed(String)
}

/// A playback backend. MacPlayer has two:
/// - `AVEngine` (AVFoundation) for MP4/MOV — lowest power use, native HDR/EDR;
/// - `MPVEngine` (libmpv + FFmpeg) for MKV, WebM, AVI and everything else.
///
/// `onEvent` is always invoked on the main thread.
protocol PlaybackEngine: AnyObject {
    var view: NSView { get }
    var onEvent: ((EngineEvent) -> Void)? { get set }

    func load(_ url: URL)
    func stop()
    func play()
    func pause()
    /// Exact seek; rapid successive calls are coalesced.
    func seek(to seconds: Double)
    func step(frames: Int)
    func setRate(_ rate: Float)
    func setVolume(_ volume: Float, muted: Bool)
    func selectAudio(id: String)
    func selectSubtitle(id: String?)
    func setStatsEnabled(_ enabled: Bool)
}
