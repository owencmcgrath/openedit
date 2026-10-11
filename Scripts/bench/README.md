# OpenEdit file-open benchmark (issue #38)

Reproducible methodology + results for OpenEdit's file-opening performance
against other editors. Everything here runs locally with no external services.

## Layout

| Path | Purpose |
|---|---|
| `gen-corpus.swift` | Deterministic corpus generator (SplitMix64-seeded) |
| `ttybench.swift` | Terminal-editor harness: time-to-first-paint on a fresh pty |
| `guibench.swift` | GUI-editor harness: time-to-interactive window via Accessibility |
| `axpress.swift` | Dismisses first-run modal dialogs (BBEdit license, etc.) |
| `bench-cli.sh` | Drives the terminal editors, appends `results/cli.tsv` |
| `bench-gui.sh` | Drives the GUI editors, appends `results/gui.tsv` |
| `corpus/` | Generated corpus (gitignored; regenerate with the command below) |
| `results/` | Raw TSV results (checked in with each report) |

## Methodology

### Corpus

```
swift Scripts/bench/gen-corpus.swift Scripts/bench/corpus 100,1000,10000,100000,1000000 38
```

Three variants per size, byte-identical across editors:

- **fixed** — every line exactly 80 printable alphanumeric chars (`\n`-terminated). The primary matrix file, `.txt`, so no editor gets an unrepresentative syntax load.
- **mixed** — seeded line lengths 5–300 chars, wrap-prone.
- **minified** — the entire document on one line (a wrap/long-line stress case).

`.py` copies of every file let OpenEdit-only runs exercise the tree-sitter
highlighting path (grammar choice differs per editor, so they are reported
separately, not in the cross-editor table).

### Terminal editors (vim, nvim, kak, micro, emacs -nw)

Two metrics per editor/size:

- **tty** — `ttybench` spawns the editor on a fresh pty (132×40, TERM=xterm-256color), watches the pty stream, and stamps the moment the file's first 24 bytes are painted (matched after stripping ANSI sequences, so escape codes interleaved with content cannot break the match). Quit keystrokes then close the editor. This is "time to first content paint" — the same notion the GUI harness measures.
- **quit** — the issue's proposed open-and-quit metric via `hyperfine` (`vim --clean --not-a-term file -c q`, `nvim --headless +q`, `emacs --batch -f kill-emacs`). This includes process spawn + teardown and excludes painting.

Repetitions scale with size (10 runs ≤10k lines, 5 at 100k, 3 at 1M); median
and p90 are reported.

### GUI editors (OpenEdit, TextEdit, VS Code, Zed, Sublime, CodeEdit, Nova, BBEdit)

- **cold** — the app is quit (terminate, escalating to SIGKILL), then launched fresh with the file; the sample is the delta from just before `open -a …` to the moment an Accessibility query reports a window whose title contains the benchmark file's name (extension-stripped, since NSDocument-style titles hide extensions).
- **warm** — the app stays running with a small decoy file; between runs the decoy is re-focused (title moves off the target), then the target opens and the title switch is timed.

Corpus copies carry a `-runK` suffix (one per repetition) so editors that restore prior-session files (Zed, Sublime) cannot fake a match with a stale title.

VS Code runs in an isolated profile (`--user-data-dir`), no extensions, no workspace-trust dialog, no large-file confirmation (`workbench.editorLargeFileConfirmation: 4096`), no window restore, no startup editor.

### Environment (this report's runs)

- macOS 27.0.1 (26A434), Apple M4 Pro (12 cores), 24 GB RAM
- Editors: vim 9.1 (/usr/bin), Neovim, Kakoune, micro, emacs (Homebrew), Zed 1.23.2, Sublime Text 4, CodeEdit 0.3.6, Nova 14.1, BBEdit 16.0.3, VS Code (current), TextEdit (system), OpenEdit (this branch, release build)
- OS page cache warm for corpus files after the first run (no `purge`; noted as a caveat — cold *disk* reads are not what is measured, cold *process* opens are)
- Editor extensions/plugins disabled or first-run dialogs dismissed where possible (`axpress` handles license dialogs)
- Benchmarks run serially; no compilation or other CPU work during timed runs

## Running it

```sh
# 1. corpus
swift Scripts/bench/gen-corpus.swift Scripts/bench/corpus 100,1000,10000,100000,1000000 38

# 2. terminal editors (tty + open-and-quit)
Scripts/bench/bench-cli.sh --variant fixed --mode both

# 3. GUI editors
Scripts/bench/bench-gui.sh --variant fixed --mode both

# 4. OpenEdit highlighting path (OpenEdit-only, .py corpus)
Scripts/bench/bench-gui.sh --editors openedit --variant fixed --sizes 1000000 --mode warm
```

`guibench` also accepts `OPENEDIT_BENCH_MARKER=<path>`: when set, OpenEdit
appends `<firstPaintWallMS>\t<readMS>\t<setTextMS>\t<highlightMS>\t<path>` on
each first paint, giving the app's own account of its open pipeline
(os_signpost spans `com.openedit.app/category=open` cover the same path for
Instruments).

## Results

See `results/README.md` for the generated tables and the analysis for the
current report. Regenerate with the commands above; the environment section
must be updated whenever the machine or editor versions change.
