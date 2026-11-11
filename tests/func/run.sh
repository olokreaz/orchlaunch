#!/usr/bin/env bash
# Functional (terminal-level) tests for the fibrous CMake profile editor.
#
# Drives a real Neovim inside a detached session on the isolated tmux server
# (`-L orch`) and emulates a user with actual keystrokes. Skips cleanly when
# tmux, nvim, or fibrous.nvim is unavailable.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$DIR/../.." && pwd)"
COLS="${ORCH_FUNC_COLS:-120}"
LINES="${ORCH_FUNC_LINES:-40}"
export NVIM_APPNAME=orch-test

if ! command -v tmux >/dev/null 2>&1; then
    echo "SKIP  functional tests: tmux not found"
    exit 0
fi
if ! command -v nvim >/dev/null 2>&1; then
    echo "SKIP  functional tests: nvim not found"
    exit 0
fi

DEPS_ROOT="${ORCHLAUNCH_DEPS:-$HOME/.local/share/nvim/lazy}"
if [ ! -d "$DEPS_ROOT/fibrous.nvim" ]; then
    echo "SKIP  functional tests: fibrous.nvim not found (set ORCHLAUNCH_DEPS)"
    exit 0
fi

TMP="$(mktemp -d)"
SESSION="orchfunc_$$"
LOG="$TMP/transitions.log"
OUT="$TMP/screen.txt"
PROJ="$TMP/proj"
mkdir -p "$PROJ"

pass=0
fail=0

cleanup() {
    if [ "${ORCH_FUNC_KEEP:-0}" != "1" ]; then
        "$DIR/../tmux_helper.sh" kill-session -t "$SESSION" >/dev/null 2>&1 || true
        rm -rf "$TMP"
    else
        echo "kept tmux session: $SESSION (tmp: $TMP)"
    fi
}
trap cleanup EXIT

cap() { "$DIR/../tmux_helper.sh" capture-pane -p -t "$SESSION" 2>/dev/null; }
send() { "$DIR/../tmux_helper.sh" send-keys -t "$SESSION" "$@"; }
sendl() { "$DIR/../tmux_helper.sh" send-keys -t "$SESSION" -l "$1"; }
truncate_log() { : > "$LOG"; }
last_win() { grep '^win=' "$LOG" 2>/dev/null | tail -1 | sed 's/^win=\([0-9]*\).*/\1/'; }
has() { grep -qF "$1" "$LOG" 2>/dev/null; }

report_fail() {
    echo "FAIL  $1"
    echo "------ screen ------"
    cap > "$OUT"
    cat -n "$OUT"
    echo "------ transitions (tail) ------"
    tail -n 30 "$LOG" 2>/dev/null || true
    echo "--------------------"
    fail=$((fail + 1))
}
report_pass() { echo "PASS  $1"; pass=$((pass + 1)); }

wait_for() {
    local pat="$1" timeout="${2:-15}" i
    for i in $(seq 1 $((timeout * 10))); do
        if cap | grep -qF "$pat"; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

cat > "$TMP/launch.sh" <<EOF
#!/usr/bin/env bash
export ORCH_FUNC_PLUGIN="$PLUGIN"
export ORCH_FUNC_DEPS="$DEPS_ROOT"
export ORCH_FUNC_ROOT="$PROJ"
export ORCH_FUNC_LOG="$LOG"
export NVIM_APPNAME=orch-test
exec nvim -u "$DIR/init.lua"
EOF
chmod +x "$TMP/launch.sh"

# Use an explicit Bash command in the isolated server. This avoids tmux's
# default interactive shell startup while keeping all tmux operations on -L orch.
"$DIR/../tmux_helper.sh" new-session -d -s "$SESSION" -x "$COLS" -y "$LINES" /bin/bash "$TMP/launch.sh"

if ! wait_for "Save" 20; then
    report_fail "editor opens"
else
    report_pass "editor opens"
fi
ROOT_WIN="$(grep -m1 '^open ' "$LOG" 2>/dev/null | sed 's/^open root=\([0-9]*\).*/\1/' || true)"

# 1. Flash jump enters a field in insert mode.
truncate_log
sendl "s"
sleep 0.4
sendl "s"
sleep 0.6
send F6
sleep 0.3
probe="$(tail -1 "$LOG" 2>/dev/null | grep '^probe ' || true)"
p_mode="$(printf '%s' "$probe" | sed -n 's/.* mode=\([a-z]*\).*/\1/p')"
p_win="$(printf '%s' "$probe" | sed -n 's/.* win=\([0-9]*\).*/\1/p')"
p_tab="$(printf '%s' "$probe" | sed -n 's/.* tab=\([a-z]*\).*/\1/p')"
if [ "$p_mode" = "i" ] && [ "$p_win" != "$ROOT_WIN" ] && [ "$p_tab" = "true" ]; then
    report_pass "flash letter jump enters a field (insert)"
else
    report_fail "flash letter jump enters a field (insert) [probe=$probe]"
fi

# 2. Tab moves to another field and keeps typing.
win_before="$p_win"
truncate_log
send Tab
sleep 0.6
send F6
sleep 0.3
probe="$(tail -1 "$LOG" 2>/dev/null | grep '^probe ' || true)"
win_after="$(printf '%s' "$probe" | sed -n 's/.* win=\([0-9]*\).*/\1/p')"
t_mode="$(printf '%s' "$probe" | sed -n 's/.* mode=\([a-z]*\).*/\1/p')"
if [ -n "$win_after" ] && [ "$win_after" != "$win_before" ] && [ "$t_mode" = "i" ]; then
    report_pass "Tab cycles into the next field (insert)"
else
    report_fail "Tab cycles into the next field (insert) [before=$win_before after=$win_after probe=$probe]"
fi

# 3. Shift-Tab cycles back to the previous field.
win_prev="$win_after"
truncate_log
send BTab
sleep 0.6
send F6
sleep 0.3
probe="$(tail -1 "$LOG" 2>/dev/null | grep '^probe ' || true)"
win_back="$(printf '%s' "$probe" | sed -n 's/.* win=\([0-9]*\).*/\1/p')"
b_mode="$(printf '%s' "$probe" | sed -n 's/.* mode=\([a-z]*\).*/\1/p')"
if [ -n "$win_back" ] && [ "$win_back" != "$win_prev" ] && [ "$b_mode" = "i" ]; then
    report_pass "S-Tab cycles back to the previous field (insert)"
else
    report_fail "S-Tab cycles back to the previous field (insert) [before=$win_prev after=$win_back probe=$probe]"
fi

# 4. Escape returns to the canvas.
truncate_log
send Escape
sleep 0.5
send F6
sleep 0.3
probe="$(tail -1 "$LOG" 2>/dev/null | grep '^probe ' || true)"
e_win="$(printf '%s' "$probe" | sed -n 's/.* win=\([0-9]*\).*/\1/p')"
if [ "$e_win" = "$ROOT_WIN" ]; then
    report_pass "Esc returns from a field to the canvas"
else
    report_fail "Esc returns from a field to the canvas [probe=$probe]"
fi

# 5. q closes the editor from the canvas.
sendl "q"
sleep 0.6
if wait_for "Save" 2; then
    report_fail "q closes the editor"
else
    report_pass "q closes the editor"
fi

echo "=== $pass passed, $fail failed ==="
if [ "$fail" -ne 0 ]; then
    exit 1
fi
echo "=== FUNCTIONAL TESTS PASSED ==="
