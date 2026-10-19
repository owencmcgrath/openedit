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
| Settings window | Language-server inventory: per-language install status, resolved paths/commands with Copy, and config diagnostics (5.14) |

## 5. Component Contracts

These are the seams between components — pin these down precisely since they let each piece be built (or handed to an agent) independently.

### 5.1 CLI shim → App

- **[Default, except `--wait`]** Fire-and-forget: `openedit file.py` resolves to an absolute path and calls `open -a OpenEdit.app <path>`, then exits immediately. The only blocking path is the explicit `--wait` mode added by #46. (Empirically verified: `-n` forces a second app instance and breaks reuse, and `--args` are ignored when an instance is already running — so files must be passed as open-document arguments, delivered to the running instance as Apple Events.)
- **[Implemented #22] Reuse is the default; `--new-window` opts out.** A plain open reuses the frontmost document window, tabbing the file into it rather than spawning a window. The flag cannot travel to an already-running instance (see the verified mechanics above), so the opt-out is carried as the host of a custom `openedit://new-window?path=...` URL (`--reuse-window` is accepted as the explicit no-op form of the default); the app registers the `openedit` scheme and parses it in `application(_:open:)` via `OpenEditWindowing`. Decisions settled with the owner at the #22 gates: presentation is a **native macOS tab** (each file keeps its own `NSDocument`/window controller, grouped by a shared `tabbingIdentifier`), the target is the **frontmost** reusable document window, and reuse falls back to a normal new window when there is no such window (not running, no windows, or only a launch-created empty Untitled window, which is skipped). The reuse-vs-new decision is the Foundation-only `OpenPlacementRouter` so it is unit-testable without a window server; the shim stays fire-and-forget.
  - **Placement seam (verified while implementing #22):** AppKit delivers file-open Apple Events (`odoc`) straight to `NSDocumentController` — *not* to the delegate's `application(_:open:)`, which only receives URL-scheme (`GURL`) opens. So the placement decision and tabbing live in `OpenEditDocumentController.openDocument(withContentsOf:display:completionHandler:)` (`Sources/OpenEdit/AppDelegate.swift`), which forces `display: false` on the superclass, resolves the target from `NSApp.orderedWindows`, and either `addTabbedWindow`s the new document or shows it as its own window. The scheme-derived intent reaches it through `OpenEditDocumentController.pendingIntent`; a plain odoc open leaves that `nil` and defaults to reuse.
- **[Promoted #46] Blocking `$EDITOR`-compatible mode.** Deferred for v1, then promoted to work by #46 with the status-file IPC described below: `EDITOR="openedit --wait" git commit` blocks the shim until the commit-message document closes. The app-side hooks (`TextDocument.close`, `writeSafely`) already own the two events the waiter needs.
- App-side entry points: `NSApplicationDelegate.application(_:open:)` for URL-scheme opens, and `NSDocumentController.openDocument(withContentsOf:display:completionHandler:)` for file opens. `open -a` (no `-n`) reuses an already-running instance; if the file is already open, the existing window is brought forward rather than duplicated (standard `NSDocumentController` behavior), for both intents.
- **[Implemented #46] Developer CLI flags.** The shim's flag surface is settled with the owner at the #46 gate; `Scripts/openedit` parses the flags, validates them, and carries everything that must affect an already-running instance as query items on the same `openedit://` URL (the `#22` transport constraint). A plain `open -a` is used only for a bare default open with no options. Decisions recorded here:
  - **Range grammar.** 1-based, inclusive. A single position is `file:LINE[:COL]` or `--line N` / `--col N`; a line range is `file:START-END` or `--line START-END`; a column range is `--col START-END` and applies to the selection endpoints. Two lines or two columns therefore opens with that range selected. A single position resolves to a **caret**: the caret carries a concrete column (the line's start when none was given) so it is never read as a whole-line highlight; an explicit one-line range (`file:12-12`) still selects the whole line, and a single column on a line range applies that column to both endpoints. A line range with no columns selects whole lines; a single line with two columns selects that span on the line. Position flags are accepted only when the request names exactly one file (per-file suffixes may be mixed, but not combined with global `--line`/`--col`). Columns count UTF-16 code units, matching AppKit's selection APIs; positions are clamped to the document.
  - **`--wait` IPC.** The shim creates a JSON status file under `$TMPDIR`, passes its token as `wait=<token>`, and polls (~100ms); the app **owns the file from its first write**, updating it on save (`state: saved`, `path`) and on document close (`state: closed`), and sweeps stale tokens at launch; the shim removes the file on completion or timeout. "Closed" means the document/tab closes, not the whole window, so `EDITOR="openedit --wait" git commit` returns when the commit-message tab closes. Handshake has a bounded timeout (10s); after the app acknowledges, there is no timeout. `--print-filename` requires `--wait` and prints the final saved path. A stale token is ignored and swept. Extension-less `$EDITOR` targets (git's `COMMIT_EDITMSG`, `.git/MERGE_MSG`) resolve to `public.data`, which `CFBundleDocumentTypes` claims (rank `Alternate`, so OpenEdit is never the default handler for arbitrary files); non-text files a user force-opens still fail the read cleanly with the not-decodable error.
  - **`--stdin`.** The shim writes stdin to `$TMPDIR/openedit-stdin-<uuid>` and sends it as a scratch target. The app deletes the temp file when the document is closed/discarded, not when it is saved elsewhere via Save As; stale `openedit-stdin-*` files are swept at launch.
  - **`--reopen`.** A last-closed MRU stack in `UserDefaults` (capped, de-duplicated), Cmd-Shift-T style. Each `--reopen` reopens the most recent file-backed document; untitled/scratch documents are not recorded.
  - **`--tabs` / `--no-tabs`.** Aliases: `--tabs` is the explicit default (reuse/tab into the frontmost window), `--no-tabs` is an alias for `--new-window`. No separate `tabbingMode = .disallowed` mode.
  - **`--config` / `--no-config`.** Per-document, carried in the URL: the document loads its own `LanguageRegistry` snapshot from that path (or bundled defaults only for `--no-config`). This works against an already-running instance. `--force-language` is likewise a per-document override.
  - **Logging.** A small `OpenEditLog` layer (OSLog subsystem `com.openedit.app` + optional append-only file sink, levels error/warn/info/debug) backs `--log-level`, `--log-file`, and `--debug`. It is runtime-reconfigurable so the flags also apply to a running instance; `--debug` implies debug level and verbose shim output.
  - **`--encoding`.** The shim validates the charset name against the platform charset list (dash/underscore/case-insensitive) and exits 2 on an unknown name, so a typo cannot silently fall back to UTF-8 on save; the app additionally warns in `OpenEditLog` if the requested charset still cannot encode a document at save time.
  - **`--lsp-log`.** The stderr sink binds **per language at spawn**: the sink recorded when a language server spawns stays for that process's lifetime; a shared, already-running server is never re-scoped by a later `--lsp-log` open, and the newest recorded sink applies at respawn. The sink is spawn input to the transport, not process-global state, and per-document `--lsp-log` is therefore not possible (§5.5's one server per language).
  - **`--json` breadth.** `--app-path` is an accepted alias of `--app`; `--read-only` of `-R`/`--readonly`; both appear in the usage text. `--json` applies to every informational shim output — `--version`, `--print-app-path`, `--selftest`, and `--dry-run`.
  - **Delivery.** Two reviewable slices on the #46 branch, both landing with tests: (1) shim/parser + URL/intent model, position/range, per-document editor/config/LSP/watcher options, and logging; (2) `--wait`/`--print-filename`, `--stdin`/`--scratch`/`--temp`, `--reopen`, and window size/position/session flags.
  - **App plumbing.** Parsed options ride through `OpenEditDocumentController.pendingOpenOptions` into `TextDocument.read`/`makeWindowControllers`, so per-document config, encoding, EOL, highlighting, LSP, and watcher choices apply to the document being opened rather than to the whole process. Re-opening an **already-open** document brings it forward and applies only the position/range selection, activation, and wait state; the per-document editor options above are first-open-only and do not rebuild the live window (owner decision, #46). LSP opens also pass the resolved `languageID` explicitly, because a per-document config snapshot can differ from the process-wide default registry.

### 5.2 Config file

- **[Decided]** Location: `~/.config/openedit/languages.toml` — TOML, for hand-editability.
- Schema (conceptually): two arrays of tables.
  - `[[language]]` — an explicit mapping, each with `extensions: [String]`, `languageId: String`, `grammar: String` (required here; tree-sitter grammar name), optional `binaryName: String` (checked against `PATH` to detect presence), optional `installCommand: String` (shown in Settings → Languages, 5.14), and optional literal `lspPath` override for non-standard install locations. No `binaryName` means highlighting-only, no LSP for that language; `installCommand` is optional even when `binaryName` is present, and both `installCommand` and `lspPath` require `binaryName` (they are LSP-only fields). An explicit `[[language]]` entry — even one with no server — **claims** its `languageId`: it suppresses autodetection for that language (this is how a user says "don't autodetect here", which is why a catalog-served language like python has no bundled `[[language]]` entry).
  - `[[knownServer]]` — the user-editable autodetection catalog (see the [Implemented #23] bullet below), each with `extensions: [String]` (required, non-empty — discovery is keyed by real file extensions, so an entry without any is unreachable and rejected), `languageId: String`, optional `grammar: String` (absent means LSP-only, plain text), `candidates: [String]` (required, non-empty, **ordered**; probed on `PATH` in order, first executable wins), and optional `installCommand: String` for the Languages inventory (5.14). A catalog entry applies only where no `[[language]]` entry claims its `languageId`.
- **[Implemented #23] LSP autodetection.** When a file's language has no explicit `[[language]]` server config, the app probes a bundled, user-editable known-server catalog for an installed server and uses it automatically — no prompt, no confirm step, no auto-install, no downloads, no package-manager calls (read-only `PATH` probing; Non-Goals §2 unchanged). Decisions recorded here (settled with the owner at the #23 decision gate):
  - **Catalog is data, like `BundledLanguages`.** The type and bundled entries live in `OpenEditConfig/KnownServer.swift` (`KnownServer`, `BundledKnownServers`), out of the locator's logic, so tests can inject fakes. Users edit/override it via `[[knownServer]]` in `languages.toml`, whole-entry replacement by `languageId` (same overlay rule as `[[language]]`).
  - **Precedence (one verdict per open, §5.6):** explicit `lspPath` → explicit `binaryName` → catalog `binaryAlternatives` (ordered, first hit) → `.missing` / `.highlightingOnly`. Explicit config always wins and autodetection never changes a language already configured with a server.
  - **"No server configured" vs "explicitly highlighting-only":** a `[[language]]` entry with no `binaryName` is highlighting-only and suppresses autodetection; the catalog only fills gaps where no `[[language]]` entry claims the `languageId`. Catalog candidates are folded into the registry as `ResolvedLanguage.binaryAlternatives`, so the locator needs no new input type.
  - **No-grammar case:** a catalog-only language may omit `grammar`; `ResolvedLanguage.grammar` is optional. The file opens as plain, editable text but still gets LSP (the inverse of highlighting-only). `[[language]]` still requires `grammar`.
  - **Inventory:** a catalog language whose candidates are all missing shows as "Server not installed" in Settings → Languages with its `installCommand` (5.14).
  - **PATH scope:** the catalog reuses the same effective-process-`PATH` rule as #7 (never a login shell).
- **Bundled defaults ship inside the app** for common languages; the user file overrides/extends rather than fully replacing them. Bundled `[[language]]` entries (`BundledLanguages`) carry grammars but no server; bundled catalog entries (`BundledKnownServers`) carry the server candidates.
- **TOML parsing** uses `TOMLKit` (LebJe) — the only third-party dependency, confined to the `OpenEditConfig` module. Foundation has no TOML reader, and the loader walks the parsed tree itself so schema decisions are not inherited from the library. **[Decided]**
- **[Decided] Overlay semantics** (implemented in `LanguageConfigLoader`, tests in `Tests/OpenEditConfigTests`):
  - Loading the user file is optional; a missing file simply yields the bundled defaults.
  - A user entry with an existing `languageId` replaces that bundled entry **whole** (no field-by-field merge); a new `languageId` appends. Two user entries with the same `languageId`: the **later** one wins and the collision is reported with a diagnostic (same later-wins rule as duplicate extensions).
  - Duplicate extensions: the **later** entry wins (the user file is processed after the bundled defaults), and there is no removal syntax in v1.
  - An invalid entry (wrong type, unknown field, missing required field) is **skipped and reported** with a diagnostic carrying the config path, entry index, language ID, and field; its neighbors and all defaults are untouched. Malformed TOML keeps the defaults and returns a diagnostic. The loader never throws or crashes.
  - **[Implemented #51]** The load result also reports `userConfiguredLanguageIDs`: the explicit `languageId`s that came from the user's `[[language]]` entries, so the Settings dashboard can label Bundled vs. Your config (5.14). It is provenance only — the registry shape and overlay semantics are unchanged, and a user `[[knownServer]]` entry is deliberately not included because it is autodetected behavior.
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

### 5.6 Language Server Availability

**[Decided]** The app never installs language servers on the user's behalf. When a file is opened and the config (5.2) has an entry for that language but the specified binary isn't found on `PATH` (or at a user-configured literal path), the file still opens immediately with tree-sitter highlighting only. The Settings window's Languages tab (5.14) shows the language as "Server not installed" with the configured install command, and the app never runs that command.

- Detection: on open, resolve the configured `binaryName` against `PATH` (and any user-specified literal path); the pool must not attempt a launch on a miss. **[Implemented #23]** When the language has no explicit `[[language]]` server config, the same check probes the bundled `[[knownServer]]` catalog's ordered candidates and uses the first executable found, so an unconfigured language can get LSP with no `languages.toml` entry.
- Each registry entry (bundled or user-supplied) carries both a server selector (`binaryName`, or a catalog candidate list) for the PATH check and a human-readable `installCommand` string to display — no install logic is executed by the app itself.
- If the server later becomes available (user runs the install command), the *next* file opened for that language picks it up automatically via the same PATH check — no restart required, but the currently-open document doesn't retroactively gain LSP features without being reopened.
- **[Implemented #7]** Detection lives in the `OpenEditLSP` module (Foundation only, AppKit-free) so it is testable with a controlled `PATH`; the process pool (#6) and the Settings inventory (#51) consume the same result. Decisions recorded here:
  - **PATH source**: the process's effective `PATH` (`ProcessInfo.environment["PATH"]`), never a spawned login shell's — availability must not depend on the user's dotfiles nor run a shell per open. If the process has no `PATH`, the documented fallback `/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` is used. **[Implemented #23]** Because GUI launches get launchd's stripped `PATH`, the well-known install directories `/opt/homebrew/bin` (Apple Silicon Homebrew), `/usr/local/bin` (Intel Homebrew), `~/.cargo/bin` (rustup), `~/go/bin` (`go install`), and `~/.local/bin` (pipx) are appended *after* the `PATH` entries, de-duplicated — an explicit `PATH` (e.g. pyenv/asdf shims) still wins, and this is a static list, not a shell probe. A configured `lspPath` is authoritative and does not fall through to `PATH` when it is not executable.
  - **One verdict per open**: `LanguageServerLocator` returns a `LanguageServerAvailability` (`.available(path)` / `.missing` / `.highlightingOnly`); #6 must consult the same result before spawning, so a single open cannot misreport and launch.
  - **[Implemented #51] Notifications removed end-to-end (owner decision).** The missing-LSP notification, its "Don't show again" action, the per-language suppression store, the app-side authorization/wiring, and #46's CLI suppression flags are gone; install guidance lives in Settings → Languages (5.14), where the row shows the resolved path or the install command with a Copy action. Orphaned `missingLSP.suppressed.*` keys are swept from user defaults at launch. Supersedes #7/#8.

### 5.7 Line Number Gutter

**[Default]** Implemented as an `NSRulerView` attached to the scroll view's `verticalRulerView`, the standard AppKit mechanism for editor gutters (this is how Xcode and BBEdit do it) — it tracks the text view's line-fragment geometry automatically on scroll/wrap/zoom, rather than a hand-rolled overlay `NSView` that has to stay manually in sync. Redraws on `NSTextView`'s `didChangeSelection` notification, and its cached line starts are invalidated on every character edit — user edits through the window controller's `NSTextStorage` delegate, programmatic replacement (initial load, watcher reload) via an explicit call — because a programmatic `NSTextView.string` replacement posts no `NSText.didChangeNotification`, while the storage-level notification it does post (`NSTextStorage.didProcessEditingNotification`) also fires on the highlighter's attribute-only rounds, so the delegate hook (which sees the edit mask) keeps invalidation scoped to real character edits (#37), keeping the digit count (for files crossing power-of-ten line counts) up to date.

### 5.8 Appearance / Theming

**[Decided]** No custom theme engine, no user-selectable color schemes in v1 — the app follows system light/dark appearance everywhere, full stop. The editor's palette is **GitHub's**: the Light Default + Dark Default token set of `primer/github-vscode-theme` (6.3.5, built from `@primer/primitives` 7.10.0), the same theme GitHub ships for VS Code. Concretely: syntax highlighting maps tree-sitter token types to the theme's token colors (`GitHubPalette` — keyword red, string deep blue, function purple, type/variable orange, …), and the editor surface uses the theme's `editor.*` colors — background `#ffffff`/`#0d1117`, foreground `#1f2328`/`#e6edf3`, blue caret and 20%-alpha blue selection, and the gutter's muted/active line numbers. All of them are *dynamic* `NSColor`s (`NSColor(name:dynamicProvider:)` carrying the light and dark hex), the same mechanism the previous system-color mapping used, so highlighting adapts to Dark Mode with zero extra code; the exact hex values are pinned per appearance in `OpenEditHighlighting`'s tests. Non-editor window chrome keeps AppKit's system semantic colors, and diagnostics coloring (5.9) stays on system colors (red/orange/blue squiggles) per 5.9.

**[Decided]** Standard, unmodified `NSWindow` title-bar chrome — no custom-drawn traffic lights, no `titlebarAppearsTransparent` tricks. This means OS-level window-chrome redesigns (e.g. macOS 27's Liquid Glass traffic light buttons) are inherited automatically with zero app-side code, in both AppKit and SwiftUI, since both sit on the same underlying `NSWindow`. Custom traffic lights would trade that free upkeep for a copy the app has to maintain and re-match every time Apple changes the design. Window chrome and diagnostics coloring (5.9) follow the same rule; the editor surface (5.7's gutter included) is the one themed exception, using the GitHub palette above.

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

**[Decided]** The app hides its Dock icon while it has no document windows open, and shows it again as soon as a document window exists. The process deliberately outlives its windows (`applicationShouldTerminateAfterLastWindowClosed` returns `false` — the CLI shim, file watcher, and LSP pool all live in it), so an idle, windowless app should not keep occupying the Dock. `DockPresenceController` maps open-document-window count to `NSApplication.ActivationPolicy`: `.regular` while at least one document window exists, `.accessory` (no Dock icon, no menu bar, still reachable via the app switcher and the CLI) once they are all gone. **Only document windows count** — the Settings window (#8) is a transient auxiliary surface and does not keep the app in the Dock. Miniaturized document windows still count, so the icon never disappears while a window the user can only restore from the Dock remains. Reopening a window is the existing CLI/`open`-event path (#2/#15); no menu-bar status item is added. While hidden, the bare-executable Untitled backstop in `AppDelegate.applicationDidBecomeActive` is suppressed so activating a windowless app from the app switcher does not resurrect a window (owner decisions, #32). **[Implemented #39]** When the last document window closes while the app is frontmost and no other window remains on screen, the app drops off the front entirely instead of lingering as an active-but-invisible accessory: `DockPresenceController` hides it (`NSApp.hide(nil)` right after the `.accessory` policy change), which makes macOS re-activate the previously active app — e.g. the terminal that launched it. The hide is skipped while any other window remains (e.g. Settings, which does not count as a document window; the closing window's own transient children — its hover popover, a sheet — do not count either, since they are dismissed with their anchor) or the app is not the active app. The hand-off is not a one-shot on the `.regular → .accessory` transition: every window's close recomputes (not only document windows'), and the decision also fires when the policy is already `.accessory`, so a close that was vetoed by a remaining window still hands focus back once that last window itself closes instead of leaving the app active-but-invisible. The restore-to-`.regular` path unhides before activating so a reopened document window comes back on screen, and stays gated on an actual policy change so routine key/main recomputes remain focus-neutral. Rejected: `.prohibited` (removes the app switcher entry too, making it harder to reach a windowless app); an always-regular app (the status quo this issue exists to change).

### 5.14 Language Servers Window (Settings)

**[Implemented #51]** The Settings window (app menu / Cmd-,) is a language-server inventory over the same config load and locator verdict the document-open path uses. It is **resolution-state only**: it does not show or control live server processes, and the missing-LSP notification feature was removed end-to-end in favor of this surface (5.6).

- **Coverage.** One row per language in the merged registry — bundled `[[language]]`, user `[[language]]`, and autodetected catalog. Rows are sorted by display name; there is no stale-dismissal list (5.6's suppression store is gone).
- **Status.** "Server ready" with the resolved executable path (from `LanguageServerAvailability.available`), "Server not installed" with the configured `installCommand`, and "Highlighting only". Availability is re-probed on present and on Re-check; the default resolver is `LanguageServerLocator`, so the inventory cannot disagree with an open.
- **Origin.** Bundled, Your config, or Autodetected — summarized as one line in Configuration (`Origins: Bundled N · Autodetected N · Your config N`). The loader records explicit user `[[language]]` IDs in `LanguageConfigLoadResult.userConfiguredLanguageIDs` (5.2); catalog entries are identified by non-empty `binaryAlternatives`. The registry itself stays provenance-free, and the rows stay status-focused.
- **Tabs.** Native two-tab Settings pane in a unified `NSTabViewController` toolbar: **Languages** (the inventory) and **Configuration** (config path, origin summary, and the full diagnostics list). Both tabs share a bottom help/Done bar; settings apply immediately, so Done only closes the window.
- **Languages rows.** A native view-based `NSTableView` (Language / Server / trailing action columns): name + extensions, a status line, and the resolved executable path or the configured install command rendered in the system monospaced face. The trailing action column holds **Copy** (puts the resolved path or the install command on the clipboard, brief "Copied" state) and **Open Config** for a not-installed row with no `installCommand`; highlighting-only rows carry no action. A literal `lspPath` is reported in the row tooltip ("Checked path: …"); a missing row's probed binaries are in the tooltip too ("Checked for: …").
- **Missing without a command.** "No install command configured" is its own state, and the app never invents a command.
- **Diagnostics.** Loader diagnostics are surfaced in Configuration in full, including file-level failures and skipped entries that cannot attach to a row. The Languages tab shows only a count banner with a Review… action that switches tabs; a diagnostic with a matching `languageID` also puts a warning icon and tooltip on that row. The window never parses TOML itself.
- **Source of truth.** `languages.toml` only. The window never writes language config and does not layer `UserDefaults` overrides on top. "Open languages.toml" opens the file through `NSDocumentController`; when it does not exist, the window creates `~/.config/openedit` if needed and reveals it. No config file is created.
- **Refresh.** Present and Re-check reload the config and re-probe `PATH`. Documents already open keep their first-open registry snapshot (5.1), and the window says so; changes apply to the next document opened.
- **Presentation.** Programmatic AppKit, native view-based `NSTableView` on Languages, native toolbar tabs and bottom help/Done bar, system appearance only (5.8). The window remains a non-document auxiliary surface for Dock presence (5.13).

## 6. Key Decisions (rationale + rejected alternatives)

**No App Sandbox / no App Store.** LSP servers are arbitrary third-party executables (installed via npm/pip/brew, in unpredictable locations); the sandbox does not permit spawning those. Panic hit the identical wall with Nova and shipped Developer-ID-only for the same reason. Rejected: a Mac-App-Store build with only bundled/self-compiled LSPs — possible, but turns "point at whatever's installed" into "vendor and update every language server yourself," which cuts against the actual use case (working alongside whatever LSPs the user already has for their agent workflow).

**Full-document LSP sync over incremental.** Incremental sync avoids resending the whole file on every keystroke, which matters for large files in long-lived IDE sessions. This app's documents are typically single files, edited in short sessions — the complexity of correct incremental offset math isn't worth it yet. Rejected: incremental sync as the default; can be revisited per-language if a particular server or file size makes full sync noticeably slow.

**Tree-sitter direct, not via Neon.** Neon's value is async, viewport-aware highlighting for large files in a persistent IDE. This app's files are typically small-to-medium and short-lived; a direct synchronous `SwiftTreeSitter` integration is far less code. Rejected: adopting Neon up front — deferred until a real perf problem shows up, not built preemptively.

**Naive reload-on-external-change over diff/merge.** The actual usage pattern is reviewing while an agent writes, not simultaneous overlapping edits on the same lines. A silent-reload-when-clean, prompt-on-conflict model covers the common case cheaply. Rejected: a diff view or three-way merge for v1 — real engineering cost for a case that may rarely occur in practice; revisit if edits get lost.

**Surface the install command in the Languages inventory, over auto-installing the LSP.** Auto-installing (running `npm`/`pip`/`gem`/`go` on the user's behalf, or downloading and executing binaries from GitHub releases) adds real complexity — toolchain detection, quarantine/Gatekeeper handling for downloaded binaries, a versioning/update story for managed installs — for a feature whose only advantage is skipping one command the user would otherwise type once per language, ever. Showing the exact command in Settings → Languages (5.14) with a Copy action gets the same "opens a `.py` file, finds out what to do" experience with none of that machinery, and keeps the app from silently executing package-manager commands without the user having asked it to — which matters more once this is meant for other people to run, not just personal dogfooding. (The command was first delivered via a native notification; #51 removed that feature end-to-end in favor of the inventory window, 5.6.)

## 7. Open Questions

None currently outstanding for v1 — all three items from the last round (config format, LSP idle lifetime, blocking CLI mode) are resolved above. New ones will surface during implementation; add them here as they come up.

## 8. Deferred to v1.1+

Things worth remembering, not worth building now:

- Crash/error reporting (nothing in v1 — no crash reporter wired up at all yet)

## 9. Build Sequence

Each numbered item is a candidate for its own task spec (separate file), scoped small enough to have a one-sentence "done" test. Later items depend on earlier ones.

1. Bare `NSWindow` + `NSTextView` app with a line-number gutter (5.7) and native find/replace via `NSTextFinder` (5.10); `application(_:open:)` opens a file passed as a launch argument — no highlighting, no LSP
2. `openedit` CLI shell wrapper; confirm `open -na` reuses the running instance and brings existing-file windows forward
3. File watcher + reload/conflict prompt (5.3), explicit Cmd-S save only (5.11)
4. Config loader (5.2) — TOML, implement schema + bundled defaults
5. Tree-sitter highlighting keyed off the config's grammar mapping, using the GitHub theme's dynamic colors (5.4, 5.8)
6. LSP process pool with idle-linger (5.5) + full-document sync + diagnostics rendering (5.9) + hover
7. Missing-LSP detection (PATH check) (5.6); the notification on top of it was removed end-to-end in #51
8. Settings window — per-language server inventory, at minimum (5.14)
9. Codesigning + notarization CI pipeline (GitHub Actions, tag-triggered)
10. Homebrew tap (cask + `binary` stanza for the CLI shim) + DMG packaging + Sparkle with Caskroom detection
