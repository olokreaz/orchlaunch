#!/usr/bin/env bash
# Drive a real LLDB native-debug session through an isolated tmux terminal and
# inspect its exact DAP state with `nvim --server ... --remote-expr`.
#
# Covers the stage-2 cycle on the fixture: breakpoint on the work() call in
# main, stop, Step In into work(), Step Over (exactly one line), Step Out back
# to main, Continue to a normal exit.
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
    cmake -S "$PROJ" -B "$TMP/build" -G Ninja -DCMAKE_BUILD_TYPE=Debug >/dev/null
    cmake --build "$TMP/build" >/dev/null
    cp "$TMP/build/native_debug_fixture" "$PROJ/native_debug_fixture"
fi

cat > "$TMP/launch.sh" <<LAUNCH
#!/usr/bin/env bash
export ORCH_FUNC_PLUGIN="$PLUGIN"
export ORCH_FUNC_DEPS="$DEPS_ROOT"
export ORCH_FUNC_ROOT="$PROJ"
export NVIM_APPNAME=orch-test
exec nvim --listen "$TMP/nvim.sock" -u "$DIR/native_debug_init.lua" >"$LOG" 2>&1
LAUNCH
chmod +x "$TMP/launch.sh"

"$DIR/../tmux_helper.sh" new-session -d -s "$SESSION" -x 120 -y 40 /bin/bash "$TMP/launch.sh"

pass=0
fail=0
report_pass() { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
remote() { nvim --server "$TMP/nvim.sock" --remote-expr "$1" 2>/dev/null; }
# Poll an expression until it equals `expected` or the timeout (seconds) passes.
wait_expr() {
    local expr="$1" expected="$2" timeout="${3:-20}" i actual=""
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
frame_line() { remote 'luaeval("require(\"orchlaunch.debug\").current_frame().line")'; }
frame_name() { remote 'luaeval("require(\"orchlaunch.debug\").current_frame().name")'; }
status() { remote 'luaeval("require(\"orchlaunch.debug\").status()")'; }
press() { remote "luaeval(\"require('orchlaunch.debug').$1()\")" >/dev/null; }
# Wait until the session is stopped at a given line in a frame. Frame names
# carry their signature (e.g. "work(int)"), so match the name as a prefix.
wait_stop_at() {
    local line="$1" name="$2" timeout="${3:-10}" i frame
    for ((i = 0; i < timeout * 10; i++)); do
        frame="$(frame_name)"
        if [ "$(status)" = "stopped" ] && [ "$(frame_line)" = "$line" ] && [[ "$frame" == "$name" || "$frame" == "$name("* ]]; then
            return 0
        fi
        sleep 0.1
    done
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
    report_pass "LLDB stops at the breakpoint in work()"
else
    report_fail "LLDB stops at the breakpoint in work()"
    printf '%s\n' '--- Neovim log ---'
    cat "$LOG" || true
    exit 1
fi

line_before="$(frame_line)"
if [ "$line_before" = "14" ] && [ "$(frame_name)" = "main" ]; then
    report_pass "remote-expr reports the stop on line 14 in main"
else
    report_fail "stop is at $(frame_name) line $line_before (expected main line 14)"
fi

# Step In: enters work() at its first statement, one stop.
press step_in
if wait_stop_at 5 work 10; then
    report_pass "Step In enters work() at line 5"
else
    report_fail "Step In did not enter work() (frame: $(frame_name) line $(frame_line))"
fi

# Step Over: exactly one source line, one stop.
line_before="$(frame_line)"
press step_over
if wait_stop_at 6 work 10; then
    report_pass "Step Over advances exactly one line (5 to 6)"
else
    report_fail "Step Over moved to $(frame_name) line $(frame_line) (expected work line 6)"
fi

# Step Out: back to main at the call site of work().
press step_out
if wait_stop_at 14 main 10; then
    report_pass "Step Out returns to main at line 14"
else
    report_fail "Step Out did not return to main line 14 (frame: $(frame_name) line $(frame_line))"
fi

# Continue to normal termination: the debuggee exits and the session reports
# exited (a clean end, not stopped or running).
press continue
if wait_expr 'luaeval("require(\"orchlaunch.debug\").status()")' exited 20 >/dev/null; then
    report_pass "Continue runs the program to a normal exit"
else
    report_fail "Continue did not end the session (status: $(status))"
fi

if [ "$fail" -ne 0 ]; then
    printf '=== %d passed, %d failed ===\n' "$pass" "$fail"
    printf '%s\n' '--- Neovim log ---'
    cat "$LOG" || true
    exit 1
fi
printf '=== %d passed, 0 failed ===\nFUNCTIONAL NATIVE DEBUG TESTS PASSED\n' "$pass"
