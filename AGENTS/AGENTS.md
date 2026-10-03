# AGENTS.md

Instructions for any coding agent working in this repository.

## Before You Start

- Read `ARCHITECTURE.md` in full before making changes. It contains the settled design decisions ([Decided]/[Default]/[Open] tags), the component contracts, and the numbered build sequence.
- Work from a GitHub **issue**, not from a chat request alone. Find the issue that covers the work, or file one first — see **Issue & Project Workflow**.
- Read the issue in full before coding. It is authoritative over the chat request: its scope, decision gates, dependencies, and acceptance criteria all bind. If the issue and the request conflict, ask — don't silently pick one.
- Work one numbered task from the Build Sequence at a time. Don't implement functionality from a later task "while you're in there" — if you notice something a later task will need, note it in the PR description rather than building it now.
- If a task's scope is ambiguous, or touches an `[Open]` item in `ARCHITECTURE.md`, ask rather than guessing — don't quietly resolve an open design question through an implementation choice.

## Issue & Project Workflow

Work is tracked as GitHub issues on `owencmcgrath/openedit`, grouped in the **openedit** project (GitHub Projects v2, owner `owencmcgrath`, project number `11`). The issue is the unit of work; a branch and a PR are the artifacts that resolve it. A chat request is not a work item by itself.

### Find or file the issue first

- Every Build Sequence task in `ARCHITECTURE.md` §9 has (or should have) an issue. Before starting, locate it: `gh issue list` / `gh issue view <n>`.
- If no issue covers the requested work, **open one** using the issue spec below, assign yourself, apply the type label, add it to the project, and confirm scope with the owner before coding — don't code first and back-fill an issue.
- Honor the issue's `### Decision gate` and `### Dependencies` sections. Stop and ask before coding when a gate is unresolved; don't start work a dependency hasn't unblocked.

### Issue spec (use this shape)

Issues serve two audiences — a human summary and an agent-executable spec. Keep that structure:

```markdown
## Human summary

<plain-language paragraph: the user-visible outcome>

## Agent description

**Status:** <open — not started | in progress — branch <name> | in review — PR #<n> | shipped — PR #<n> merged to release/v1.0.0 | blocked — see Dependencies>

### What exists today

- <current behavior, with `path:line` references>
- Source of truth: `AGENTS/ARCHITECTURE.md` §<section>

### Objective

<what "done" means, in one or two sentences>

### Decisions (settled with owner — do not relitigate)

<only when a prior gate resolved; otherwise omit>

### Implementation boundary

- <files/components in scope; what is explicitly out>

### Decision gate — STOP and ask before coding

<unresolved design questions needing the owner's call; omit if none>

### Agent rules

- <how to build/test this safely; boundaries not to cross>

### Acceptance criteria

- [ ] <verifiable outcomes>

### Dependencies

<`#N` references; what must land first>

### Notes

<optional>
```

- Keep the `**Status:**` line current as you work. It is the issue's logbook and the first thing the next agent reads.
- `What exists today` uses `path:line` pointers so the next agent doesn't re-derive the codebase.
- Every decision the owner makes at a gate gets recorded in `AGENTS/ARCHITECTURE.md` and referenced from the issue — not only in a PR comment.

### Project status lifecycle

The openedit project's `Status` field (single-select) is the board. Move the issue as work progresses; never leave a stale card:

| Status | When |
|---|---|
| `Triage` | Filed; scope or decision gates not yet settled |
| `Ready` | Scope settled, gates resolved, dependencies merged — safe to start |
| `In Progress` | Branch created, work underway |
| `Testing` | PR opened; verification in progress |
| `Done` | PR merged into `release/v1.0.0` (or closed as not-planned) |

Set the status to match reality at the end of every work turn. Never mark `Done` for unmerged work.

### Labels

The repo's labels are exactly the Conventional Commit types (`feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`). Apply the label matching the change type to **both** the issue and its PR. There is no separate severity/area scheme — don't invent labels; ask the owner before adding one.

### Blockers & dependencies

- Express ordering with explicit cross-references in the issue: `Depends on #N`, `Blocked by #N`, `Blocks #M`. The `### Dependencies` section is authoritative.
- A blocked issue stays in `Triage`/`Ready`; add a comment naming the blocking issue and the reason. Don't start blocked work.
- When a blocker merges, comment on the blocked issue and move it to `Ready`.
- Hierarchical work (a task with sub-tasks) uses GitHub's native parent/sub-issue links, which the project surfaces as `Parent issue` / `Sub-issues progress` — use them instead of duplicating the relationship in prose.

### Branch ↔ issue

