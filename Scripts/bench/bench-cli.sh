#!/usr/bin/env bash
# bench-cli.sh — terminal-editor file-open benchmark (issue #38).
#
# Drives each installed terminal editor through the TTY harness in
# ttybench.swift: spawn on a fresh pty, stamp the moment the benchmark file's
# first bytes are painted, quit. Two metrics per editor:
#
#   tty    — time-to-first-paint (comparable with the GUI table's
#            time-to-interactive-window)
#   quit   — hyperfine open-and-quit (the issue's proposed CLI metric;
#            measures open+parse+teardown, not first paint)
#
# Results append to Scripts/bench/results/cli.tsv as
#   editor  variant  lines  mode  median_s  p90_s  min_s  max_s  ok  failed
#
# Usage: bench-cli.sh [--variant fixed|mixed|minified] [--sizes 100,1000,...]
#                     [--editors vim,nvim,...] [--runs N] [--mode tty|quit|both]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BENCH="$ROOT/Scripts/bench"
CORPUS="$BENCH/corpus"
RESULTS="$BENCH/results"
TOOLCACHE="${TMPDIR:-/tmp}/openedit-bench-tools"
mkdir -p "$RESULTS" "$TOOLCACHE"

VARIANT="fixed"
SIZES="100,1000,10000,100000,1000000"
EDITORS="vim,nvim,kak,micro,emacs"
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

# Compile the harness once per invocation cache.
if [[ ! -x "$TOOLCACHE/ttybench" || "$BENCH/ttybench.swift" -nt "$TOOLCACHE/ttybench" ]]; then
    swiftc -O "$BENCH/ttybench.swift" -o "$TOOLCACHE/ttybench"
fi

# runs scale with file size: big files are slow, and the variance across runs
# is small once the OS page cache is warm.
runs_for_size() {
    local lines=$1
    if [[ -n "$RUNS" ]]; then echo "$RUNS"; return; fi
    if (( lines >= 1000000 )); then echo 3
    elif (( lines >= 100000 )); then echo 5
    else echo 10; fi
}

timeout_for_size() {
    local lines=$1
    if (( lines >= 1000000 )); then echo 180
    elif (( lines >= 100000 )); then echo 90
    else echo 30; fi
}

record() { # editor variant lines mode median p90 min max ok failed
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$RESULTS/cli.tsv"
    printf '  %-8s %-9s %-8s %-6s median=%ss p90=%ss\n' "$1" "$2" "$3" "$4" "$5" "$6"
}

# Per-editor launch command (file path appended), quit keystrokes, and a
# comma-separated options list:
#   ctty   — wrap in /usr/bin/script so the editor gets a controlling terminal
#            (kakoune and micro's tcell open /dev/tty; emacs too)
#   init=… — one-shot keystrokes sent ~400ms after spawn (first-run prompts)
#   env=…  — child environment entry VAR=VALUE, %RUN% substituted per run, so
#            editors that write session state (micro) get a pristine config
# Quit sequences use ttybench escapes: \e ESC, \r CR, \xHH hex, "\;" 60ms pause.
editor_spec() {
    case "$1" in
        vim)   echo "/usr/bin/vim|--clean|\e\;:q\r|ctty|" ;;
        nvim)  echo "/opt/homebrew/bin/nvim|--clean|\e\;:qa\r|ctty|" ;;
        kak)   echo "/opt/homebrew/bin/kak||\e\;:q\r|ctty|" ;;
        micro) echo "/opt/homebrew/bin/micro||\x11|ctty,init=y\r,env=MICRO_CONFIG_HOME=$TOOLCACHE/micro-run%RUN%|" ;;
        emacs) echo "/opt/homebrew/bin/emacs|-nw -q --no-site-file|\x18\x03|ctty|" ;;
        *) return 1 ;;
    esac
}

IFS=',' read -r -a editor_list <<< "$EDITORS"
IFS=',' read -r -a size_list <<< "$SIZES"

