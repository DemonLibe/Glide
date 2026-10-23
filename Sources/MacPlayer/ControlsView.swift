import SwiftUI

struct ControlsView: View {
    @EnvironmentObject private var player: PlayerController
    let clock: PlaybackClock

    var body: some View {
        VStack(spacing: 8) {
            TimelineSlider(clock: clock)

            HStack(spacing: 16) {
                Button { player.previous() } label: { Image(systemName: "backward.end.fill") }
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .frame(width: 26)
                }
                Button { player.next() } label: { Image(systemName: "forward.end.fill") }
                    .disabled(player.currentIndex + 1 >= player.playlist.count)

                TimeLabel(clock: clock)

                Spacer()

                Button { player.isMuted.toggle() } label: {
                    Image(systemName: volumeIcon).frame(width: 22)
                }
                Slider(value: $player.volume, in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 90)

                Menu {
                    ForEach(PlayerController.rates, id: \.self) { rate in
                        Button { player.setRate(rate) } label: {
                            if rate == player.rate {
                                Label(Self.rateLabel(rate), systemImage: "checkmark")
                            } else {
                                Text(Self.rateLabel(rate))
                            }
                        }
                    }
                } label: {
                    Text(Self.rateLabel(player.rate)).monospacedDigit()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Скорость ( [ и ] )")

                TracksMenu()

                Button { player.loopEnabled.toggle() } label: {
                    Image(systemName: "repeat")
                        .foregroundStyle(player.loopEnabled ? Color.accentColor : .white)
                }
                .help("Повтор (L)")

                Button { player.showStats.toggle() } label: {
                    Image(systemName: player.showStats ? "info.circle.fill" : "info.circle")
                }
                .help("Статистика (I)")

                Button { player.toggleFullScreen() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Полный экран (F)")
            }
            .buttonStyle(.plain)
            .font(.system(size: 15))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: 900)
    }

    private var volumeIcon: String {
        if player.isMuted || player.volume == 0 { return "speaker.slash.fill" }
        return player.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
    }

    static func rateLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate.formatted())×"
    }
}

private struct TimelineSlider: View {
    @EnvironmentObject private var player: PlayerController
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        Slider(
            value: Binding(get: { clock.currentTime }, set: { player.scrub(to: $0) }),
            in: 0...max(clock.duration, 0.01),
            onEditingChanged: { editing in
                editing ? player.beginScrubbing() : player.endScrubbing()
            }
        )
        .controlSize(.small)
    }
}

private struct TimeLabel: View {
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        Text("\(format(clock.currentTime)) / \(format(clock.duration))")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = Int(seconds)
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

private struct TracksMenu: View {
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        Menu {
            if player.audioTracks.count > 1 {
                Section("Аудио") {
                    ForEach(player.audioTracks) { track in
                        Button { player.selectAudio(id: track.id) } label: {
                            checked(track.title, track.id == player.selectedAudioID)
                        }
                    }
                }
            }
            if !player.subtitleTracks.isEmpty {
                Section("Субтитры") {
                    Button { player.selectSubtitle(id: nil) } label: {
                        checked("Выкл.", player.selectedSubtitleID == nil)
                    }
                    ForEach(player.subtitleTracks) { track in
                        Button { player.selectSubtitle(id: track.id) } label: {
                            checked(track.title, track.id == player.selectedSubtitleID)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(player.audioTracks.count < 2 && player.subtitleTracks.isEmpty)
        .help("Аудиодорожки и субтитры")
    }

    @ViewBuilder
    private func checked(_ title: String, _ isOn: Bool) -> some View {
        if isOn { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
