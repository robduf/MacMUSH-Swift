// Entry point. Code-only AppKit: no @main, no storyboard — just build the
// NSApplication, attach a delegate, and run.

#if canImport(AppKit)
import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
#else
import Foundation
print("MacMUSH is a macOS application and requires AppKit to run.")
#endif
