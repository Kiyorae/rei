import AppKit
import ReiUI

@main
@MainActor
enum ReiApplication {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = ReiApplicationDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
