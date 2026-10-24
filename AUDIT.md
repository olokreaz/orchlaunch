# OrchLaunch Audit

- Baseline: `e50c5c3` (`feat: add CMake actions, targets browser and toolchain environments`)
- Audited HEAD: `e679a18` (`docs: add full OrchLaunch audit`)
- Fixes below are implemented in local commits `ad384de..7903cfd` on top of `e679a18`.
- Date: 2026-10-23
- Scope: `lua/orchlaunch/**`, CMake preset handling, run/debug dispatch, DAP
  backends, fibrous UI, persistence, breakpoints, integrations and tests.
- P1-P3 were supplied with the follow-up task: preserve hand edits (P1), survive
  malformed JSON (P2) and report missing executables without a Lua traceback
  (P3). P4/P5 were not supplied. P1-P3 are covered by the fixes below.

## Severity model

| Severity | Meaning |
| --- | --- |
| High | Data corruption, a core workflow that cannot be used, or a crash in a normal workflow. |
| Medium | Wrong behavior in an edge case, misleading UX, or data-safety issue under a failure. |
| Low | Hardening, documentation drift, or a low-impact cleanup. |

## Summary

| ID | Severity | Status | Area |
| --- | --- | --- | --- |
| H-01 | High | Fixed in `55c1d67` | Rename collision created duplicate names. |
| H-02 | High | Fixed in `acaa7e3` | CMake profile editor never listed configured toolchains. |
| H-03 | High | Fixed in `ccbe9f0` | Compound configuration cycles caused unbounded recursion. |
| M-01 | Medium | Fixed | Malformed JSON or valid JSON with the wrong shape is handled unsafely. |
| M-02 | Medium | Fixed | Saves are non-atomic; reload can leave partially mixed state. |
| M-03 | Medium | Fixed | Debug session is marked active before backend validation. |
| M-04 | Medium | Fixed | Explicit adapter paths are resolved through the default backend. |
| M-05 | Medium | Fixed | `console.keep_open` / `clear_on_start` are stored but ignored. |
| M-06 | Medium | Fixed | Run/debug environment omits the active CMake profile environment. |
| M-07 | Medium | Fixed | Malformed preset `inherits` can throw during profile import. |
| M-08 | Medium | Fixed | Malformed CMake File API replies can throw during target discovery. |
| M-09 | Medium | Fixed | `ctest` and preflight ignore the configured toolchain CMake. |
| M-10 | Medium | Fixed | Preset import is not idempotent when a manual profile owns the preset name. |
| M-11 | Medium | Fixed | `presets.visible()` ignores `condition`. |
| M-12 | Medium | Fixed | Creating a nested project loads the highest ancestor instead of the created root. |
| M-13 | Medium | Fixed | Shared fibrous augroups break nested list/field dialogs. |
| M-14 | Medium | Fixed | CMake/build/tool steps block the Neovim UI and cannot be cancelled. |
| M-15 | Medium | Fixed | Switching projects leaves old breakpoints installed in nvim-dap. |
| L-01 | Low | Fixed | Direct `state.update_*()` renames do not update active/references. |
| L-02 | Low | Fixed | `config.from_lua()` executes arbitrary Lua. |
| L-03 | Low | Fixed | Breakpoint toggle without nvim-dap silently no-ops but reports "removed". |
| L-04 | Low | Fixed | Unknown configuration/console types fall through to a different behavior. |
| L-05 | Low | Fixed | Filesystem target fallback does not match symlinked executables. |
| L-06 | Low | Fixed | Multi-config File API artifacts use the first configuration only. |
| L-07 | Low | Fixed | `project.create()` can leave a partially created `.orch`. |
| L-08 | Low | Fixed | Remote-debug documentation advertises unsupported env/cwd/args. |

## Fixed high-severity findings

### H-01: Rename to an existing name created a duplicate

- Area: `lua/orchlaunch/state.lua`, all named-item editors.
- Root cause: `add_named()` rejected duplicate names, but `update_named()`
  replaced an existing entry without checking whether the new name belonged to
  another entry. Editors also checked duplicates only when creating.
- Impact: two configurations/toolchains/tools/profiles with the same name.
  Lookups become ambiguous, active selections may point at the wrong entry, and
  only one of the duplicates is addressable by name.
- Repro: create `A` and `B`, rename `B` to `A`, save, reload.
- Fix: `update_named()` now rejects a collision while allowing a no-op rename;
  native, remote, compound, toolchain and external-tool editors perform the same
  check before save.
