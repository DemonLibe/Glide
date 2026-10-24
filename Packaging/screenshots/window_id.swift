// Prints the CGWindowID of Glide's main window (for `screencapture -l`).
// With --dump, prints every Glide window instead (for debugging).
import CoreGraphics

let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let glide = windows.filter { $0[kCGWindowOwnerName as String] as? String == "Glide" }
if CommandLine.arguments.contains("--dump") {
    for window in glide {
        print(window[kCGWindowNumber as String] ?? "?", "layer:", window[kCGWindowLayer as String] ?? "?",
              "onscreen:", window[kCGWindowIsOnscreen as String] ?? "?",
              "name:", window[kCGWindowName as String] ?? "", "bounds:", window[kCGWindowBounds as String] ?? "")
    }
} else if let main = glide.first(where: {
    $0[kCGWindowLayer as String] as? Int == 0 && $0[kCGWindowIsOnscreen as String] as? Bool == true
}) {
    print(main[kCGWindowNumber as String]!)
}
