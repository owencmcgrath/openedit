# AGENTS.md

Instructions for any coding agent working in this repository.

## Before You Start

- Read `ARCHITECTURE.md` in full before making changes. It contains the settled design decisions ([Decided]/[Default]/[Open] tags), the component contracts, and the numbered build sequence.
- Work one numbered task from the Build Sequence at a time. Don't implement functionality from a later task "while you're in there" — if you notice something a later task will need, note it in the PR description rather than building it now.
- If a task's scope is ambiguous, or touches an `[Open]` item in `ARCHITECTURE.md`, ask rather than guessing — don't quietly resolve an open design question through an implementation choice.

## Engineering Standards

- Follow the Swift API Design Guidelines (clarity at the point of use, no abbreviations, argument labels read like prose).
- Prefer native AppKit/Foundation over third-party dependencies. Every new dependency should be justified against something the architecture doc already named (SwiftTreeSitter, Sparkle, etc.) — don't introduce an unlisted library without flagging it first.
- Match the project's existing bias toward simplicity over premature optimization (see the "Tree-sitter direct, not via Neon" and "Full-document LSP sync" decisions in `ARCHITECTURE.md` — that's the calibration to use elsewhere too: build the simple version first, revisit only if a real problem shows up).
- Keep the component boundaries from the architecture doc's Component Map intact — e.g. the highlighter shouldn't reach into the LSP client's state, the file watcher shouldn't know about tree-sitter. If a change seems to require crossing a boundary, that's worth flagging rather than just doing it.
- Comment on *why*, not *what* — the code should say what it does; comments are for decisions that aren't obvious from the code itself (and ideally point back to the relevant `ARCHITECTURE.md` section instead of re-explaining the reasoning inline).
- Small, focused commits over large ones. A commit should do one thing.
- Every change that can be built and run should be verified (build succeeds, app launches, the specific behavior being added actually works) before being committed — don't hand off broken intermediate states.

## Git Workflow

**Never commit directly to `main`.** `main` only ever receives merges from `v1.0.0` at an actual release cut — nothing else lands there directly, agent or human.

- All work happens on a branch off `v1.0.0`, merged back into `v1.0.0` via PR. `v1.0.0` is the integration branch; `main` reflects only what's actually been shipped.
- Branch naming mirrors Conventional Commit types: `<type>/<short-kebab-description>`, e.g. `feature/line-number-gutter`, `fix/notification-permission-crash`, `chore/update-tree-sitter-swift`.
  - Types: `feature`, `fix`, `chore`, `refactor`, `docs`, `test`, `perf`, `ci`, `build`
  - Keep the description short and specific — prefer `feature/lsp-idle-linger-timeout` over `feature/lsp-stuff`
  - When a branch corresponds to a numbered Build Sequence task, it's fine (encouraged, even) to reference it: `feature/02-cli-shell-wrapper`
- Open a PR from the feature/fix branch **into `v1.0.0`**, never into `main`. Rebase or merge `v1.0.0` into your branch to resolve conflicts before requesting merge, don't force-push over shared history.
- Squash-merge PRs into `v1.0.0` with a Conventional Commit message summarizing the whole change (see below) — keep `v1.0.0`'s history readable even if the branch itself had messy WIP commits.

## Conventional Commits

Every commit message (and PR title, since it becomes the squash-merge commit message) follows:

```
<type>(<optional scope>): <short summary, imperative mood, no trailing period>

<optional body — the "why," wrapped at ~72 chars>

<optional footer(s) — e.g. BREAKING CHANGE: ..., Refs: #12>
```

- Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`
- Use `feat`/`fix` only for changes that affect the app's actual behavior — internal refactors, dependency bumps, and CI tweaks use the other types even if they touch a lot of code
- A breaking change gets a `!` after the type/scope (`feat(config)!: ...`) and a `BREAKING CHANGE:` footer explaining what breaks and why
- Scope is optional but useful here given the component map — e.g. `feat(highlighter): ...`, `fix(lsp): ...`, `feat(gutter): ...`

Examples:

```
feat(gutter): add line-number ruler view

Implements the NSRulerView-based gutter per ARCHITECTURE.md Section 5.7.
Tracks line-fragment geometry automatically on scroll/wrap.
```

```
fix(watcher): debounce rapid external file changes

Multiple FSEvents callbacks were firing for a single save, triggering
the reload prompt more than once.
```

## PR Checklist

Before opening a PR against `v1.0.0`:

- [ ] Branch is named `<type>/<description>` per the convention above
- [ ] Commit message(s) follow Conventional Commits
- [ ] Builds and runs; the specific behavior in scope has been manually verified
- [ ] Nothing from a later Build Sequence task snuck in
- [ ] Any `[Open]` question in `ARCHITECTURE.md` that this work touches has been resolved (and the doc updated) or explicitly flagged in the PR description, not silently decided in code