- Regression tests: `tests/rename_validation_test.lua` (13 checks) and the
  rename scenario in `tests/e2e_ui_test.lua` (78 checks total).

### H-02: CMake profile editor did not list toolchains

- Area: `lua/orchlaunch/ui/fibrous/cmake_profile.lua`.
- Root cause: the editor iterated `state.toolchains()` directly. That function
  returns `{ toolchains = { ... } }`, so numeric `ipairs` found no entries.
- Impact: the toolchain dropdown contained only `(none)`; a user could not
  assign a toolchain from the profile editor.
- Fix: iterate `state.toolchains().toolchains`; expose
  `handle.orch.toolchain_options` for the headless regression test.
- Regression test: `tests/fibrous_cmake_profile_test.lua` (36 checks total).

### H-03: Compound configuration cycle caused unbounded recursion

- Area: `lua/orchlaunch/runner.lua`.
- Root cause: `launch_compound()` recursively expanded child configurations
  without tracking the active chain. `A -> B -> A` and self-cycles recursed
  until stack overflow.
- Impact: a valid but cyclic JSON document could crash the editor when run.
- Fix: pass an internal `_compound_stack`, reject a child already present in
  the chain, and report
  `compound configuration cycle detected: A -> B -> A`.
- Regression test: `tests/compound_cycle_test.lua` (6 checks: self-cycle,
  two-node cycle and acyclic compound).

## Medium-severity findings

### M-01: Unsafe JSON/schema handling during load and reload

- Fix: `config.load()` returns `nil, error`, rejects non-object and non-empty list JSON; each loader validates its schema; `state.reload()` builds the complete state before replacement and `init.load()` reports failures without throwing.
- Files: `lua/orchlaunch/config.lua:125-145`,
  `lua/orchlaunch/state.lua:164-185`, `lua/orchlaunch/init.lua:21-34`,
  `lua/orchlaunch/init.lua:46-51`.
- `config.load()` uses `assert()` for open/decode failures. `state.setup()`
  calls it without a recovery boundary; `M.load()` is called directly from
  `DirChanged`.
- Valid JSON with the wrong shape is silently treated as empty. For example, an
  array instead of an object yields no configurations; a later `state.save()`
  can overwrite the user's file with an empty document.
- Proposed fix: return `nil, error` from `config.load()`, validate top-level
  shapes in each loader, notify on load errors, and never overwrite a file that
  failed schema validation without an explicit user confirmation.

### M-02: Non-atomic writes and partial reload

- Fix: `config.save()` writes a sibling temporary file, flushes and renames it; `load_state()` constructs the whole state before replacing the live one.
- Files: `lua/orchlaunch/config.lua:159-169`,
  `lua/orchlaunch/state.lua:592-615`, `lua/orchlaunch/active.lua:37-49`,
  `lua/orchlaunch/breakpoints.lua:258-275`.
- `config.save()` truncates the destination before writing; a crash or full
  disk can leave a truncated JSON file. `state.reload()` updates fields one by
  one, so a later parse failure leaves new files mixed with old in-memory data.
- Proposed fix: write to a temporary sibling, fsync/rename, propagate errors,
  and build a complete replacement state before assigning it.

### M-03: Debug state starts before backend validation

- Fix: `debug.start()` validates the backend and availability first, calls `session.start_session()` only when actually launching, and resets the session on failure.
- Files: `lua/orchlaunch/debug/init.lua:81-104`,
  `lua/orchlaunch/debug/session.lua:347-353`.
- `session.start_session()` is called at line 89, before backend resolution,
  availability checks and adapter launch. Any early return leaves the debugger
  panel and session state at `active/running` with no real DAP session.
- Proposed fix: build and validate the request/backend first; call
  `start_session()` only immediately before a successful `d.run()` or
  backend handoff, or reset on every failure path.

### M-04: Explicit adapter path is forced through the default backend

- Fix: Backend resolution uses the adapter basename (`gdb`/`lldb`); an explicit `dap_path` satisfies availability.
- Files: `lua/orchlaunch/debug/init.lua:69-72`,
  `lua/orchlaunch/debug/backend.lua:105-131`,
  `lua/orchlaunch/debug/backends/lldb.lua:54-56`,
  `lua/orchlaunch/debug/backends/gdb.lua:21-23`.