for editor in "${editor_list[@]}"; do
    spec="$(editor_spec "$editor" || true)"
    if [[ -z "$spec" ]]; then echo "skip unknown editor $editor" >&2; continue; fi
    IFS='|' read -r -a parts <<< "$spec"
    bin="${parts[0]}"
    extra_flags="${parts[1]}"
    quit="${parts[2]}"
    editor_options="${parts[3]:-}"
    needs_ctty=0 init_keys="" fresh_envs=()
    IFS=',' read -r -a option_list <<< "$editor_options"
    for option in "${option_list[@]}"; do
        case "$option" in
            ctty) needs_ctty=1 ;;
            init=*) init_keys="${option#init=}" ;;
            env=*) fresh_envs+=("${option#env=}") ;;
        esac
    done
    if ! command -v "$bin" >/dev/null 2>&1 && [[ ! -x "$bin" ]]; then
        echo "skip $editor: $bin not installed" >&2
        continue
    fi

    for lines in "${size_list[@]}"; do
        file="$CORPUS/$VARIANT-${lines}lines.txt"
        [[ -e "$file" ]] || { echo "missing corpus file $file; run gen-corpus first" >&2; continue; }
        runs="$(runs_for_size "$lines")"
        timeout="$(timeout_for_size "$lines")"

        # Warm the page cache so every editor/size cell starts in the same
        # cache state (same rationale as bench-gui.sh's prewarm).
        cat "$file" > /dev/null 2>&1 || true
        sleep 0.5

        if [[ "$MODE" == "tty" || "$MODE" == "both" ]]; then
            if [[ "$needs_ctty" == 1 ]]; then
                launcher=(/usr/bin/script -q /dev/null "$bin")
            else
                launcher=("$bin")
            fi
            fresh_env_args=()
            for entry in "${fresh_envs[@]+"${fresh_envs[@]}"}"; do
                fresh_env_args+=(--fresh-env "$entry")
            done
            # shellcheck disable=SC2086
            out=$("$TOOLCACHE/ttybench" --file "$file" --runs "$runs" --timeout-sec "$timeout" \
                --quit "$quit" ${init_keys:+"--init" "$init_keys"} \
                ${fresh_env_args[@]+"${fresh_env_args[@]}"} \
                -- "${launcher[@]}" $extra_flags "$file" 2>&1) || true
            parsed=$(printf '%s\n' "$out" | awk -F= '{v[$1]=$2}END{printf "%s %s %s %s %s %s", v["median"],v["p90"],v["min"],v["max"],v["ok"],v["failed"]}')
            read -r median p90 mn mx ok failed <<< "$parsed"
            if [[ -z "$median" ]]; then
                median="DNF"; p90="DNF"; mn="DNF"; mx="DNF"; ok=0; failed="$runs"
            fi
            record "$editor" "$VARIANT" "$lines" "tty" "$median" "$p90" "$mn" "$mx" "$ok" "$failed"
        fi

        if [[ "$MODE" == "quit" || "$MODE" == "both" ]]; then
            case "$editor" in
                vim)
                    cmd="/usr/bin/vim --clean --not-a-term '$file' -c 'silent! q!'"
                    ;;
                nvim)
                    cmd="/opt/homebrew/bin/nvim --clean --headless '$file' +q"
                    ;;
                emacs)
                    cmd="/opt/homebrew/bin/emacs --batch '$file' -f kill-emacs"
                    ;;
                *)
                    continue # micro/kak have no scripted open-and-quit
                    ;;
            esac
            if command -v hyperfine >/dev/null 2>&1; then
                json="$TOOLCACHE/hyperfine.json"
                if hyperfine --warmup 2 --min-runs "$runs" --style basic \
                    --export-json "$json" "$cmd" >/dev/null 2>&1; then
                    stats=$(python3 -c 'import json,sys,math
r=json.load(open(sys.argv[1]))["results"][0]
s=r["summary"]["time_wall_clock"]
times=sorted(m["time_wall_clock"]["value"] for m in r["measurements"])
i=max(0,math.ceil(len(times)*0.9)-1)
print("%.6f %.6f %.6f %.6f" % (s["median"], times[i], s["min"], s["max"]))' "$json") || true
                    if [[ -n "$stats" ]]; then
                        read -r median p90 mn mx <<< "$stats"
                        record "$editor" "$VARIANT" "$lines" "quit" "$median" "$p90" "$mn" "$mx" "$runs" 0
                    fi
                fi
            fi
        fi
    done
done

echo "results: $RESULTS/cli.tsv"
