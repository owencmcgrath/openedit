#!/usr/bin/env bash
# bench-gui.sh — GUI-editor file-open benchmark (issue #38).
#
# For each installed GUI editor, runs guibench.swift (AX window-title poll):
#   cold — quit the app, launch fresh, open the file, time to visible window
#   warm — app already running; open a never-before-opened copy, time to the
#          window title switching to it
#
# Corpus copies carry a -runK suffix (one per repetition) so editors that
# restore previous-session files (Zed, Sublime) cannot fake a match.
#
# Results append to Scripts/bench/results/gui.tsv as
#   editor variant lines mode median_s p90_s min_s max_s ok failed
#
# Usage: bench-gui.sh [--variant fixed|mixed|minified] [--sizes 100,...]
#                     [--editors openedit,textedit,...] [--runs N]
#                     [--mode cold|warm|both]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BENCH="$ROOT/Scripts/bench"
CORPUS="$BENCH/corpus"
RESULTS="$BENCH/results"
TOOLCACHE="${TMPDIR:-/tmp}/openedit-bench-tools"
DOWNLOADS="${TMPDIR:-/tmp}/openedit-bench-downloads"
mkdir -p "$RESULTS" "$TOOLCACHE" "$DOWNLOADS"

VARIANT="fixed"
SIZES="100,1000,10000,100000,1000000"
EDITORS="openedit,textedit,vscode,zed,sublime,codeedit,nova,bbedit"
MODE="both"
RUNS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant) VARIANT="$2"; shift 2 ;;
        --sizes) SIZES="$2"; shift 2 ;;
        --editors) EDITORS="$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        --runs) RUNS="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ ! -x "$TOOLCACHE/guibench" || "$BENCH/guibench.swift" -nt "$TOOLCACHE/guibench" ]]; then
    swiftc -O "$BENCH/guibench.swift" -o "$TOOLCACHE/guibench"
fi
AXPRESS="$TOOLCACHE/axpress"
if [[ ! -x "$AXPRESS" || "$BENCH/axpress.swift" -nt "$AXPRESS" ]]; then
    swiftc -O "$BENCH/axpress.swift" -o "$AXPRESS" || true
fi

DECOY="$CORPUS/decoy.txt"
[[ -e "$DECOY" ]] || printf 'OpenEdit benchmark decoy file - unique title token.\n' > "$DECOY"

# runs scale down for giant files.
runs_for_size() {
    local lines=$1
    if [[ -n "$RUNS" ]]; then echo "$RUNS"; return; fi
    if (( lines >= 1000000 )); then echo 3
    elif (( lines >= 100000 )); then echo 4
    else echo 5; fi
}
timeout_for_size() {
    local lines=$1
    if (( lines >= 1000000 )); then echo 300
    elif (( lines >= 100000 )); then echo 120
    else echo 60; fi
}

record() { # editor variant lines mode median p90 min max ok failed
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$RESULTS/gui.tsv"
    printf '  %-9s %-9s %-8s %-5s median=%ss p90=%ss\n' "$1" "$2" "$3" "$4" "$5" "$6"
}

# ---- VS Code benchmark profile: no extensions, no trust dialog, no large-file
# confirmation, no window restore, no welcome tab. Isolated user-data-dir.
VSCODE_BIN="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
VSCODE_PROFILE="${TMPDIR:-/tmp}/openedit-vscode-bench-profile"
prepare_vscode() {
    [[ -x "$VSCODE_BIN" ]] || return 1
    mkdir -p "$VSCODE_PROFILE/User"
    cat > "$VSCODE_PROFILE/User/settings.json" <<'JSON'
{
  "window.restoreWindows": "none",
  "workbench.startupEditor": "none",
  "security.workspace.trust.enabled": false,
  "workbench.editorLargeFileConfirmation": 4096,
  "update.mode": "none",
  "telemetry.telemetryLevel": "off",
  "extensions.autoCheckUpdates": false,
  "files.autoSave": "off"
}
JSON
}
vscode_open() { # %FILE%
    echo "$VSCODE_BIN --user-data-dir '$VSCODE_PROFILE' --disable-extensions %FILE%"
}