- `build_request()` turns an adapter path into `dap_path`, but
  `backend.resolve()` cannot infer a backend from a path and falls back to
  lldb. A custom GDB path is therefore launched with the lldb key and without
  GDB's `--interpreter=dap` arguments. LLDB availability also ignores a valid
  `req.dap_path` and rejects the launch when `lldb-dap` is not on `PATH`.
- Proposed fix: infer the backend from the executable basename, or require an
  explicit backend for paths; make `available()` accept a valid explicit path.

### M-05: Console flags are not implemented

- Fix: `open_terminal()` honors `keep_open` and `clear_on_start`; unknown console modes warn and fall back to `embedded`.
- Files: `lua/orchlaunch/runner.lua:225-244`,
  `lua/orchlaunch/runner.lua:344-357`,
  `lua/orchlaunch/ui/fibrous/editors/native.lua:39-41`,
  `lua/orchlaunch/ui/fibrous/editors/native.lua:104-108`,
  `lua/orchlaunch/config.lua:365-372`.
- `keep_open` and `clear_on_start` are stored and shown in the editor, but the
  embedded terminal always creates a new buffer with `bufhidden=wipe`. Unknown
  `console.mode` values fall into the detached hidden branch rather than
  falling back to `embedded`.
- Proposed fix: either implement the options (reuse a terminal buffer, clear
  it according to policy) or remove them from types, UI and docs.

### M-06: Run/debug environment omits the active CMake profile environment

- Fix: `launch_environment()` merges toolchain, active CMake profile and configuration environments in that order.
- Files: `lua/orchlaunch/runner.lua:250-259`,
  `lua/orchlaunch/cmake.lua:158-175`, `README.md:156-159`.
- README says toolchain, active profile and run configuration environments are
  inherited by run/debug, with the run configuration winning. The runner merges
  only the toolchain environment and the configuration environment.
- Impact: variables such as `LD_LIBRARY_PATH` or a runtime `PATH` defined in the
  active CMake profile are missing when launching or debugging.
- Proposed fix: merge `settings().environment` between the toolchain and
  configuration environments, then resolve once.

### M-07: Malformed preset `inherits` can throw during import

- Fix: `presets.resolve()` validates `inherits` types and detects cycles, returning `nil, error`; preset import reports the error.
- Files: `lua/orchlaunch/presets.lua:329-334`,
  `lua/orchlaunch/state.lua:398`.
- A non-string, non-table `inherits` value (for example a number) reaches
  `ipairs(inherits or {})` and raises a Lua error. `sync_cmake_profiles()`
  calls `presets.resolve()` without a pcall.
- Proposed fix: validate the type and report a preset-level error instead of
  propagating it through the UI.

### M-08: Malformed File API replies can throw during target discovery

- Fix: `read_targets()` guards every nested File API table and skips malformed entries.
- Files: `lua/orchlaunch/cmake.lua:453-495`.
- `codemodel.configurations` is checked, but each `configuration.targets` is
  passed directly to `ipairs`; a malformed reply with a non-table value raises.
- Proposed fix: guard every nested File API shape and skip invalid entries.

### M-09: `ctest` and preflight ignore the toolchain CMake

- Fix: `ctest_program()` resolves `ctest` from the profile, `CMAKE_CTEST_COMMAND` or the configured CMake sibling; preflight checks the effective toolchain.
- Files: `lua/orchlaunch/cmake.lua:312-330`,
  `lua/orchlaunch/preflight.lua:47-60`.
- `M.cmake_program()` honors the toolchain CMake path, but test discovery and
  execution hard-code `ctest`. Preflight also checks `cmake` from `PATH`, not
  the configured toolchain.
- Proposed fix: derive `ctest` from the configured CMake installation or
  `CMAKE_CTEST_COMMAND`, and run preflight against the effective toolchain.

### M-10: Preset import is not idempotent on name collisions

- Fix: `sync_cmake_profiles()` identifies already-imported profiles by their configure/build preset pair and skips them.
- Files: `lua/orchlaunch/state.lua:371-406`.
- When a manual profile already uses a build preset's name, `free_name()` adds
  a suffix. On every later import the same check fails again, producing
  `name (build)`, `name (build 2)`, and so on.
- Proposed fix: identify an existing profile by its configure/build preset
  pair, or update/skip the conflicting manual profile explicitly.

### M-11: Preset visibility ignores `condition`

