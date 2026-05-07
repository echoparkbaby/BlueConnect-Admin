import AppKit
import Foundation
import SwiftTerm

@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    let title: String
    let kind: Kind
    let blueskyid: Int
    @ObservationIgnored let view: LocalProcessTerminalView
    var isRunning: Bool = true
    /// True while the session lives in its own floating window. Hidden
    /// from the tab bar and from the main bottom-pane content while
    /// detached, since the same NSView can't be in two hierarchies.
    var isDetached: Bool = false

    enum Kind: String { case ssh, scp }

    init(blueskyid: Int, title: String, kind: Kind, executable: String, args: [String]) {
        self.title = title
        self.kind = kind
        self.blueskyid = blueskyid
        self.view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 320))
        view.feed(text: "\u{1B}[2m$ \(executable) \(args.joined(separator: " "))\u{1B}[0m\r\n")
        view.startProcess(
            executable: executable,
            args: args,
            environment: Self.fullEnvironment(termName: "xterm-256color")
        )
    }

    private static func fullEnvironment(termName: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = termName
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        return env.map { "\($0.key)=\($0.value)" }
    }

    func terminate() {
        if let pid = view.process.shellPid as pid_t? {
            kill(pid, SIGTERM)
        }
        isRunning = false
    }
}
