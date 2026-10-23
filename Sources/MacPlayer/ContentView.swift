import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var player: PlayerController
    @State private var controlsVisible = true
    @State private var controlsHovered = false
    @State private var dropTargeted = false
    @State private var hideWork: DispatchWorkItem?

    var body: some View {
        ZStack {
            VideoSurface(controller: player)

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { player.toggleFullScreen() }
                .onTapGesture { player.togglePlay() }

            if player.playlist.isEmpty {
                EmptyStateView()
            }

            VStack {
                HStack(alignment: .top) {
                    if player.showStats {
                        StatsOverlay()
                    }
                    Spacer()
                    if let error = player.errorMessage {
                        ErrorBanner(message: error) { player.errorMessage = nil }
                    }
                }
                Spacer()
                if !player.playlist.isEmpty {
                    ControlsView(clock: player.clock)
                        .onHover { controlsHovered = $0 }
                        .padding(16)
                        .opacity(controlsVisible ? 1 : 0)
                        .allowsHitTesting(controlsVisible)
                }
            }
        }
        .background(Color.black)
        .frame(minWidth: 480, minHeight: 270)
        .navigationTitle(player.title)
        .onContinuousHover { _ in revealControls() }
        .onChange(of: player.isPlaying) { _, _ in revealControls() }
        .dropDestination(for: URL.self) { urls, _ in
            player.open(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 4)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    private func revealControls() {
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true }
        }
        hideWork?.cancel()
        let work = DispatchWorkItem {
            guard player.isPlaying, !player.isScrubbing, !controlsHovered else { return }
            withAnimation(.easeIn(duration: 0.3)) { controlsVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
}

private struct EmptyStateView: View {
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 56, weight: .thin))
            Text("Перетащите видео или папку сюда")
                .font(.title3)
            Button("Открыть… (⌘O)") { player.showOpenPanel() }
                .controlSize(.large)
        }
        .foregroundStyle(.white.opacity(0.8))
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).lineLimit(3)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 420)
        .padding(12)
    }
}