- Fix: `presets.condition()` implements `const`, `not`, `and`, `or`, `equals`, `in` and `matches` with `$env`/`$penv` expansion; `visible()` applies it without mutating the caller context.
- Files: `lua/orchlaunch/presets.lua:251-258`,
  `lua/orchlaunch/ui/fibrous/cmake_profile.lua:171-179`,
  `lua/orchlaunch/state.lua:384-395`.
- Hidden presets are filtered, but CMake `condition` expressions are ignored.
  Presets that should not be selectable on the current host or compiler are
  imported and shown.
- Proposed fix: evaluate the CMake condition subset or document it as
  unsupported and exclude presets with unverifiable conditions.

### M-12: Nested project creation loads the parent project

- Fix: `create_project()` passes the explicit `project.orch_dir(root)` to `state.setup()`.
- Files: `lua/orchlaunch/project.lua:35-50`,
  `lua/orchlaunch/init.lua:140-143`.
- `create_project(root)` creates `.orch` under `root` and then calls
  `state.setup(root)`, which uses `project.locate()` and returns the highest
  ancestor containing `.orch`.
- Impact: in a nested project, the child files are created but the parent is
  loaded and the success notification names `root`.
- Proposed fix: call `state.setup(root, project.orch_dir(root))` after creation,
  or make `locate()` prefer the nearest marker for explicit roots.

### M-13: Shared fibrous augroups break nested dialogs

- Fix: Each list/fields/form instance receives a unique augroup and deletes only its own group.
- Files: `lua/orchlaunch/ui/fibrous/util.lua:63-73`,
  `lua/orchlaunch/ui/fibrous/list.lua:82,315`,
  `lua/orchlaunch/ui/fibrous/fields.lua:232`.
- `watch_resize()` creates with `clear = true`, and both lists use
  `OrchlaunchFibrousList`. Opening a target list from the browser replaces the
  browser's resize handler; closing either list deletes the shared group. Field
  wiring has the same pattern under `OrchlaunchFibrousFields`.
- Proposed fix: generate a unique augroup per dialog instance and delete only
  that instance's group.

### M-14: Synchronous CMake/build/tool steps block the UI

- Fix: `runner` exposes async configure/build/clean/rebuild/install/test/load/external-tool paths used by commands and the UI, plus `:OrchLaunchCancel`; the sync API remains available.
- Files: `lua/orchlaunch/process.lua:82-92`,
  `lua/orchlaunch/runner.lua:48-106`.
- Runs use `vim.system(...):wait()`; build/test/configure can block Neovim for
  up to the 15-minute default with no cancellation or progress UI.
- Proposed fix: use asynchronous jobs with a cancellable progress handle, or
  document the synchronous behavior as intentional and expose a short timeout.

### M-15: Project switch leaves old breakpoints installed

- Fix: `breakpoints.load()` clears managed live breakpoints before applying the new project set.
- Files: `lua/orchlaunch/init.lua:21-34`,
  `lua/orchlaunch/breakpoints.lua:279-302`.
- `init.load()` applies the new project's persisted breakpoints but never
  clears live nvim-dap breakpoints from the previous project.
- Proposed fix: clear project-managed breakpoints before applying the new
  project's set, while leaving user breakpoints outside the managed set alone
  if they can be identified.

## Low-severity findings

### L-01: Direct state renames do not update active references

- Fix: Configuration/profile update and remove paths update the `active` bookkeeping.
- Files: `lua/orchlaunch/state.lua:510-561`,
  `lua/orchlaunch/active.lua:62`.
- The UI updates the active key after a rename, but the public state API does
  not. An API user can rename the active configuration/profile and leave the
  active pointer stale.
- Proposed fix: centralize rename bookkeeping in state, or document the API
  contract.

### L-02: `config.from_lua()` executes arbitrary Lua

- Fix: `from_lua()` runs in an empty environment, disables LuaJIT during evaluation and enforces an instruction budget.
- File: `lua/orchlaunch/config.lua:246`.
- The loader is not called internally, but it is a public function. Passing
  untrusted text executes arbitrary code.
- Proposed fix: remove it from the public API or document that the input must
  be trusted.

### L-03: Breakpoint toggle without nvim-dap silently no-ops

- Fix: `set`/`toggle`/`clear` return success and commands report missing `nvim-dap` instead of claiming a removal.
- Files: `lua/orchlaunch/breakpoints.lua:100-107`,
  `lua/orchlaunch/commands.lua:250-261`.
