import AppKit
import Foundation
import SwiftTerm

@MainActor
@Observable
final class TerminalSession: NSObject, Identifiable, LocalProcessTerminalViewDelegate {
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

    enum Kind: String { case ssh, scp, local }

    init(blueskyid: Int, title: String, kind: Kind, executable: String, args: [String]) {
        self.title = title
        self.kind = kind
        self.blueskyid = blueskyid
        self.view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 320))
        super.init()
        // Pick up the operator's Terminal preferences (font size +
        // background / foreground / cursor colors) before the first
        // frame draws. Subsequent live changes are pushed in via
        // `applyAppearance(...)` from `TerminalSessionsManager`.
        Self.applyAppearance(to: view)
        if kind != .local {
            // The "what's about to run" preview gets fed to SwiftTerm
            // as a single big line. If args contain a base64-embedded
            // binary (the GUI Helper install ships a 237KB chat client
            // inline), the resulting 320KB line takes seconds to push
            // through SwiftTerm's VT100 state machine on the main
            // thread — that's the beachball, and the side-effect is
            // SSH/sudo prompts coming in can't render either. Sanitize
            // the display line to elide long base64 runs; the real
            // `args` going to startProcess are untouched.
            let displayLine = Self.sanitizeForTerminalDisplay(
                "\(executable) \(args.joined(separator: " "))"
            )
            view.feed(text: "\u{1B}[2m$ \(displayLine)\u{1B}[0m\r\n")
        }
        view.startProcess(
            executable: executable,
            args: args,
            environment: Self.fullEnvironment(termName: "xterm-256color")
        )
        // Surface child exit so a silent ssh/sudo failure shows up
        // instead of looking like "maybe it worked silently." Without
        // this, a 320KB install command that aborts before printing
        // anything just leaves the tab empty and the operator
        // guessing whether the script succeeded or died at line 2.
        view.processDelegate = self
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // No-op — SwiftTerm handles internal layout. Hook reserved for
        // when we add a status bar that needs the current cols/rows.
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // No-op — we use the host-derived title from init() and don't
        // honor OSC 0/2 retitles; would otherwise let a misbehaving
        // shell rewrite the tab name out from under us.
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // No-op.
    }

    /// Banner the exit code into the terminal so an immediate ssh/sudo
    /// failure is visible. Without this, a 320KB install command that
    /// crashes before printing anything just leaves a blank tab and
    /// the operator can't tell whether sudo ran or aborted.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        let banner: String
        if let code = exitCode {
            banner = code == 0
                ? "\r\n\u{1B}[2m[exited 0]\u{1B}[0m\r\n"
                : "\r\n\u{1B}[1;33m[exited \(code)]\u{1B}[0m\r\n"
        } else {
            banner = "\r\n\u{1B}[1;31m[exited unexpectedly — I/O error]\u{1B}[0m\r\n"
        }
        view.feed(text: banner)
    }

    /// Replace any contiguous base64 run of 200+ chars with a short
    /// placeholder. Same heuristic as `QuickActionSheet.sanitizeForDisplay`
    /// — keeps the preview readable and, more importantly, keeps the
    /// terminal renderer from choking on 320KB of opaque data.
    private static let base64BlobRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "[A-Za-z0-9+/]{200,}={0,2}")
    }()

    static func sanitizeForTerminalDisplay(_ command: String) -> String {
        // Pass 1: elide long base64 blobs (helper install / chat client
        // installer payloads etc.) so SwiftTerm doesn't have to render
        // 300KB of opaque data through its VT100 state machine.
        var out = command
        let nsCommand = out as NSString
        let range = NSRange(location: 0, length: nsCommand.length)
        let blobMatches = base64BlobRegex.matches(in: out, range: range)
        for match in blobMatches.reversed() {
            guard let r = Range(match.range, in: out) else { continue }
            let lenBytes = out.distance(from: r.lowerBound, to: r.upperBound)
            let kb = max(1, lenBytes / 1024)
            out.replaceSubrange(r, with: "<\(kb)KB base64 payload sent over SSH>")
        }
        // Pass 2: collapse bash line-continuations (`\` + newline +
        // leading whitespace) into a single space, so a multi-statement
        // shell payload renders as one logical line that the terminal
        // soft-wraps based on its width — instead of forty 80-column
        // lines with stray backslashes and ragged indentation.
        if let lineContRegex = try? NSRegularExpression(pattern: #"\\\s*\n\s*"#) {
            let r2 = NSRange(out.startIndex..., in: out)
            out = lineContRegex.stringByReplacingMatches(in: out, range: r2, withTemplate: " ")
        }
        return out
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

    /// Push the user's saved Terminal preferences into a SwiftTerm
    /// view. Reads `terminalFontSize` + the three color hex strings
    /// straight from UserDefaults (the same store `@AppStorage` writes
    /// to) so this stays usable from a non-SwiftUI context — e.g. the
    /// init path, where wiring up an `@AppStorage` would require
    /// turning the type into a `View`.
    static func applyAppearance(to view: LocalProcessTerminalView) {
        let d = UserDefaults.standard
        let size = d.object(forKey: "terminalFontSize") as? Double ?? 12.0
        // Pick a font face: empty name → system monospace; otherwise
        // try to load the saved PostScript name and fall back to system
        // monospace if it isn't installed (so an uninstalled face
        // silently degrades instead of crashing).
        let name = d.string(forKey: "terminalFontName") ?? ""
        if !name.isEmpty, let custom = NSFont(name: name, size: CGFloat(size)) {
            view.font = custom
        } else {
            view.font = NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
        }

        if let bg = NSColor.fromHex(d.string(forKey: "terminalBackgroundHex") ?? "") {
            view.nativeBackgroundColor = bg
        }
        if let fg = NSColor.fromHex(d.string(forKey: "terminalForegroundHex") ?? "") {
            view.nativeForegroundColor = fg
        }
        if let cur = NSColor.fromHex(d.string(forKey: "terminalCursorHex") ?? "") {
            view.caretColor = cur
        }

        // Custom 16-color ANSI palette. Stock xterm blue (#0225C7) and
        // bright blue (#6871FF) are unreadable on the Peppermint-style
        // dark backgrounds we ship as defaults — and operator shell
        // prompts (PS1, starship, oh-my-zsh) routinely paint the hostname
        // in ANSI blue. Remap ANSI 4 + 12 to white so that text reads
        // clearly without the operator needing to touch their PS1.
        view.installColors(BlueConnectAnsiPalette.colors)

        view.needsDisplay = true
    }

    /// Re-apply appearance to this session's view. Called by
    /// `TerminalSessionsManager` when the operator changes any
    /// `terminal*` setting, so live sessions update without needing
    /// to be closed + reopened.
    func reapplyAppearance() {
        Self.applyAppearance(to: view)
    }
}
