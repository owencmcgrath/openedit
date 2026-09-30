# Tree-sitter grammars

Provenance for the grammars compiled into OpenEdit for syntax highlighting
(ARCHITECTURE.md 5.4, 5.8). The set matches `BundledLanguages` in
`Sources/OpenEditConfig/BundledLanguages.swift`; the config's `grammar` field is
the key looked up in `GrammarRegistry`.

| Language | Package product | Source | Pinned version | License |
|---|---|---|---|---|
| Python | `TreeSitterPython` | https://github.com/tree-sitter/tree-sitter-python | `0.23.6` | MIT |
| JSON | `TreeSitterJSON` | https://github.com/tree-sitter/tree-sitter-json | `0.24.8` | MIT |
| Markdown | `TreeSitterMarkdown` | https://github.com/tree-sitter-grammars/tree-sitter-markdown | `0.5.3` | MIT |
| TOML | `TreeSitterTOML` | https://github.com/tree-sitter-grammars/tree-sitter-toml | `0.7.0` | MIT |
| YAML | `TreeSitterYAML` | https://github.com/tree-sitter-grammars/tree-sitter-yaml | `0.7.0` | MIT |

The Swift binding is [`tree-sitter/swift-tree-sitter`](https://github.com/tree-sitter/swift-tree-sitter)
(`SwiftTreeSitter`, pinned `from: 0.25.0`, BSD-3-Clause); it brings in the
tree-sitter C runtime (`tree-sitter/tree-sitter`, MIT) transitively. Grammars
are parser projects that only expose their C `tree_sitter_<language>()` entry
point and their `queries/` directory (`highlights.scm`), so they do not couple
to the binding's API.

## Why the grammars are pinned with `exact:`

Each grammar package ships an external scanner in `src/scanner.c`, but recent
tags decide whether to compile it with
`FileManager.default.fileExists(atPath: "src/scanner.c")` inside `Package.swift`.
That relative-path check is false when SwiftPM evaluates the manifest as a
*dependency* (the manifest's working directory is not the package root), so the
scanner is silently dropped and the link fails on the missing
`tree_sitter_<language>_external_scanner_*` symbols. The pinned tags are the
newest releases whose manifests list `src/scanner.c` unconditionally. Bump them
deliberately and re-verify the build, not with a floating range.

## How the query resources reach OpenEdit.app

SwiftPM emits one resource bundle per grammar target
(`TreeSitterPython_TreeSitterPython.bundle`, …, containing
`Contents/Resources/queries/*.scm`) next to the executable under `swift run`
and `swift test`. `Scripts/build-app.sh` copies every `*.bundle` into
`OpenEdit.app/Contents/Resources`. `GrammarRegistry.defaultQueriesDirectory`
walks the executable's, `Bundle.main`'s, and `Bundle(for:)`'s ancestors so the
same lookup succeeds in all three launch paths, then hands the directory to
`LanguageConfiguration(language:name:queriesURL:)`.

## Evidence status

- Highlighting is exercised by `Tests/OpenEditHighlightingTests`: initial tokens
  in Python and JSON, incremental edits (single-line, multiline, delete, end of
  document, non-ASCII), and range-limited re-attribution. All five grammars
  resolve and load their highlight queries.
- The `binaryName`/`installCommand` fields in the config remain *names*, not
  verified-working claims — PATH detection is task #7, not this one.