- `toggle()` returns silently when nvim-dap is absent; the command then reports
  `breakpoint removed at ...`.
- Proposed fix: return success/error and notify "nvim-dap is not installed".

### L-04: Unknown configuration and console types fall through

- Fix: Unknown console modes warn and use `embedded`; unknown configuration types are rejected before dispatch.
- Files: `lua/orchlaunch/runner.lua:344-357`,
  `lua/orchlaunch/runner.lua:421-426`.
- Any non-compound/non-remote configuration is launched as native. Any console
  mode other than `embedded`/`none` is treated as a detached hidden process.
- Proposed fix: validate types at load/save and reject unknown values with a
  clear error.

### L-05: Symlinked executables are not found by the fallback search

- Fix: Filesystem fallback accepts readable symlinked artifacts.
- File: `lua/orchlaunch/cmake.lua:607-640`.
- The breadth-first fallback only accepts `kind == "file"`; a symlinked build
  artifact is reported as a link and skipped.
- Proposed fix: accept links when `filereadable(full) == 1`.

### L-06: Multi-config artifacts use the first configuration

- Fix: Targets retain per-configuration artifacts and `find_target()` selects the active build type, falling back to the first.
- Files: `lua/orchlaunch/cmake.lua:475-493`,
  `lua/orchlaunch/cmake.lua:388-410`.
- Target discovery deduplicates by name and records the artifact from the first
  codemodel configuration. Multi-config generators can put artifacts in
  configuration-specific paths.
- Proposed fix: store per-configuration artifacts or resolve the artifact for
  the active build type.

### L-07: `project.create()` can leave a partial `.orch`

- Fix: `project.create()` scaffolds in a temporary sibling directory and renames it into place.
- File: `lua/orchlaunch/project.lua:56-84`.
- Files are written sequentially; a failure after the directory or first file
  leaves a partial project that later looks valid.
- Proposed fix: create in a temporary directory and rename, or clean up on
  failure.

### L-08: Remote-debug documentation advertises unsupported fields

- Fix: `DOCUMENTATION.md` now states that attach requests ignore `env`, `cwd` and `args`.
- Files: `DOCUMENTATION.md:387-390`, `lua/orchlaunch/types.lua:65-73`,
  `lua/orchlaunch/runner.lua:388-400`.
- Documentation lists env, cwd and args for remote-debug; the type and runner
  do not carry them into the DAP request.
- Proposed fix: implement the fields in the attach request, or correct the
  documentation.

## Verification

Executed on `e679a18` plus these fixes with `ORCHLAUNCH_DEPS=/tmp/opencode/deps`:

- `bash tests/run.sh`: `EXIT=0`, `=== ALL TESTS PASSED ===`, no `FAIL` lines.
- `bash tests/func/run.sh`: `6 passed, 0 failed`,
  `=== FUNCTIONAL TESTS PASSED ===`.
- Targeted checks included in the full run:
  - `tests/hardening_test.lua`: 42 checks (JSON shape errors, atomic saves,
    external-edit conflicts, sandbox, preset conditions, async cancel, augroups).
  - `tests/e2e_debug_attach_test.lua`: 9 checks (real `lldb-server` attach).
  - `tests/debug_backend_test.lua`: 34 checks.
  - `tests/e2e_cmake_test.lua`: 101 checks (toolchain/profile env, real CTest).
  - `tests/e2e_runner_test.lua`: 28 checks.
  - `tests/rename_validation_test.lua`: 13 checks.
  - `tests/e2e_ui_test.lua`: 78 checks.
  - `tests/fibrous_cmake_profile_test.lua`: 36 checks.
  - `tests/compound_cycle_test.lua`: 6 checks.

## Manual checks still required

- Remote debugging against a real gdbserver/lldb-server host.
- `ptrace_scope=1` attach behavior; attach to another user's process remains
  intentionally blocked.
- Windows fallback for the atomic rename path.
- Running the plugin under `sudo` where the debugger cannot elevate.
- Interactive resize behavior of two simultaneously open fibrous dialogs.

## Limitations of this audit

- No remote host, Windows/macOS environment or user projects were available.
- Tests are headless plus a tmux-driven fibrous editor test; the debug e2e tests
  do run real LLDB and GDB DAP sessions locally.
- `INTERFACE_LIBRARY` targets are absent from CMake File API, so that runtime
  kind cannot be validated end-to-end.
- P4/P5 were not supplied, so no parity claim against them is made.
