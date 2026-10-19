#!/usr/bin/env bash
# Unit tests for the openedit CLI shim's flag parsing and LaunchServices
# forwarding (ARCHITECTURE.md 5.1). Runs the real script with a stub `open` on
# PATH and a temp OPENEDIT_APP, then asserts the arguments the shim would hand
# to LaunchServices. No app, window server, or bundle required.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
shim="$repo_root/Scripts/openedit"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_app="$tmp/OpenEdit.app"
mkdir -p "$fake_app"

bin="$tmp/bin"
mkdir -p "$bin"
stub_args="$tmp/open-args"
cat > "$bin/open" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$OPENEDIT_STUB_ARGS"
exit 0
STUB
chmod +x "$bin/open"

export OPENEDIT_APP="$fake_app"
export OPENEDIT_STUB_ARGS="$stub_args"
export PATH="$bin:$PATH"

failures=0
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "FAIL: $label"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        failures=$((failures + 1))
    else
        echo "ok: $label"
    fi
}

RUN_STATUS=0
RUN_STDERR=""
# Run the shim with a clean stub capture; records RUN_STATUS and RUN_STDERR.
run_shim() {
    : > "$stub_args"
    RUN_STDERR="$("$shim" "$@" 2>&1 >/dev/null)"
    RUN_STATUS=$?
}

RUN_STDOUT=""
run_shim_stdout() {
    : > "$stub_args"
    RUN_STDOUT="$("$shim" "$@" 2>/dev/null)"
    RUN_STATUS=$?
}

forwarded() { cat "$stub_args"; }

a="$tmp/a.txt"
b="$tmp/b.txt"
mkdir -p "$tmp/adir"
touch "$a" "$b" "$tmp/a b.txt"

# Default: reuse the frontmost window — a plain `open -a <app> <file>`.
run_shim "$a"
assert_eq "default exit code" 0 "$RUN_STATUS"
assert_eq "default forwards file open" $'-a\n'"$fake_app"$'\n'"$a" "$(forwarded)"

# --reuse-window is the explicit form of the default.
run_shim --reuse-window "$b"
assert_eq "--reuse-window matches default" $'-a\n'"$fake_app"$'\n'"$b" "$(forwarded)"

# --new-window carries the intent as an openedit:// URL.
run_shim --new-window "$a"
assert_eq "new-window forwards scheme URL" \
    $'-a\n'"$fake_app"$'\n'"openedit://new-window?path=$a" "$(forwarded)"

# Multiple files in one --new-window call: repeated path items, order kept.
run_shim --new-window "$a" "$b"
assert_eq "new-window multiple files" \
    $'-a\n'"$fake_app"$'\n'"openedit://new-window?path=$a&path=$b" "$(forwarded)"

# Paths with spaces are percent-encoded.
run_shim --new-window "$tmp/a b.txt"
assert_eq "new-window percent-encodes spaces" \
    $'-a\n'"$fake_app"$'\n'"openedit://new-window?path=${tmp}/a%20b.txt" "$(forwarded)"

# No files: just activate/launch the app.
run_shim
assert_eq "no files forwards bare launch" $'-a\n'"$fake_app" "$(forwarded)"

# Validation is unchanged by the flags.
run_shim --new-window "$tmp/missing.txt"
assert_eq "missing file exit code" 1 "$RUN_STATUS"
assert_eq "missing file message" "openedit: no such file: $tmp/missing.txt" "$RUN_STDERR"
assert_eq "missing file does not forward" "" "$(forwarded)"

run_shim "$tmp/adir"
assert_eq "directory exit code" 1 "$RUN_STATUS"
assert_eq "directory message" "openedit: not a file: $tmp/adir" "$RUN_STDERR"
assert_eq "directory does not forward" "" "$(forwarded)"

run_shim --bogus "$a"
assert_eq "unsupported option exit code" 2 "$RUN_STATUS"
assert_eq "unsupported option message" \
    $'openedit: unsupported option: --bogus\nusage: openedit [options] [--] [file[:line[:col]] ...]' "$RUN_STDERR"
assert_eq "unsupported option does not forward" "" "$(forwarded)"

# Help/usage/version are informational and exit 0.
run_shim_stdout --help
assert_eq "--help exit code" 0 "$RUN_STATUS"
assert_eq "--help mentions wait" 1 "$(grep -c '^  -w, --wait' <<<"$RUN_STDOUT")"

run_shim_stdout --usage
assert_eq "--usage exit code" 0 "$RUN_STATUS"
assert_eq "--usage line" \
    "usage: openedit [options] [--] [file[:line[:col]] ...]" "$RUN_STDOUT"

run_shim_stdout --version
assert_eq "--version exit code" 0 "$RUN_STATUS"
assert_eq "--version output" "openedit 0.1.0" "$RUN_STDOUT"

run_shim_stdout --print-app-path
assert_eq "--print-app-path" "$fake_app" "$RUN_STDOUT"

# Position grammar rides as line/col query items.
run_shim --line 12 --col 4 "$a"
assert_eq "single position URL" \
    $'-a\n'"$fake_app"$'\n'"openedit://reuse-window?path=$a&line=12&col=4" "$(forwarded)"

