#!/usr/bin/env bash
# Drive a real LLDB native-debug session through an isolated tmux terminal and
# inspect its exact DAP state with `nvim --server ... --remote-expr`.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$DIR/../.." && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
DEPS_ROOT="${ORCHLAUNCH_DEPS:-$HOME/.local/share/nvim/lazy}"
FIXTURE="$REPO/build/orchlaunch-stage0/native_debug_fixture"
export NVIM_APPNAME=orch-test

for tool in tmux nvim cmake ninja clang++ lldb-dap; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "SKIP  native debug tmux e2e: $tool not found"
        exit 0
    fi
done
if [ ! -d "$DEPS_ROOT/nvim-dap" ]; then
    echo "SKIP  native debug tmux e2e: nvim-dap not found (set ORCHLAUNCH_DEPS)"
    exit 0
fi

TMP="$(mktemp -d)"
SESSION="orchnative_$$"
PROJ="$TMP/proj"
LOG="$TMP/nvim.log"
mkdir -p "$PROJ"
cp "$DIR/../fixtures/native-debug/main.cpp" "$PROJ/main.cpp"
cp "$DIR/../fixtures/native-debug/CMakeLists.txt" "$PROJ/CMakeLists.txt"

cleanup() {
    "$DIR/../tmux_helper.sh" kill-session -t "$SESSION" >/dev/null 2>&1 || true
    if [ "${ORCH_FUNC_KEEP:-0}" = "1" ]; then
        printf 'kept native debug test artifacts: %s (session: %s)\n' "$TMP" "$SESSION"
    else
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT

# Reuse the configured build only if it already targets this source tree;
# otherwise build in this test's temporary directory to preserve build/.
if [ -x "$FIXTURE" ] && [ "$(cmake -LA -N "$REPO/build/orchlaunch-stage0" 2>/dev/null | sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p')" = "$REPO/tests/fixtures/native-debug" ]; then
    cp "$FIXTURE" "$PROJ/native_debug_fixture"
else
    cmake -S "$PROJ" -B "$TMP/build" -G Ninja -DCMAKE_BUILD_TYPE=Debug
    cmake --build "$TMP/build"
    cp "$TMP/build/native_debug_fixture" "$PROJ/native_debug_fixture"
fi

cat > "$TMP/launch.sh" <<EOF
#!/usr/bin/env bash
export ORCH_FUNC_PLUGIN="$PLUGIN"
export ORCH_FUNC_DEPS="$DEPS_ROOT"
export ORCH_FUNC_ROOT="$PROJ"
export NVIM_APPNAME=orch-test
exec nvim --listen "$TMP/nvim.sock" -u "$DIR/native_debug_init.lua" >"$LOG" 2>&1
EOF
chmod +x "$TMP/launch.sh"

"$DIR/../tmux_helper.sh" new-session -d -s "$SESSION" -x 120 -y 40 /bin/bash "$TMP/launch.sh"

pass=0
fail=0
report_pass() { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
remote() { nvim --server "$TMP/nvim.sock" --remote-expr "$1" 2>/dev/null; }
wait_expr() {
    local expr="$1" expected="$2" timeout="${3:-20}" i actual
    for ((i = 0; i < timeout * 10; i++)); do
        actual="$(remote "$expr" || true)"
        if [ "$actual" = "$expected" ]; then
            printf '%s' "$actual"
            return 0
        fi
        sleep 0.1
    done
    printf '%s' "$actual"
    return 1
}

if ! wait_expr 'luaeval("1 + 1")' 2 20 >/dev/null; then
    report_fail "Neovim remote server starts"
    printf '%s\n' '--- Neovim log ---'
    cat "$LOG" || true
    exit 1
fi
report_pass "Neovim remote server starts in isolated tmux session"

if wait_expr 'luaeval("require(\"orchlaunch.debug\").status()")' stopped 30 >/dev/null; then
    report_pass "LLDB stops at the source breakpoint"
else
    report_fail "LLDB stops at the source breakpoint"
    printf '%s\n' '--- Neovim log ---'
    cat "$LOG" || true
    exit 1
fi

line_before="$(remote 'luaeval("require(\"orchlaunch.debug\").current_frame().line")')"
if [ "$line_before" = "4" ]; then
    report_pass "remote-expr reports breakpoint at line 4"
else
    report_fail "remote-expr breakpoint line is $line_before (expected 4)"
fi

remote 'luaeval("require(\"orchlaunch.debug\").step_over()")' >/dev/null
if wait_expr 'luaeval("require(\"orchlaunch.debug\").status()")' stopped 10 >/dev/null; then
    line_after="$(remote 'luaeval("require(\"orchlaunch.debug\").current_frame().line")')"
    if [ "$line_after" = "5" ] && [ "$((line_after - line_before))" -eq 1 ]; then
        report_pass "one Step Over advances exactly one source line (4 to 5)"
    else
        report_fail "one Step Over advanced from line $line_before to $line_after"
    fi
else
    report_fail "debug session returns to stopped state after Step Over"
fi

remote 'luaeval("require(\"orchlaunch.debug\").stop()")' >/dev/null || true
if [ "$fail" -ne 0 ]; then
    printf '=== %d passed, %d failed ===\n' "$pass" "$fail"
    exit 1
fi
printf '=== %d passed, 0 failed ===\nFUNCTIONAL NATIVE DEBUG TESTS PASSED\n' "$pass"
