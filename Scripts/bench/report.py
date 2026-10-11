#!/usr/bin/env python3
"""report.py — render Scripts/bench/results/*.tsv into markdown tables.

Inputs (written by bench-cli.sh / bench-gui.sh, columns tab-separated):
  cli.tsv: editor variant lines mode median p90 min max ok failed
  gui.tsv: editor variant lines mode median p90 min max ok failed

Output: markdown with, per variant:
  - terminal editors (tty metric)
  - terminal editors (open-and-quit metric)
  - GUI editors (cold / warm)
plus a per-size winner summary across all measured editors on the tty/GUI
"first paint" metrics.

Usage: report.py [results-dir] [--variant fixed] [--stdout | --out FILE]
"""

import argparse
import pathlib
import sys

def load(path: pathlib.Path, variant: str):
    rows = []
    if not path.exists():
        return rows
    for line in path.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) != 10:
            continue
        editor, var, lines, mode, median, p90, mn, mx, ok, failed = parts
        if var != variant:
            continue
        rows.append({
            "editor": editor, "lines": int(lines), "mode": mode,
            "median": float(median) if median not in ("DNF", "") else None,
            "p90": float(p90) if p90 not in ("DNF", "") else None,
            "min": float(mn) if mn not in ("DNF", "") else None,
            "max": float(mx) if mx not in ("DNF", "") else None,
            "ok": int(ok or 0), "failed": int(failed or 0),
        })
    return rows

def fmt(seconds):
    if seconds is None:
        return "DNF"
    return f"{seconds*1000:.0f} ms" if seconds < 10 else f"{seconds:.2f} s"

def table(rows, sizes, title, metric_editors=None):
    """rows for one mode; one column per size; one row per editor."""
    editors = sorted({r["editor"] for r in rows})
    out = [f"### {title}", "", "| editor | " + " | ".join(f"{s:,} lines" for s in sizes) + " |",
           "|---|" + "---|" * len(sizes)]
    for editor in editors:
        cells = []
        for size in sizes:
            match = [r for r in rows if r["editor"] == editor and r["lines"] == size]
            cells.append(fmt(match[0]["median"]) if match else "—")
        out.append(f"| {editor} | " + " | ".join(cells) + " |")
    out.append("")
    return "\n".join(out)

def winner_table(cli_rows, gui_rows, sizes, variant):
    """First-paint comparison: CLI tty medians vs GUI cold/warm medians."""
    paint = [r for r in cli_rows if r["mode"] == "tty"] + gui_rows
    out = ["### Winner per size (time to first paint / interactive window)", "",
           "| lines | fastest | median | runner-up | median | OpenEdit | median |", "|---|---|---|---|---|---|---|"]
    for size in sizes:
        cell = [r for r in paint if r["lines"] == size and r["median"] is not None]
        if not cell:
            out.append(f"| {size:,} | — | — | — | — | — | — |")
            continue
        ranked = sorted(cell, key=lambda r: r["median"])
        def entry(r):
            return f"{r['editor']}", fmt(r["median"])
        w = entry(ranked[0])
        second = entry(ranked[1]) if len(ranked) > 1 else ("—", "—")
        oe = [r for r in ranked if r["editor"] == "openedit"]
        out.append("| {:,} | {} | {} | {} | {} | {} | {} |".format(
            size, w[0], w[1], second[0], second[1],
            oe[0]["editor"] if oe else "—",
            fmt(oe[0]["median"]) if oe else "—"))
    out.append("")
    return "\n".join(out)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results", nargs="?", default=None)
    ap.add_argument("--variant", default="fixed")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    results = pathlib.Path(args.results) if args.results else pathlib.Path(__file__).parent / "results"

    cli = load(results / "cli.tsv", args.variant)
    gui = load(results / "gui.tsv", args.variant)
    sizes = sorted({r["lines"] for r in cli + gui})
    if not sizes:
        sys.exit("no results found")

    parts = [f"# Results — variant `{args.variant}`", "",
             "Times are medians; `DNF` = did not finish within the timeout.", ""]
    if cli:
        parts.append("## Terminal editors")
        parts.append("")
        tty = [r for r in cli if r["mode"] == "tty"]
        quit_ = [r for r in cli if r["mode"] == "quit"]
        if tty:
            parts.append(table(tty, sizes, "Time to first content paint (tty metric)"))
        if quit_:
            parts.append(table(quit_, sizes, "Open and quit (hyperfine; includes process spawn + teardown)"))
    if gui:
        parts.append("## GUI editors")
        parts.append("")
        for mode, label in (("cold", "Cold start (fresh process)"), ("warm", "Warm open (running instance)")):
            rows = [r for r in gui if r["mode"] == mode]
            if rows:
                parts.append(table(rows, sizes, label))
    parts.append(winner_table(cli, gui, sizes, args.variant))
    text = "\n".join(parts)

    if args.out:
        pathlib.Path(args.out).write_text(text)
        print(f"wrote {args.out}")
    else:
        print(text)

if __name__ == "__main__":
    main()
