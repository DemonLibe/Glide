import SwiftUI

struct StatsOverlay: View {
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("Движок", player.engineName)
            if let info = player.videoInfo {
                row("Видео", "\(info.width)×\(info.height) \(info.codec)\(info.isHDR ? " HDR" : "")")
                if let decoder = info.decoder { row("Декодер", decoder) }
                row("Кадры файла", String(format: "%.2f fps", info.frameRate))
                row("Битрейт", String(format: "%.1f Мбит/с", info.bitrateMbps))
                if let audio = info.audioCodec { row("Аудио", audio) }
            }
            row("Показано", String(format: "%.1f fps", player.stats.presentedFPS))
            row("Экран", player.displayHz > 0 ? "\(Int(player.displayHz)) Гц" : "—")
            row("Пропущено", "\(player.stats.droppedFrames)")
            row("Скорость", ControlsView.rateLabel(player.rate))

            if let info = player.videoInfo, player.displayHz > 0,
               Double(info.frameRate) > player.displayHz + 1 {
                Text("Экран \(Int(player.displayHz)) Гц не покажет все \(Int(info.frameRate.rounded())) fps")
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
        .allowsHitTesting(false)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.white.opacity(0.6)).frame(width: 90, alignment: .leading)
            Text(value)
        }
    }
}
