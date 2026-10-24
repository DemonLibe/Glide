// Prints the CGWindowID of Glide's main window (for `screencapture -l`).
import CoreGraphics

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows
where window[kCGWindowOwnerName as String] as? String == "Glide" && window[kCGWindowLayer as String] as? Int == 0 {
    print(window[kCGWindowNumber as String]!)
    break
}
