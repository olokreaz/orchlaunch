#!/usr/bin/env bash
# Functional (terminal-level) test for the OrchLaunch menu.
#
# Starts a real Neovim in a detached session on the isolated tmux server
# (`-L orch`), presses the keys a user would press and asserts on the screen.
# Skips cleanly when tmux, nvim or fibrous.nvim is unavailable.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$DIR/../.." && pwd)"
COLS="${ORCH_FUNC_COLS:-120}"
LINES="${ORCH_FUNC_LINES:-40}"
export NVIM_APPNAME=orch-test

if ! command -v tmux >/dev/null 2>&1; then
    echo "SKIP  menu functional tests: tmux not found"
    exit 0
fi
if ! command -v nvim >/dev/null 2>&1; then
    echo "SKIP  menu functional tests: nvim not found"
    exit 0
fi

DEPS_ROOT="${ORCHLAUNCH_DEPS:-$HOME/.local/share/nvim/lazy}"

TMP="$(mktemp -d)"
SESSION="orchmenu_$$"
PROJ="$TMP/proj"
mkdir -p "$PROJ"

# A minimal .orch project with one native configuration and one CMake profile,
# so the menu and statusline have something real to show.
mkdir -p "$PROJ/.orch"
cat > "$PROJ/.orch/run_configurations.json" <<'JSON'
{
  "configurations": [
    { "name": "app", "type": "native", "target": "app_bin" }
  ]
}
JSON
cat > "$PROJ/.orch/toolchain.json" <<'JSON'
{
  "toolchains": [
    { "name": "gcc", "type": "system", "cmake": "cmake", "c": "gcc", "cxx": "g++", "debugger": "gdb" }
  ]
}
JSON
cat > "$PROJ/.orch/cmake_settings.json" <<'JSON'
{
  "cmake": {
    "active": "Debug",
    "profiles": [
      { "name": "Debug", "toolchain": "gcc", "build_type": "Debug" }
    ]
  }
}
JSON

LOG="$TMP/out.txt"
pass=0
fail=0

tm() { "$DIR/../tmux_helper.sh" "$@"; }
cap() { tm capture-pane -p -t "$SESSION" 2>/dev/null; }
send() { tm send-keys -t "$SESSION" "$@"; }
sendl() { tm send-keys -t "$SESSION" -l "$1"; }

cleanup() {
    if [ "${ORCH_FUNC_KEEP:-0}" != "1" ]; then
        tm kill-session -t "$SESSION" >/dev/null 2>&1 || true
        rm -rf "$TMP"
    else
        echo "kept tmux session: $SESSION (tmp: $TMP)"
    fi
}
trap cleanup EXIT

wait_for() {
    local pat="$1" timeout="${2:-15}" i
    for i in $(seq 1 $((timeout * 10))); do
        if cap | grep -qF -- "$pat"; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

report_pass() { echo "PASS  $1"; pass=$((pass + 1)); }
report_fail() {
    echo "FAIL  $1"
    echo "------ screen ------"
    cap | cat -n
    echo "--------------------"
    fail=$((fail + 1))
}

cat > "$TMP/launch.sh" <<EOF
#!/usr/bin/env bash
export ORCH_FUNC_PLUGIN="$PLUGIN"
export ORCH_FUNC_DEPS="$DEPS_ROOT"
export ORCH_FUNC_ROOT="$PROJ"
export NVIM_APPNAME=orch-test
exec nvim -u "$DIR/menu_init.lua"
EOF
chmod +x "$TMP/launch.sh"

tm new-session -d -s "$SESSION" -x "$COLS" -y "$LINES" /bin/bash "$TMP/launch.sh"

# 1. Editor starts and the statusline shows the active configuration.
if wait_for "app" 20; then
    report_pass "editor starts and statusline shows the configuration"
else
    report_fail "editor starts and statusline shows the configuration"
fi

# 2. <leader>o opens the menu with the configuration in its prompt.
send Space
send o
if wait_for "OrchLaunch — app" 5; then
    report_pass "<leader>o opens the menu (prompt shows active configuration)"
else
    report_fail "<leader>o opens the menu (prompt shows active configuration)"
fi

# 3. The menu lists the main actions.
if wait_for "Run active configuration" 3 && wait_for "Build" 3; then
    report_pass "menu lists Run and Build"
else
    report_fail "menu lists Run and Build"
fi

# 4. Escape closes the menu without running anything.
send Escape
sleep 0.5
if cap | grep -qF "OrchLaunch — app"; then
    report_fail "Escape closes the menu"
else
    report_pass "Escape closes the menu"
fi

# 5. <leader>or runs the active configuration. The target is not built here,
#    so the runner must report that exact reason; this proves the keymap fired
#    and reached the runner, not just that some text appeared.
#    The keys are sent in one burst, as a user types them: a pause between
#    <leader>o and the suffix would let the menu open first.
send Space o r
if wait_for 'cannot resolve CMake target "app_bin"' 5; then
    report_pass "<leader>or runs the active configuration (reaches runner)"
else
    report_fail "<leader>or runs the active configuration (reaches runner)"
fi

echo
echo "functional menu tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
