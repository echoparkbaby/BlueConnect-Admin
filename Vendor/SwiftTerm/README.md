# Vendored SwiftTerm

- Upstream: https://github.com/migueldeicaza/SwiftTerm, tag 1.13.0 (`8e7a1e1`). MIT, see LICENSE.
- Plus one patch, `terminal-app-text.patch` (from kfattic, PR #23): opt-in
  Terminal.app-style text (antialiasing off, bold options, Terminal.app line height).
- Only `Sources/SwiftTerm` is kept; `Package.swift` is trimmed to the library.

To update: copy `Sources/SwiftTerm` from a newer upstream tag, then
`git apply Vendor/SwiftTerm/terminal-app-text.patch` (paths are relative to the
SwiftTerm repo root, so run it with `--directory=Vendor/SwiftTerm`).
