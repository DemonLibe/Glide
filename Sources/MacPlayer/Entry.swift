import Foundation

@main
enum Entry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--selftest" {
            exit(MPVEngine.selfTest(files: Array(arguments.dropFirst())) ? 0 : 1)
        }
        MacPlayerApp.main()
    }
}