# Editor registry: NAME|bundle-id|open-command-template|prepare
# %FILE% is replaced per invocation; command runs via /bin/sh.
editor_spec() {
    case "$1" in
        openedit) echo "com.openedit.app|open -a '$ROOT/build/OpenEdit.app' %FILE%|" ;;
        textedit) echo "com.apple.TextEdit|open -a TextEdit %FILE%|" ;;
        vscode)   echo "com.microsoft.VSCode|$(vscode_open)|prepare_vscode" ;;
        zed)      echo "dev.zed.Zed|open -a '$HOME/Applications/Zed.app' %FILE%|" ;;
        sublime)  echo "com.sublimetext.4|open -a '$HOME/Applications/Sublime Text.app' %FILE%|" ;;
        codeedit) echo "com.codeeditapp.CodeEdit|open -a '$HOME/Applications/CodeEdit.app' %FILE%|" ;;
        nova)     echo "com.panic.Nova|open -a Nova %FILE%|" ;;
        bbedit)   echo "com.barebones.bbedit|open -a BBEdit %FILE%|" ;;
        *) return 1 ;;
    esac
}

IFS=',' read -r -a editor_list <<< "$EDITORS"
IFS=',' read -r -a size_list <<< "$SIZES"

for editor in "${editor_list[@]}"; do
    spec="$(editor_spec "$editor" || true)"
    if [[ -z "$spec" ]]; then echo "skip unknown editor $editor" >&2; continue; fi
    IFS='|' read -r -a parts <<< "$spec"
    bundle="${parts[0]}"
    template="${parts[1]}"
    prepare="${parts[2]:-}"
    # App present? resolve the path inside the template crudely: substitute
    # $HOME/$ROOT, then check `open -a` targets. Simplest presence check:
    # bundle-id lookup after a launch attempt is deferred to guibench; here we
    # only skip when a named app directory does not exist.
    app_dir=$(printf '%s' "$template" | grep -oE "/[^' ]+\.app" | head -1 || true)
    if [[ -n "$app_dir" && ! -d "$app_dir" ]]; then
        echo "skip $editor: $app_dir not installed" >&2
        continue
    fi
    [[ -n "$prepare" ]] && $prepare

    # First-run dialogs (license agreements, welcome screens) block automated
    # opens: launch once with a scratch file, press through any modal with
    # axpress, then quit so the measured runs start clean.
    if [[ -x "$AXPRESS" && "$editor" != "openedit" ]]; then
        printf 'OpenEdit benchmark first-run dismissal file.\n' > "$CORPUS/firstrun.txt"
        sh -c "${template/\%FILE\%/$CORPUS/firstrun.txt}" >/dev/null 2>&1 || true
        "$AXPRESS" --bundle-id "$bundle" --seconds 12 >/dev/null 2>&1 || true
        osascript -e "quit app id \"$bundle\"" >/dev/null 2>&1 || true
        sleep 2
    fi

    for lines in "${size_list[@]}"; do
        runs="$(runs_for_size "$lines")"
        timeout="$(timeout_for_size "$lines")"

        # Per-run corpus copies with unique suffixes.
        copies=()
        for k in $(seq 1 "$runs"); do
            src="$CORPUS/$VARIANT-${lines}lines.txt"
            dst="$CORPUS/$VARIANT-${lines}lines-run$k.txt"
            [[ -e "$dst" ]] || cp "$src" "$dst"
            copies+=("$dst")
        done
        file_template="$CORPUS/$VARIANT-${lines}lines-run%RUN%.txt"

        for mode in cold warm; do
            [[ "$MODE" == "both" || "$MODE" == "$mode" ]] || continue
            extra=()
            [[ "$mode" == "warm" ]] && extra=(--decoy "$DECOY")
            out=$("$TOOLCACHE/guibench" \
                --file "$file_template" \
                --mode "$mode" --runs "$runs" --timeout-sec "$timeout" \
                --bundle-id "$bundle" ${extra[@]+"${extra[@]}"} \
                -- "$(printf '%s' "$template")" 2>&1) || true
            parsed=$(printf '%s\n' "$out" | awk -F= '{v[$1]=$2}END{printf "%s %s %s %s %s %s", v["median"],v["p90"],v["min"],v["max"],v["ok"],v["failed"]}')
            read -r median p90 mn mx ok failed <<< "$parsed"
            failed=$(( runs - ${ok:-0} ))
            if [[ -z "$median" ]]; then
                printf '%s\n' "$out" | head -3 >&2
                median="DNF"; p90="DNF"; mn="DNF"; mx="DNF"; ok=0
            fi
            record "$editor" "$VARIANT" "$lines" "$mode" "$median" "$p90" "$mn" "$mx" "$ok" "$failed"
        done
    done
done

echo "results: $RESULTS/gui.tsv"
