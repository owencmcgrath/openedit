# OpenEdit — Architecture

Status legend used throughout this doc: **[Decided]** — settled, build against it. **[Default]** — a reasonable choice made to keep momentum; flag before deviating, but don't treat as immovable. **[Open]** — genuinely undecided; a task that hits this should ask rather than assume.

## 1. Goal

A native macOS text editor, launched from the CLI (`openedit <file>`), that behaves like TextEdit but with IDE-grade syntax highlighting and language-server-powered diagnostics/hover. Primary use case: a fast companion window for reviewing and lightly editing files while a terminal-based coding agent works on the same project.

## 2. Non-Goals (v1)

- No project/workspace concept — no sidebar, no multi-file navigation, no "open folder"
- No built-in terminal, git integration, task runner, or extension marketplace
- No Mac App Store distribution, no App Sandbox
- No three-way merge or diff view for external-edit conflicts
- No code completion or go-to-definition (limited value without a real project root anyway) — including AI-assisted completion (e.g. Apple's Foundation Models framework, considered and explicitly passed on): the point of this app is to open and edit files an agent is touching, not to be the place you write code from scratch
- Not optimized for very large files — correctness and simplicity over perf at this stage
- No bundled language runtimes (Node, Python, Ruby, Go), and no automatic installation of language servers — the app never runs package-manager commands on the user's behalf; at most it tells the user what to run

## 3. Users & Distribution

- Primary user: developers who want a native, keyboard-standard editor to glance at / tweak files an agent is also touching
- Distribution: **[Decided]** Developer ID signing + notarization, no App Store
- Channels: **[Decided]** Homebrew (personal tap initially, e.g. `brew install user/tap/openedit`), GitHub Releases as the canonical artifact, a website offering an optional DMG for non-brew users
- Auto-update: Sparkle for DMG installs; suppressed at launch when the running app's path indicates a Homebrew Caskroom install, deferring to `brew upgrade` instead

### 3.1 Build Tooling

- **[Decided]** Swift Package Manager project (`Package.swift`), not an `.xcodeproj` — no Interface Builder/storyboards, no Xcode.app required for local development. Everything in this doc already assumes code-driven AppKit (`NSRulerView`, `NSTextFinder`, programmatic window setup), so nothing depends on `.xib` files.
- Local build/run via `swift build` / `swift run`. `swift build` produces a bare executable, not a proper `.app` bundle (no `Info.plist`, no icon, no bundle structure) — a small packaging script (or a tool built for this, e.g. `swift-bundler`) assembles the actual `.app` after building.
- Code signing and notarization (`codesign`, `xcrun notarytool`, `xcrun stapler`) are CLI tools bundled with Command Line Tools, not gated behind the full Xcode IDE — the Developer ID + notarization pipeline (Section 9, task 9) is unaffected by not having Xcode installed locally.
- CI is not bound by this: GitHub Actions' macOS runners ship full Xcode pre-installed, so CI can use it if that's simplest there, independent of the local no-Xcode preference.

## 4. Component Map

| Component | Responsibility |
|---|---|
| CLI shim (`openedit`) | Resolves the file path, hands it to the running app instance (or launches one) |
| App shell | Menu bar app, `NSDocumentController`-driven window management, no project browser |
| Document/window layer | One `NSDocument` per open file; owns the `NSTextView`/`NSTextStorage`; renders a line-number gutter |
| File watcher | Detects external changes to the open file; drives the reload/conflict flow |
| Highlighter | Tree-sitter grammar per language; synchronous re-highlight on edit |
| LSP client | Spawns and owns a pool of language server processes; routes diagnostics/hover to the active document |
| Config loader | Reads the extension → grammar → LSP mapping file; supplies bundled defaults |
| Settings window | Houses per-user preferences — currently just the per-language "missing LSP notification" dismissal state (5.6) |

## 5. Component Contracts

These are the seams between components — pin these down precisely since they let each piece be built (or handed to an agent) independently.

### 5.1 CLI shim → App

- **[Default]** Fire-and-forget: `openedit file.py` resolves to an absolute path and calls `open -a OpenEdit.app <path>`, then exits immediately. No blocking `$EDITOR`-style wait mode in v1. (Empirically verified: `-n` forces a second app instance and breaks reuse, and `--args` are ignored when an instance is already running — so files must be passed as open-document arguments, delivered to the running instance as Apple Events.)
- **[Default, deferred]** A blocking `$EDITOR`-compatible mode is not being built for v1. Context: some CLI tools (`git commit`, `crontab -e`) launch whatever `$EDITOR` points to and *wait* for it to exit before continuing — e.g. `EDITOR="openedit --wait" git commit` would need `openedit` to hang until you close the window, then let `git` read the finished commit message. That requires real IPC (the CLI process blocking on a signal from the app when the window closes), which is more plumbing than the CLI shim in 5.1 currently has. Since the core use case here is reviewing/editing files alongside an agent — not standing in for `$EDITOR` in other tools — this is deferred (see Section 9), but the app-side entry point shouldn't be built in a way that makes adding it later awkward.
- App-side entry point: `NSApplicationDelegate.application(_:open:)`. `open -a` (no `-n`) reuses an already-running instance; if the file is already open, the existing window is brought forward rather than duplicated (standard `NSDocumentController` behavior).
- Optional `file.py:LINE:COL` suffix syntax for jump-to-position — **[Default]**, low priority, not required for v1.

### 5.2 Config file

- **[Decided]** Location: `~/.config/openedit/languages.toml` — TOML, for hand-editability.
- Schema (conceptually): two arrays of tables.
  - `[[language]]` — an explicit mapping, each with `extensions: [String]`, `languageId: String`, `grammar: String` (required here; tree-sitter grammar name), optional `binaryName: String` (checked against `PATH` to detect presence), optional `installCommand: String` (shown in the missing-LSP notification, 5.6), and optional literal `lspPath` override for non-standard install locations. No `binaryName` means highlighting-only, no LSP for that language; `installCommand` is optional even when `binaryName` is present, and both `installCommand` and `lspPath` require `binaryName` (they are LSP-only fields). An explicit `[[language]]` entry — even one with no server — **claims** its `languageId`: it suppresses autodetection for that language (this is how a user says "don't autodetect here", which is why a catalog-served language like python has no bundled `[[language]]` entry).
  - `[[knownServer]]` — the user-editable autodetection catalog (see the [Implemented #23] bullet below), each with `extensions: [String]` (required, non-empty — discovery is keyed by real file extensions, so an entry without any is unreachable and rejected), `languageId: String`, optional `grammar: String` (absent means LSP-only, plain text), `candidates: [String]` (required, non-empty, **ordered**; probed on `PATH` in order, first executable wins), and optional `installCommand: String` for the missing notice. A catalog entry applies only where no `[[language]]` entry claims its `languageId`.
- **[Implemented #23] LSP autodetection.** When a file's language has no explicit `[[language]]` server config, the app probes a bundled, user-editable known-server catalog for an installed server and uses it automatically — no prompt, no confirm step, no auto-install, no downloads, no package-manager calls (read-only `PATH` probing; Non-Goals §2 unchanged). Decisions recorded here (settled with the owner at the #23 decision gate):
  - **Catalog is data, like `BundledLanguages`.** The type and bundled entries live in `OpenEditConfig/KnownServer.swift` (`KnownServer`, `BundledKnownServers`), out of the locator's logic, so tests can inject fakes. Users edit/override it via `[[knownServer]]` in `languages.toml`, whole-entry replacement by `languageId` (same overlay rule as `[[language]]`).
  - **Precedence (one verdict per open, §5.6):** explicit `lspPath` → explicit `binaryName` → catalog `binaryAlternatives` (ordered, first hit) → `.missing` / `.highlightingOnly`. Explicit config always wins and autodetection never changes a language already configured with a server.
  - **"No server configured" vs "explicitly highlighting-only":** a `[[language]]` entry with no `binaryName` is highlighting-only and suppresses autodetection; the catalog only fills gaps where no `[[language]]` entry claims the `languageId`. Catalog candidates are folded into the registry as `ResolvedLanguage.binaryAlternatives`, so the locator needs no new input type.
  - **No-grammar case:** a catalog-only language may omit `grammar`; `ResolvedLanguage.grammar` is optional. The file opens as plain, editable text but still gets LSP (the inverse of highlighting-only). `[[language]]` still requires `grammar`.
  - **Notice:** a catalog language whose candidates are all missing gets exactly one missing notice carrying the catalog's `installCommand`, keyed by its `languageId`, so #8's dismissal/reset works unchanged.
  - **PATH scope:** the catalog reuses the same effective-process-`PATH` rule as #7 (never a login shell).
- **Bundled defaults ship inside the app** for common languages; the user file overrides/extends rather than fully replacing them. Bundled `[[language]]` entries (`BundledLanguages`) carry grammars but no server; bundled catalog entries (`BundledKnownServers`) carry the server candidates.
- **TOML parsing** uses `TOMLKit` (LebJe) — the only third-party dependency, confined to the `OpenEditConfig` module. Foundation has no TOML reader, and the loader walks the parsed tree itself so schema decisions are not inherited from the library. **[Decided]**
- **[Decided] Overlay semantics** (implemented in `LanguageConfigLoader`, tests in `Tests/OpenEditConfigTests`):
  - Loading the user file is optional; a missing file simply yields the bundled defaults.
  - A user entry with an existing `languageId` replaces that bundled entry **whole** (no field-by-field merge); a new `languageId` appends. Two user entries with the same `languageId`: the **later** one wins and the collision is reported with a diagnostic (same later-wins rule as duplicate extensions).
  - Duplicate extensions: the **later** entry wins (the user file is processed after the bundled defaults), and there is no removal syntax in v1.
  - An invalid entry (wrong type, unknown field, missing required field) is **skipped and reported** with a diagnostic carrying the config path, entry index, language ID, and field; its neighbors and all defaults are untouched. Malformed TOML keeps the defaults and returns a diagnostic. The loader never throws or crashes.
  - Extensions are normalized (trimmed, lowercased, leading dot stripped) before lookup and duplicate detection.
- **Bundled inventory.** The grammar names are verified for highlighting as of #5 (all five bundle a working parser and `highlights.scm`; see `AGENTS/GRAMMARS.md`). `binaryName`/`candidates`/`installCommand` remain names, not verified-working claims — PATH detection is #7/#23. Do not upgrade an LSP row to "verified" until a test or manual check proves it.

  **Explicit bundled `[[language]]` entries** (`BundledLanguages`):

  | Language ID | Extensions | Grammar | Server | Status |
  |---|---|---|---|---|
  | `json` | `json` | `json` | — | highlighting-only, grammar verified |
  | `markdown` | `md`, `markdown` | `markdown` | — | highlighting-only, grammar verified |
  | `toml` | `toml` | `toml` | — | highlighting-only, grammar verified |
  | `yaml` | `yaml`, `yml` | `yaml` | — | highlighting-only, grammar verified |

  **Bundled known-server catalog** (`BundledKnownServers`, autodetected; #23):

  | Language ID | Extensions | Grammar | Candidates (ordered) | Install command | Status |
  |---|---|---|---|---|---|
  | `python` | `py`, `pyw` | `python` | `pylsp`, `pyright-langserver` | `pip install python-lsp-server` | grammar verified (#5); candidates unverified |
  | `rust` | `rs` | — (LSP-only) | `rust-analyzer` | `rustup component add rust-analyzer` | unverified |
  | `go` | `go` | — (LSP-only) | `gopls` | `go install golang.org/x/tools/gopls@latest` | unverified |
  | `lua` | `lua` | — (LSP-only) | `lua-language-server` | `brew install lua-language-server` | unverified |


### 5.3 File watcher → Document

- Watcher fires on any external write to the open file's path.
- **[Decided as v1 approach]** If the document has no unsaved edits, reload silently. If it does, prompt: "File changed on disk — Keep Mine / Reload from Disk." No diff view, no merge, in v1.

### 5.4 Document → Highlighter

- On every text change, the document pushes the edited range to the highlighter; the highlighter re-tokenizes synchronously via the tree-sitter incremental parse and applies attributes to the affected range only (not the whole document).
- **[Default]** No async/background highlighting pipeline (i.e., no Neon-style viewport virtualization) unless real files show it's needed.
- **[Implemented #5]** The highlighter lives in the `OpenEditHighlighting` module (AppKit + `SwiftTreeSitter` + the bundled grammars); the app resolves a file's extension → `grammar` name through `OpenEditConfig` and hands it that name. It applies `InputEdit`s in UTF-16 coordinates (the binding is driven in UTF-16LE, so byte offsets are twice the code-unit offsets) and re-attributes the union of the edit and tree-sitter's `changedRanges`, expanded to whole lines. Attribute-only writes are filtered out of `NSTextStorageDelegate` so they never register as document changes, touch undo, or fight find/selection styling. A missing config mapping or an unbundled grammar leaves the text plain and editable with a `HighlightingDiagnostic` naming the cause. Grammars are pinned and their resource bundles are described in `AGENTS/GRAMMARS.md`. No departure from the synchronous `[Default]`.

### 5.5 Document → LSP client

- On open: `textDocument/didOpen` with full content, using `rootUri` = the file's parent directory (no real workspace).
- On edit: **[Decided]** full-document `didChange` sync (`TextDocumentSyncKind.Full`), not incremental deltas — simpler, correctness over micro-perf.
- Consumed in v1: diagnostics (rendered as underlines/gutter marks) and hover. Completion and go-to-definition are out of scope until there's a reason to revisit.
- One server process per language, shared across all open documents of that language; **[Decided]** idle lifetime uses a linger timeout — when the last document of a language closes, the server isn't killed immediately but kept alive for a short window (starting point: 5 minutes, tunable later) before shutting down. This matches the actual usage pattern: you're likely to open another file from the same project/language shortly after closing one, and re-spawning a language server is the slow part (often several seconds of startup + indexing), so avoiding that cost for a plausible next open is worth the idle memory. A file reopened within the window reuses the still-running server for free; one reopened after the timeout just pays the normal startup cost again.
- **[Implemented #6, Checkpoint A]** Transport and lifecycle live in the Foundation-only `OpenEditLSP` module (`ProcessTransport` over `Process` pipes with Content-Length framing, `LanguageServerClient` per process, `LSPProcessPool` per language); the app target supplies the thin wiring. Decisions recorded here:
  - **`rootUri` is `null`, a deviation from the line above.** LSP accepts roots only in `initialize`, and one process serves every same-language file, scattered or not, so a per-file root is not expressible. Approved for v1: null root (no workspace indexing) — right for scattered single-file peeks. Revisit only if a real server needs a root to provide diagnostics/hover.
  - **Full-document sync is one `didChange`** carrying the whole text; versions are owned by the pool and monotonic per document URI.
  - **Edits during handshake are buffered** (latest text wins) and flushed with the eventual `didOpen`, so typing during a slow server start is never lost.
  - **One verdict per open:** the pool spawns only for the `LanguageServerAvailability.available(path)` that 5.6's locator produced, so an open cannot both warn and launch.
  - **Failure handling:** launch failure or an unexpected process exit drops the client; already-open documents keep editing without LSP until reopened (no auto-respawn), and pending requests fail in place. Graceful shutdown writes `shutdown` + `exit`, closes stdin (EOF) so the server can exit itself, and terminates only as a bounded backstop.
  - **Malformed framing** (garbage bytes that cannot resynchronize) fails the connection rather than crashing or hanging.

### 5.6 Missing LSP Notification

**[Decided]** The app never installs language servers on the user's behalf. When a file is opened and the config (5.2) has an entry for that language but the specified binary isn't found on `PATH` (or at a user-configured literal path), the app posts a native macOS notification (via `UserNotifications`) — title along the lines of "Python language server not installed," body containing the exact command to run (e.g. `pip install python-lsp-server`). The file still opens immediately with tree-sitter highlighting only; the notification is informational, not a blocking dialog.

- Detection: on open, resolve the configured `binaryName` against `PATH` (and any user-specified literal path); if not found, fire the notification and proceed without an LSP for that document. **[Implemented #23]** When the language has no explicit `[[language]]` server config, the same check probes the bundled `[[knownServer]]` catalog's ordered candidates and uses the first executable found, so an unconfigured language can get LSP with no `languages.toml` entry; if every catalog candidate is missing, the notice is keyed by the catalog's `languageId` and carries its `installCommand`.
- Each registry entry (bundled or user-supplied) carries both a server selector (`binaryName`, or a catalog candidate list) for the PATH check and a human-readable `installCommand` string to display — no install logic is executed by the app itself.
- **[Decided]** Notification frequency: fires every time a file of that language is opened with no server found, unless the user has dismissed it via a "Don't show this again" option on the notification itself — that choice is persisted per-language (e.g. in `UserDefaults`, keyed by language ID), not globally, so dismissing the Python notification doesn't also silence Ruby's.
- Requires `UNUserNotificationCenter` authorization, requested on first launch or on first notification attempt.
- If the server later becomes available (user runs the install command), the *next* file opened for that language picks it up automatically via the same PATH check — no restart required, but the currently-open document doesn't retroactively gain LSP features without being reopened.
- **[Implemented #7]** Detection, persistence, and the notification policy live in the `OpenEditLSP` module (Foundation only, AppKit-free) so they are testable with a controlled `PATH` and a notification spy; the app target supplies the thin `UNUserNotificationCenter` edge. Decisions recorded here:
  - **PATH source**: the process's effective `PATH` (`ProcessInfo.environment["PATH"]`), never a spawned login shell's — availability must not depend on the user's dotfiles nor run a shell per open. If the process has no `PATH`, the documented fallback `/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` is used. **[Implemented #23]** Because GUI launches get launchd's stripped `PATH`, the well-known install directories `/opt/homebrew/bin` (Apple Silicon Homebrew), `/usr/local/bin` (Intel Homebrew), `~/.cargo/bin` (rustup), `~/go/bin` (`go install`), and `~/.local/bin` (pipx) are appended *after* the `PATH` entries, de-duplicated — an explicit `PATH` (e.g. pyenv/asdf shims) still wins, and this is a static list, not a shell probe. A configured `lspPath` is authoritative and does not fall through to `PATH` when it is not executable.
  - **One verdict per open**: `LanguageServerLocator` returns a `LanguageServerAvailability` (`.available(path)` / `.missing` / `.highlightingOnly`); #7 notifies on `.missing` and #6 must consult the same result before spawning, so a single open cannot both warn and launch.
  - **Persistence**: one `UserDefaults` boolean per language, key `missingLSP.suppressed.<languageId>` (`MissingLSPSuppressionStore.keyPrefix`). Per-language, so dismissing Python leaves Ruby notifying; #8 reads/resets these same keys.
  - **Dismissal semantics**: only the registered `UNNotificationAction` "Don't show again" persists a suppression; an ordinary click/dismiss uses the default action and does not. Authorization is requested at first launch and again lazily before a notice; denial never blocks opening a file and the OS will not prompt twice. Body text is the configured `installCommand` verbatim (a fallback sentence naming `binaryName` — or the first catalog candidate — is used when it is absent).
  - **[Implemented #8] Removed-language behavior (recorded before coding)**: a saved dismissal for a `languageId` that no longer has a config entry is **kept and listed**, not cleaned up. Settings reads the raw persisted keys (5.6's `MissingLSPSuppressionStore.suppressedLanguageIDs`), so the row is shown with the fallback capitalized-ID name and marked "no longer configured"; its Reset control still clears the stored key. Discarding the key because a mapping changed would silently reverse a user choice the moment a user file is edited or a bundled entry is renamed, which the task forbids. Reset itself is per-language and immediate: it removes only that language's key (never another's), persists at once, and posts no notice — eligibility returns on the *next new file open*, and an installed server never produces a missing notice.

### 5.7 Line Number Gutter

**[Default]** Implemented as an `NSRulerView` attached to the scroll view's `verticalRulerView`, the standard AppKit mechanism for editor gutters (this is how Xcode and BBEdit do it) — it tracks the text view's line-fragment geometry automatically on scroll/wrap/zoom, rather than a hand-rolled overlay `NSView` that has to stay manually in sync. Redraws on `NSTextView`'s `didChangeSelection`/text-change notifications to keep the current-line indicator (if any) and digit count (for files crossing power-of-ten line counts) up to date.

### 5.8 Appearance / Theming

**[Decided]** No custom theme engine, no user-selectable color schemes in v1 — the app follows system light/dark appearance everywhere, full stop, in service of feeling as much like a native macOS app as possible. Concretely: syntax highlighting maps tree-sitter token types to AppKit's *dynamic* system colors (`NSColor.labelColor`, `.systemBlue`, `.systemGreen`, `.systemPurple`, `.secondaryLabelColor`, etc.) rather than hardcoded hex values — dynamic colors automatically resolve to the right value for the current appearance, so highlighting adapts to Dark Mode with zero extra code. Window chrome, the gutter, and diagnostics coloring (5.9) follow the same rule.

**[Decided]** Standard, unmodified `NSWindow` title-bar chrome — no custom-drawn traffic lights, no `titlebarAppearsTransparent` tricks. This means OS-level window-chrome redesigns (e.g. macOS 27's Liquid Glass traffic light buttons) are inherited automatically with zero app-side code, in both AppKit and SwiftUI, since both sit on the same underlying `NSWindow`. Custom traffic lights would trade that free upkeep for a copy the app has to maintain and re-match every time Apple changes the design. Window chrome, the gutter, and diagnostics coloring (5.9) follow the same rule.

### 5.9 Diagnostics

Diagnostics are the errors/warnings/hints a language server reports about the open file — things like a syntax error, a type mismatch, an unused variable, or a lint violation. The server pushes these unprompted via the `textDocument/publishDiagnostics` LSP notification whenever it reprocesses the file after an edit; each diagnostic carries a text range (start/end position in the file), a severity (Error / Warning / Information / Hint), and a human-readable message.

**[Default]** Rendering: a colored squiggle/underline beneath the affected range, colored by severity using system semantic colors (e.g. `.systemRed` for errors, `.systemYellow` for warnings) so it stays theme-consistent per 5.8. The message text itself is revealed on hover, via a small popover/tooltip anchored to the range — no separate "Problems panel" list in v1, since that's more IDE chrome than this app wants (Section 2).

- **[Implemented #6, Checkpoint B]** Model and rendering:
  - **Parsing and range mapping** live in `OpenEditLSP` (`Diagnostic`, `DiagnosticsPublish`, `LSPPosition`/`LSPRange`, `DocumentDiagnostics`) and are unit-tested. LSP positions are UTF-16 code units, which is exactly `NSString`'s unit — no transcoding, only line-offset bookkeeping. Ranges are validated against the live text (a line past the document or an inverted range is dropped; an end `character` past a line's end clamps to the line end).
  - **Staleness:** a publish is accepted only while the document is unedited (and, when the server sends an optional `version`, only when it matches the version the client last sent). Every edit or reload invalidates the current set — underlines clear until the server republishes — so diagnostics never describe stale text. Closed documents receive nothing (the window controller filters by URI and the pool reports no version).
  - **Underlines are temporary `NSLayoutManager` attributes** (`.underlineStyle`/`.underlineColor`), never `NSTextStorage` attributes: they do not touch syntax colors, undo, the change count, or `NSTextFinder`'s own temporary match styling. Color follows 5.8's dynamic-system-color rule (error `.systemRed` and thicker, warning `.systemOrange`, information `.systemBlue`, hint `.secondaryLabelColor`).
  - **Diagnostic message on hover** uses the native `NSView` tooltip mechanism (`addToolTip` + `view(_:stringForToolTip:point:userData:)` on `EditorTextView`), resolving the pointer's character index to the containing (or zero-length) diagnostic.
  - **Server hover (`textDocument/hover`)** is requested on pointer move with a short debounce; the result (string, `MarkupContent`, or `MarkedString[]`) is flattened to plain text and shown in an `NSPopover`. Requests are async, so typing is never blocked, and a response that loses a race with an edit, a close, or a newer pointer position is dropped. Diagnostic messages take precedence over a server hover at the same point. Content is rendered as plain text in v1 (no Markdown engine).

### 5.10 Find & Replace

**[Default]** Uses AppKit's built-in `NSTextFinder` (the same find-bar mechanism as Safari and TextEdit) wired to the `NSTextView` via `performTextFinderAction`, rather than a hand-built find UI. This gets Cmd-F find, Cmd-Option-F find-and-replace, "Find All," and match highlighting for free, in the system's own visual style — directly in line with 5.8's "feel like a native Mac app" goal, and very little code to wire up.

### 5.11 Saving

**[Decided]** Explicit save only — Cmd-S, standard `NSDocument` dirty-state tracking, no autosave-on-every-keystroke. This pairs deliberately with the file-watcher design in 5.3: local edits are always something you chose to commit to disk, so the "did the file change under me" question (external agent edit vs. your own autosave) stays unambiguous — autosave would blur that line and make the reload/conflict logic harder to reason about.

### 5.12 Document icon presentation

**[Decided]** Open documents show the macOS-provided icon for the file's type (LaunchServices) instead of the generic plain-text icon, so a `.py` or `.json` window looks like the file it is. This is presentation only: `TextDocument.fileType` stays `public.plain-text` (5.11), so `writeSafely`/`data(ofType:)` are unchanged and unregistered extensions stay writable — the save machinery never has to resolve a per-extension writable type. The icon comes from `NSWorkspace.shared.icon(forFile:)` keyed off the file URL, independent of the highlighter grammar mapping and LSP availability (a file can show a language icon with no grammar or server). Scope is the window title-bar proxy icon: `DocumentWindowController` sets `window.representedURL` and the document icon button, refreshed via `synchronizeWindowTitleWithDocumentName()` so Save As updates it. Untitled documents clear the proxy icon (no file URL); Save As gives the document its URL and the type icon. Unregistered extensions fall back to LaunchServices' generic document icon. No bundled icon assets; bare `swift run` degrades to whatever LaunchServices resolves. **Document-icon presentation in the Dock tile and app switcher remains out of scope:** the tile is app-level rather than a document surface, showing a per-document icon there is non-standard, and LaunchServices document icons lack the resolution for Dock-size rendering. (App-level Dock *presence* — whether the icon shows at all — is 5.13.)

### 5.13 Dock presence

**[Decided]** The app hides its Dock icon while it has no document windows open, and shows it again as soon as a document window exists. The process deliberately outlives its windows (`applicationShouldTerminateAfterLastWindowClosed` returns `false` — the CLI shim, file watcher, and LSP pool all live in it), so an idle, windowless app should not keep occupying the Dock. `DockPresenceController` maps open-document-window count to `NSApplication.ActivationPolicy`: `.regular` while at least one document window exists, `.accessory` (no Dock icon, no menu bar, still reachable via the app switcher and the CLI) once they are all gone. **Only document windows count** — the Settings window (#8) is a transient auxiliary surface and does not keep the app in the Dock. Miniaturized document windows still count, so the icon never disappears while a window the user can only restore from the Dock remains. Reopening a window is the existing CLI/`open`-event path (#2/#15); no menu-bar status item is added. While hidden, the bare-executable Untitled backstop in `AppDelegate.applicationDidBecomeActive` is suppressed so activating a windowless app from the app switcher does not resurrect a window (owner decisions, #32). Rejected: `.prohibited` (removes the app switcher entry too, making it harder to reach a windowless app); an always-regular app (the status quo this issue exists to change).

## 6. Key Decisions (rationale + rejected alternatives)

**No App Sandbox / no App Store.** LSP servers are arbitrary third-party executables (installed via npm/pip/brew, in unpredictable locations); the sandbox does not permit spawning those. Panic hit the identical wall with Nova and shipped Developer-ID-only for the same reason. Rejected: a Mac-App-Store build with only bundled/self-compiled LSPs — possible, but turns "point at whatever's installed" into "vendor and update every language server yourself," which cuts against the actual use case (working alongside whatever LSPs the user already has for their agent workflow).

**Full-document LSP sync over incremental.** Incremental sync avoids resending the whole file on every keystroke, which matters for large files in long-lived IDE sessions. This app's documents are typically single files, edited in short sessions — the complexity of correct incremental offset math isn't worth it yet. Rejected: incremental sync as the default; can be revisited per-language if a particular server or file size makes full sync noticeably slow.

**Tree-sitter direct, not via Neon.** Neon's value is async, viewport-aware highlighting for large files in a persistent IDE. This app's files are typically small-to-medium and short-lived; a direct synchronous `SwiftTreeSitter` integration is far less code. Rejected: adopting Neon up front — deferred until a real perf problem shows up, not built preemptively.

**Naive reload-on-external-change over diff/merge.** The actual usage pattern is reviewing while an agent writes, not simultaneous overlapping edits on the same lines. A silent-reload-when-clean, prompt-on-conflict model covers the common case cheaply. Rejected: a diff view or three-way merge for v1 — real engineering cost for a case that may rarely occur in practice; revisit if edits get lost.

**Notify with an install command, over auto-installing the LSP.** Auto-installing (running `npm`/`pip`/`gem`/`go` on the user's behalf, or downloading and executing binaries from GitHub releases) adds real complexity — toolchain detection, quarantine/Gatekeeper handling for downloaded binaries, a versioning/update story for managed installs — for a feature whose only advantage is skipping one command the user would otherwise type once per language, ever. Surfacing a native notification with the exact command to run gets the same "opens a `.py` file, finds out what to do" experience with none of that machinery, and keeps the app from silently executing package-manager commands without the user having asked it to — which matters more once this is meant for other people to run, not just personal dogfooding.

## 7. Open Questions

None currently outstanding for v1 — all three items from the last round (config format, LSP idle lifetime, blocking CLI mode) are resolved above. New ones will surface during implementation; add them here as they come up.

## 8. Deferred to v1.1+

Things worth remembering, not worth building now:

- Crash/error reporting (nothing in v1 — no crash reporter wired up at all yet)
- Blocking `$EDITOR`-compatible CLI mode (Section 5.1) — revisit if a real need for `git commit`/`crontab -e`-style usage shows up

## 9. Build Sequence

Each numbered item is a candidate for its own task spec (separate file), scoped small enough to have a one-sentence "done" test. Later items depend on earlier ones.

1. Bare `NSWindow` + `NSTextView` app with a line-number gutter (5.7) and native find/replace via `NSTextFinder` (5.10); `application(_:open:)` opens a file passed as a launch argument — no highlighting, no LSP
2. `openedit` CLI shell wrapper; confirm `open -na` reuses the running instance and brings existing-file windows forward
3. File watcher + reload/conflict prompt (5.3), explicit Cmd-S save only (5.11)
4. Config loader (5.2) — TOML, implement schema + bundled defaults
5. Tree-sitter highlighting keyed off the config's grammar mapping, using dynamic system colors (5.4, 5.8)
6. LSP process pool with idle-linger (5.5) + full-document sync + diagnostics rendering (5.9) + hover
7. Missing-LSP detection (PATH check) + native notification with install command (5.6)
8. Settings window — per-language notification dismissal reset, at minimum
9. Codesigning + notarization CI pipeline (GitHub Actions, tag-triggered)
10. Homebrew tap (cask + `binary` stanza for the CLI shim) + DMG packaging + Sparkle with Caskroom detection
