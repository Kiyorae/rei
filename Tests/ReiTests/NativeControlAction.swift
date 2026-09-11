import AppKit
import Testing

/// Delivers the real target/action without starting performClick's blocking
/// animation loop inside SwiftPM's async-main process. Pointer feedback is
/// verified in the running application.
@MainActor
func activate(_ control: NSControl) throws {
    let action = try #require(control.action)
    #expect(control.sendAction(action, to: control.target))
}
