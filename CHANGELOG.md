# Changelog

All notable changes to OrchLaunch are documented here. No releases have been
tagged yet; the entries below describe the current, unreleased state.

## [Unreleased]

### Added

- Run/Debug configurations (`native`, `remote-debug`, `compound`), toolchains,
  external tools and before-launch steps (build / install / external).
- CMake integration: `CMakePresets.json` import and resolution, profiles,
  CMake File API target discovery and automatic run configurations for every
  target (executables, static/shared/module/object libraries, custom targets).
  Executables set `target`; other kinds have an empty executable and record
  their `runtime` instead, and all configurations build before launch by
  default (CLion style); non-executable configurations run only those build
  steps. Configurations created by hand before discovery are
  preserved, and new ones are saved immediately.
- Native debugging through nvim-dap with two selectable backends: LLDB
  (`lldb-dap`/`lldb-vscode`) and GDB (`gdb --interpreter=dap`), including
  remote attach over `host:port`.
- Debugger panel: threads, frames, scopes, variables and Continue / Pause /
  Step Over / In / Out / Restart / Stop / Toggle BP controls.
- Breakpoints with conditions and log points, managed from a panel and
  persisted per project in `.orch/breakpoints.json`.
- `:OrchLaunchCheck` environment preflight (CMake, compilers, debug adapters,
  nvim-dap and fibrous).
- Complete fibrous.nvim UI: browser, editors, list dialogs, debugger and
  breakpoints panels, plus continuous `Tab`/`Shift+Tab` field navigation with a
  letter flash-jump (`s`).

### Changed

- The UI now runs exclusively on fibrous.nvim; the previous Volt engine, its
  fallback paths and its tests were removed. `fibrous.nvim` is a required
  dependency.
- Debug sessions set `switchbuf=useopen,usetab` by default so nvim-dap no longer
  replaces the debugger panel with the stopped source file. Override with
  `vim.g.orchlaunch_dap_switchbuf`.
- `debug.start` now refuses to start when the selected adapter is not installed
  and reports the missing backend.

### Testing

- The suite runs real LLDB and GDB sessions: launch matrix, remote attach via
  `lldb-server`, conditional breakpoints, debugger controls and the debugger
  panel. No mocked DAP layer remains.
- Added a tmux-driven functional suite for the fibrous form focus/navigation.
