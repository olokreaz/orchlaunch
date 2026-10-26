# Changelog

All notable changes to OrchLaunch are documented here. No releases have been
tagged yet; the entries below describe the current, unreleased state.

## [Unreleased]

### Fixed

- **`:OrchLaunchRun` crashed** with `attempt to call global 'open_terminal'`:
  the asynchronous launch path used a local function declared further down.
  Covered by a test that drives the real command (embedded, hidden, none).
- **Setup options were ignored.** `setup()` never stored its options, so
  `ui.backend`, `ui.edit.*` and `ui.virtual_text` had no effect. Options are
  now normalized and stored (`orchlaunch.options`); invalid values fall back
  with a warning.
- **`:OrchLaunchEdit` looped forever** (the file picker discarded the choice and
  *Open whole file* re-opened the entry picker). Rewritten; unknown
  subcommands warn, names with spaces work, an open buffer is refreshed after
  the plugin writes the file, `fold_others` is window-local.
- **Semantic validation never reported anything.** The line scanner started at
  the wrong brace depth, looked at the wrong buffer and spawned CMake on every
  run. Rewritten on a position-aware JSON parser (`orchlaunch.jsonpos`) with
  pure `check()` functions, real checks for tools/toolchains/profiles, exact
  lines and no process spawning.
- **Empty lists were written as `{}`**, violating the schemas (jsonls
  underlined fresh projects). They are written as `[]`; old files still load.
  A vacuous `oneOf` in `cmake_settings.schema.json` was removed.
- **jsonls integration**: URL-encoded file URLs, idempotent `setup()`,
  `client:notify` on Neovim >= 0.11, `$schema` inserted with a minimal text
  edit instead of re-encoding the buffer, files outside `.orch/` are never
  touched.
- **Pickers did nothing** in buffer mode (they only printed *Selected ...*);
  the profile label crashed for profiles without `kind`; `:OrchLaunchRunHere`
  could never find a configuration.
- Missing programs report `cmake: command not found (is it installed and in
  PATH?)` instead of Neovim internals; tests that need cmake/gdb/lldb skip
  with a reason; the schema drift test really runs (own draft-07 subset
  validator, real jsonls when installed) and is part of `tests/run.sh`.

### Added

- **Floating editor by default** — `:OrchLaunchEdit`/`:OrchLaunchNew` now open
  the JSON file in a centered floating window (`ui.edit.window = "float"`).
  Floating editors behave like a form: `:w` saves and closes the window
  (`ui.edit.close_on_write`, default on), `q`/`<Esc>` close it, and unsaved
  changes are protected.
- **JSON Schema & Language Server Integration** — Ships draft-07 schemas for all
  `.orch/*.json` files (`schemas/`). Auto-registers with `jsonls`
  (vscode-json-language-server) on `LspAttach` for autocompletion, hover docs,
  and structural validation. Optional `$schema` reference written on save
  (`write_schema_ref` option). Manual setup instructions for nvim-lspconfig
  and `vim.lsp.config`.
- **Buffer-based Editing UI (New Default)** — Configuration files are edited as
  plain JSON buffers with syntax highlighting, folding, undo, and all user
  plugins. New commands:
  - `:OrchLaunchEdit [configs|tools|toolchain|cmake|breakpoints]` — open file,
    optionally jump to a specific entry.
  - `:OrchLaunchNew [native|remote-debug|compound|external_tool|toolchain|cmake_profile]` — create new entry with defaults.
  - `:OrchLaunchRunHere` — run the configuration under cursor in `run_configurations.json`.
  - Selection via `vim.ui.select` (telescope/snacks/fzf-lua/dressing):
    `:OrchLaunchSelectConfig`, `:OrchLaunchSelectDebug`,
    `:OrchLaunchSelectTarget`, `:OrchLaunchSelectToolchain`,
    `:OrchLaunchSelectProfile`, `:OrchLaunchSelectPreset`,
    `:OrchLaunchSelectTool`.
- **Semantic Validation** — `vim.diagnostic` integration for rules JSON Schema
  cannot express: unknown CMake targets, missing toolchains/profiles/tools,
  compound cycles, duplicate names, sudo with hidden/none console, empty native
  configurations. Debounced on `TextChanged`/`InsertLeave`, cleared on
  `BufDelete`.
- **Virtual Text** — in `run_configurations.json`, native configurations show
  the resolved executable path as virtual text at end of line (toggle with
  `ui.virtual_text`).
- **UI Backend Selection** — `setup({ ui = { backend = "buffer" } })` (default)
  or `"fibrous"`. Fibrous becomes optional; falls back to buffer UI with a
  warning if fibrous is missing. Fibrous code is lazy-loaded.
- **JSON Schema Drift Test** — `tests/schema_check_test.lua` validates examples
  against schemas and checks enum consistency between schemas and code.
- `:OrchLaunchCheck` now reports jsonls availability and schema registration status.

### Changed

- **Default UI backend is now "buffer"** — fibrous is optional. The classic
  fibrous UI is still available via `setup({ ui = { backend = "fibrous" } })`
  or commands like `:OrchLaunchEditConfig`.
- **fibrous.nvim is now optional** — the plugin works without it. The fibrous
  UI code is lazy-loaded on demand.
- `:OrchLaunchEdit` now opens JSON buffers with `vim.ui.select` for entry
  selection instead of fibrous forms.
- `:OrchLaunchCheck` reports jsonls presence and schema registration.

### Removed

- Fibrous is no longer a required dependency (removed from `dependencies` in
  installation example).

### Testing

- Added `tests/schema_check_test.lua` — validates example configs against schemas
  and checks enum drift between schemas and code (skips if jsonschema not
  installed).
- Added `tests/hardening_test.lua` — regression tests for persistence,
  sandboxing, async cancel, and unique augroups.

### Fixed

- Fixed a crash when running a native configuration with the buffer UI:
  the async launch path called `open_terminal` before its local definition,
  raising "attempt to call global 'open_terminal' (a nil value)".
- Fixed a crash on `BufWritePost` for `.orch/*.json` buffers where
  `is_orch_buffer` was referenced before its local definition.
- `:OrchLaunchEdit <file_type> <entry>` now parses the second argument instead
  of falling back to the file picker.
- Fixed various issues with schema enum drift detection and validation
  position finding.

### Testing

- The suite runs real LLDB and GDB sessions: launch matrix, remote attach via
  `lldb-server`, conditional breakpoints, debugger controls and the debugger
  panel. No mocked DAP layer remains.
- Added a tmux-driven functional suite for the fibrous form focus/navigation.
- All existing tests pass with the new buffer-based UI.