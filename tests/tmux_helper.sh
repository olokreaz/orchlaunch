#!/usr/bin/env bash
# Route every OrchLaunch functional-test tmux command to its private server.
set -euo pipefail
exec tmux -L orch "$@"
