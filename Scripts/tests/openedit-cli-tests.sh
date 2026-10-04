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
    $'openedit: unsupported option: --bogus\nusage: openedit [--new-window] [file ...]' "$RUN_STDERR"
assert_eq "unsupported option does not forward" "" "$(forwarded)"

echo
if (( failures > 0 )); then
    echo "$failures CLI test(s) failed"
    exit 1
fi
echo "all CLI tests passed"