run_shim "$a:3-9"
assert_eq "inline line range URL" \
    $'-a\n'"$fake_app"$'\n'"openedit://reuse-window?path=$a&line=3-9" "$(forwarded)"

run_shim --goto 5:2 "$a"
assert_eq "--goto position URL" \
    $'-a\n'"$fake_app"$'\n'"openedit://reuse-window?path=$a&line=5&col=2" "$(forwarded)"

run_shim --line 3-7 --col 2-9 "$a"
assert_eq "range URL" \
    $'-a\n'"$fake_app"$'\n'"openedit://reuse-window?path=$a&line=3-7&col=2-9" "$(forwarded)"

run_shim --line 4-2 "$a"
assert_eq "inverted range exit code" 2 "$RUN_STATUS"
assert_eq "inverted range does not forward" "" "$(forwarded)"

run_shim --line 4 "$a" "$b"
assert_eq "global position with multiple files exit code" 2 "$RUN_STATUS"

# Window aliases and per-document options.
run_shim --no-tabs "$a"
assert_eq "--no-tabs is --new-window" \
    $'-a\n'"$fake_app"$'\n'"openedit://new-window?path=$a" "$(forwarded)"

run_shim --readonly "$a"
assert_eq "--readonly URL" \
    $'-a\n'"$fake_app"$'\n'"openedit://reuse-window?path=$a&readonly=1" "$(forwarded)"

run_shim --no-highlighting --force-language python "$a"
assert_eq "language overrides URL" \
    $'-a\n'"$fake_app"$'\n'"openedit://reuse-window?path=$a&highlighting=0&language=python" "$(forwarded)"

# --encoding is validated against the known charset list (ARCHITECTURE.md 5.1).
run_shim --encoding ISO-8859-1 "$a"
assert_eq "--encoding URL" \
    $'-a\n'"$fake_app"$'\n'"openedit://reuse-window?path=$a&encoding=ISO-8859-1" "$(forwarded)"

run_shim --encoding not-a-charset "$a"
assert_eq "unknown encoding exit code" 2 "$RUN_STATUS"
assert_eq "unknown encoding does not forward" "" "$(forwarded)"

run_shim --no-watcher --watch-debounce 250 "$a"
assert_eq "watcher options URL" \
    $'-a\n'"$fake_app"$'\n'"openedit://reuse-window?path=$a&watcher=0&watch-debounce=250" "$(forwarded)"

run_shim --no-lsp --no-autodetect --lsp-language python --lsp-server python=/bin/echo "$a"
assert_eq "LSP options URL" \
    $'-a\n'"$fake_app"$'\n'"openedit://reuse-window?path=$a&lsp=0&autodetect=0&lsp-language=python&lsp-server=python%3D/bin/echo" "$(forwarded)"

run_shim --size 900x620 --position 10,20 --background "$a"
assert_eq "window and background URL" \
    $'-g\n-a\n'"$fake_app"$'\n'"openedit://reuse-window?path=$a&size=900x620&position=10%2C20&background=1" "$(forwarded)"

# --config is validated and carried; --no-config is a distinct flag.
config="$tmp/languages.toml"
printf '[[language]]\nextensions = ["x"]\nlanguageId = "x"\ngrammar = "json"\n' > "$config"
run_shim --config "$config" "$a"
assert_eq "--config URL" \
    $'-a\n'"$fake_app"$'\n'"openedit://reuse-window?path=$a&config=$config" "$(forwarded)"

run_shim --no-config "$a"
assert_eq "--no-config URL" \
    $'-a\n'"$fake_app"$'\n'"openedit://reuse-window?path=$a&no-config=1" "$(forwarded)"

# --dry-run never invokes open and --json gives machine-readable output.
run_shim_stdout --dry-run --json --line 2 "$a"
assert_eq "--dry-run --json exit code" 0 "$RUN_STATUS"
assert_eq "--dry-run --json forwards nothing" "" "$(forwarded)"
assert_eq "--dry-run --json shape" \
    "{\"app\":\"$fake_app\",\"arguments\":[\"-a\",\"$fake_app\",\"openedit://reuse-window?path=$a&line=2\"]}" \
    "$RUN_STDOUT"

# Scratch and stdin use the URL carrier without file targets.
run_shim --scratch
assert_eq "scratch exit code" 0 "$RUN_STATUS"
assert_eq "scratch URL" \
    $'-a\n'"$fake_app"$'\n'"openedit://reuse-window?scratch=1" "$(forwarded)"

stdin_file="$tmp/stdin.txt"
printf 'hello from stdin\n' > "$stdin_file"
: > "$stub_args"
RUN_STDERR="$("$shim" --stdin < "$stdin_file" 2>&1 >/dev/null)"
RUN_STATUS=$?
stdin_temp="$(sed -n 's|^openedit://reuse-window?path=\([^&]*\)&scratch=1$|\1|p' "$stub_args")"
assert_eq "stdin exit code" 0 "$RUN_STATUS"
assert_eq "stdin URL is scratch" 1 "$(grep -c 'scratch=1' "$stub_args")"
assert_eq "stdin content written" "hello from stdin" "$(cat "$stdin_temp" 2>/dev/null)"
rm -f "$stdin_temp"

echo
if (( failures > 0 )); then
    echo "$failures CLI test(s) failed"
    exit 1
fi
echo "all CLI tests passed"