- Branch names carry the issue number: `<type>/<issue-number>-<short-kebab-description>`, e.g. `feature/25-document-type-icons`, `fix/12-notification-permission-crash`. (Branches predating this convention don't; follow it going forward.)
- Branch base is always `release/v1.0.0` (see Git Workflow).

### Common commands

```sh
gh issue view <n>                                   # read the authoritative spec
gh issue create --label feat --assignee @me \
  --title "..." --body-file /tmp/issue.md           # file a missing issue
gh project item-add 11 --owner owencmcgrath \
  --url https://github.com/owencmcgrath/openedit/issues/<n>   # add to the board
gh pr create --base release/v1.0.0 --head <branch> \
  --draft --title "..." --body-file /tmp/pr.md      # open a draft PR
```

Project status edits are easiest in the project UI; scripting them (`gh project item-edit`) needs the item and field IDs from `gh project item-list 11 --owner owencmcgrath --format json`.

## Engineering Standards

- Follow the Swift API Design Guidelines (clarity at the point of use, no abbreviations, argument labels read like prose).
- Prefer native AppKit/Foundation over third-party dependencies. Every new dependency should be justified against something the architecture doc already named (SwiftTreeSitter, Sparkle, etc.) — don't introduce an unlisted library without flagging it first.
- Match the project's existing bias toward simplicity over premature optimization (see the "Tree-sitter direct, not via Neon" and "Full-document LSP sync" decisions in `ARCHITECTURE.md` — that's the calibration to use elsewhere too: build the simple version first, revisit only if a real problem shows up).
- Keep the component boundaries from the architecture doc's Component Map intact — e.g. the highlighter shouldn't reach into the LSP client's state, the file watcher shouldn't know about tree-sitter. If a change seems to require crossing a boundary, that's worth flagging rather than just doing it.
- Comment on *why*, not *what* — the code should say what it does; comments are for decisions that aren't obvious from the code itself (and ideally point back to the relevant `ARCHITECTURE.md` section instead of re-explaining the reasoning inline).
- Small, focused commits over large ones. A commit should do one thing.
- Every change that can be built and run should be verified (build succeeds, app launches, the specific behavior being added actually works) before being committed — don't hand off broken intermediate states.

## Git Workflow

**Never commit directly to `main`.** `main` only ever receives merges from `release/v1.0.0` at an actual release cut — nothing else lands there directly, agent or human.

- All work happens on a branch off `release/v1.0.0`, merged back into `release/v1.0.0` via PR. `release/v1.0.0` is the integration branch; `main` reflects only what's actually been shipped.
- Branch naming mirrors Conventional Commit types and carries the issue number: `<type>/<issue-number>-<short-kebab-description>`, e.g. `feature/25-document-type-icons`, `fix/12-notification-permission-crash`, `chore/31-update-tree-sitter-swift`.
  - Types: `feature`, `fix`, `chore`, `refactor`, `docs`, `test`, `perf`, `ci`, `build`
  - Keep the description short and specific — prefer `feature/23-lsp-autodetection` over `feature/lsp-stuff`
  - When a branch corresponds to a numbered Build Sequence task, it's fine (encouraged, even) to reference it: `feature/02-cli-shell-wrapper`
- Open a PR from the feature/fix branch **into `release/v1.0.0`**, never into `main`. Rebase or merge `release/v1.0.0` into your branch to resolve conflicts before requesting merge, don't force-push over shared history.
- Squash-merge PRs into `release/v1.0.0` with a Conventional Commit message summarizing the whole change (see below) — keep `release/v1.0.0`'s history readable even if the branch itself had messy WIP commits.

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

## PR ↔ Issue & Project

A PR exists to resolve an issue; link them explicitly.

- PR title is the Conventional Commit summary; PR base is `release/v1.0.0`.
- Link issues in the PR body: `Closes #N` when merging resolves it, `Refs #N` otherwise. One `Closes` per resolved issue. (GitHub surfaces these as the project's `Linked pull requests`.)
- Open the PR as a **draft** while verification is incomplete, and mark it ready when the PR Checklist below passes. Draft PRs are the default for agent work.
- Mirror the issue's `### Acceptance criteria` in the PR body as a checklist: mark each passed item and state how it was verified (command or manual step). Call out anything not verified and why.
- Move the issue's project status to `Testing` when the PR opens, and to `Done` when it merges. Update the issue's `**Status:**` line to `shipped — PR #N` at merge time.
- If the PR intentionally resolves only part of the issue, say so in both the PR body and an issue comment, and leave the issue open with its remaining acceptance criteria.

## Tags & Releases

- `main` is release-only: it receives merges from `release/v1.0.0` at a release cut and nothing else. A release cut tags the shipped commit `vX.Y.Z` (tag-triggered codesign/notarize/release CI is `ARCHITECTURE.md` §9 task 9).
- Agents do **not** create tags, publish releases, or push to `main` unless the release task explicitly instructs it.
- Reference the shipped version in issues/PRs when behavior depends on it (`Fixed in v1.0.0`, `since v1.0.0`). Don't invent version numbers — use the next `release/v1.0.0` cut.

## PR Checklist

Before opening a PR against `release/v1.0.0`:

- [ ] The issue exists, is assigned, and its decision gates and dependencies are resolved (or the blocked state is documented)
- [ ] Branch is named `<type>/<issue-number>-<description>` per the convention above
- [ ] Commit message(s) follow Conventional Commits
- [ ] PR body links the issue (`Closes #N` / `Refs #N`) and applies the matching type label
- [ ] Builds and runs; the specific behavior in scope has been manually verified, with the issue's acceptance criteria mirrored and checked off in the PR body
- [ ] Project status set to `Testing`; issue `**Status:**` line updated
- [ ] Nothing from a later Build Sequence task snuck in
- [ ] Any `[Open]` question in `ARCHITECTURE.md` that this work touches has been resolved (and the doc updated) or explicitly flagged in the PR description, not silently decided in code
