import AppKit
import Carbon.HIToolbox
import SwiftUI

struct GlideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var player = PlayerController.shared

    var body: some Scene {
        Window("Glide", id: "main") {
            ContentView()
                .environmentObject(player)
        }
        .defaultSize(width: 1280, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть…") { player.showOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Воспроизведение") {
                Button("Пуск / пауза") { player.togglePlay() }
                Button("Следующий файл") { player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Предыдущий файл") { player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button("Быстрее") { player.changeRate(by: 1) }
                Button("Медленнее") { player.changeRate(by: -1) }
                Button("Обычная скорость") { player.setRate(1) }
                Divider()
                Toggle("Повтор", isOn: $player.loopEnabled)
                Toggle("Статистика", isOn: $player.showStats)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            KeyCommands.handle(event) ? nil : event
        }

        let files = CommandLine.arguments.dropFirst()
            .filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        if !files.isEmpty { PlayerController.shared.open(files) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        PlayerController.shared.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Keyboard shortcuts by physical key code, so they work with any layout
/// (including Russian — "K" works without switching to English).
enum KeyCommands {
    private static let digitKeys = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                                    kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    static func handle(_ event: NSEvent) -> Bool {
        let player = PlayerController.shared
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) { return false }
        if NSApp.keyWindow?.firstResponder is NSTextView { return false }
        let shift = mods.contains(.shift)
        let option = mods.contains(.option)

        switch Int(event.keyCode) {
        case kVK_Space, kVK_ANSI_K: player.togglePlay()
        case kVK_LeftArrow:
            if option { player.step(frames: -1) } else { player.seek(by: shift ? -30 : -5) }
        case kVK_RightArrow:
            if option { player.step(frames: 1) } else { player.seek(by: shift ? 30 : 5) }
        case kVK_UpArrow: player.adjustVolume(by: 0.05)
        case kVK_DownArrow: player.adjustVolume(by: -0.05)
        case kVK_ANSI_Comma: player.step(frames: -1)
        case kVK_ANSI_Period: player.step(frames: 1)
        case kVK_ANSI_LeftBracket: player.changeRate(by: -1)
        case kVK_ANSI_RightBracket: player.changeRate(by: 1)
        case kVK_Delete: player.setRate(1)
        case kVK_ANSI_F, kVK_Return: player.toggleFullScreen()
        case kVK_Escape:
            guard player.isFullScreen else { return false }
            player.toggleFullScreen()
        case kVK_ANSI_M: player.isMuted.toggle()
        case kVK_ANSI_I: player.showStats.toggle()
        case kVK_ANSI_L: player.loopEnabled.toggle()
        case kVK_ANSI_N: player.next()
        case kVK_ANSI_P: player.previous()
        case let code where digitKeys.contains(code):
            player.seek(toFraction: Double(digitKeys.firstIndex(of: code)!) / 10)
        default:
            return false
        }
        return true
    }
}
