#!/usr/bin/env bash
# Functional (terminal-level) tests for the fibrous CMake profile editor.
#
# Drives a real Neovim inside a detached tmux session and emulates a user with
# actual keystrokes, then asserts on the recorded mode/window log and the
# captured screen. This is the only way to exercise the parts that depend on a
# UI: the letter flash jump (built on getcharstr) and the field navigation.
#
# Requires tmux and a fibrous.nvim checkout (see ORCHLAUNCH_DEPS). Skips cleanly
# when either is missing, so the main `tests/run.sh` stays dependency-free.
#
#   tests/func/run.sh
#
# Debugging: on any failure the captured screen and the tail of the transition
# log are printed. Set ORCH_FUNC_KEEP=1 to leave the tmux session alive.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$DIR/../.." && pwd)"
COLS="${ORCH_FUNC_COLS:-120}"
LINES="${ORCH_FUNC_LINES:-40}"

if ! command -v tmux >/dev/null 2>&1; then
    echo "SKIP  functional tests: tmux not found"
    exit 0
fi
if ! command -v nvim >/dev/null 2>&1; then
    echo "SKIP  functional tests: nvim not found"
    exit 0
fi

deps_root=""
for d in "${ORCHLAUNCH_DEPS:-}" "$HOME/.local/share/nvim/lazy" \
         "$HOME/.local/share/nvim/site/pack/deps/start" \
         "$HOME/.local/share/nvim/site/pack/core/opt"; do
    if [ -n "$d" ] && [ -d "$d/fibrous.nvim" ]; then
        deps_root="$d"
        break
    fi
done
if [ -z "$deps_root" ]; then
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
        tmux kill-session -t "$SESSION" >/dev/null 2>&1
        rm -rf "$TMP"
    else
        echo "kept tmux session: $SESSION (tmp: $TMP)"
    fi
}
trap cleanup EXIT

cap() { tmux capture-pane -p -t "$SESSION" 2>/dev/null; }
send() { tmux send-keys -t "$SESSION" "$@"; }
sendl() { tmux send-keys -t "$SESSION" -l "$1"; }
truncate_log() { : > "$LOG"; }
last_win() { grep '^win=' "$LOG" 2>/dev/null | tail -1 | sed 's/^win=\([0-9]*\).*/\1/'; }
has() { grep -qF "$1" "$LOG" 2>/dev/null; }

report_fail() {
    echo "FAIL  $1"
    echo "------ screen ------"
    cap > "$OUT"
    cat -n "$OUT"
    echo "------ transitions (tail) ------"
    tail -n 30 "$LOG" 2>/dev/null
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

# ---------------------------------------------------------------------------
# launch nvim inside tmux
# ---------------------------------------------------------------------------
tmux new-session -d -s "$SESSION" -x "$COLS" -y "$LINES"

cat > "$TMP/launch.sh" <<EOF
#!/usr/bin/env bash
export ORCH_FUNC_PLUGIN="$PLUGIN"
export ORCH_FUNC_DEPS="$deps_root"
export ORCH_FUNC_ROOT="$PROJ"
export ORCH_FUNC_LOG="$LOG"
exec nvim -u "$DIR/init.lua"
EOF
chmod +x "$TMP/launch.sh"

sendl "$TMP/launch.sh"
send Enter

if ! wait_for "Save" 20; then
    report_fail "editor opens"
else
    report_pass "editor opens"
fi
ROOT_WIN="$(grep -m1 '^open ' "$LOG" | sed 's/^open root=\([0-9]*\).*/\1/')"

# ---------------------------------------------------------------------------
# 1. flash jump: s then a label letter enters that field (INSERT)
#    (no <Esc> first: on the canvas <Esc> closes the editor!)
# ---------------------------------------------------------------------------
truncate_log
sendl "s"
sleep 0.4
sendl "s"
sleep 0.6
send F6
sleep 0.3
probe="$(tail -1 "$LOG" | grep '^probe ' || true)"
p_mode="$(printf '%s' "$probe" | sed -n 's/.* mode=\([a-z]*\).*/\1/p')"
p_win="$(printf '%s' "$probe" | sed -n 's/.* win=\([0-9]*\).*/\1/p')"
p_tab="$(printf '%s' "$probe" | sed -n 's/.* tab=\([a-z]*\).*/\1/p')"
if [ "$p_mode" = "i" ] && [ "$p_win" != "$ROOT_WIN" ] && [ "$p_tab" = "true" ]; then
    report_pass "flash letter jump enters a field (insert)"
else
    report_fail "flash letter jump enters a field (insert) [probe=$probe]"
fi

# ---------------------------------------------------------------------------
# 2. Tab from inside a field moves to another field and keeps typing
# ---------------------------------------------------------------------------
win_before="$p_win"
truncate_log
send Tab
sleep 0.6
send F6
sleep 0.3
probe="$(tail -1 "$LOG" | grep '^probe ' || true)"
win_after="$(printf '%s' "$probe" | sed -n 's/.* win=\([0-9]*\).*/\1/p')"
t_mode="$(printf '%s' "$probe" | sed -n 's/.* mode=\([a-z]*\).*/\1/p')"
if [ -n "$win_after" ] && [ "$win_after" != "$win_before" ] && [ "$t_mode" = "i" ]; then
    report_pass "Tab cycles into the next field (insert)"
else
    report_fail "Tab cycles into the next field (insert) [before=$win_before after=$win_after probe=$probe]"
fi

# ---------------------------------------------------------------------------
# 3. <S-Tab> cycles back to the previous field (insert) — crossing a dropdown
# ---------------------------------------------------------------------------
win_prev="$win_after"
truncate_log
send BTab
sleep 0.6
send F6
sleep 0.3
probe="$(tail -1 "$LOG" | grep '^probe ' || true)"
win_back="$(printf '%s' "$probe" | sed -n 's/.* win=\([0-9]*\).*/\1/p')"
b_mode="$(printf '%s' "$probe" | sed -n 's/.* mode=\([a-z]*\).*/\1/p')"
if [ -n "$win_back" ] && [ "$win_back" != "$win_prev" ] && [ "$b_mode" = "i" ]; then
    report_pass "S-Tab cycles back to the previous field (insert)"
else
    report_fail "S-Tab cycles back to the previous field (insert) [before=$win_prev after=$win_back probe=$probe]"
fi

# ---------------------------------------------------------------------------
# 4. <Esc> leaves the field back to the canvas (focus returns to the root)
# ---------------------------------------------------------------------------
truncate_log
send Escape
sleep 0.5
send F6
sleep 0.3
probe="$(tail -1 "$LOG" | grep '^probe ' || true)"
e_win="$(printf '%s' "$probe" | sed -n 's/.* win=\([0-9]*\).*/\1/p')"
if [ "$e_win" = "$ROOT_WIN" ]; then
    report_pass "Esc returns from a field to the canvas"
else
    report_fail "Esc returns from a field to the canvas [probe=$probe]"
fi

# ---------------------------------------------------------------------------
# 5. q closes the editor from the canvas
# ---------------------------------------------------------------------------
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
