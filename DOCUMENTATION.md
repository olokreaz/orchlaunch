# OrchLaunch configuration layer

Configuration is split by responsibility. `config.lua` owns JSON I/O,
factories and serialization; `state.lua` owns the single loaded project and
the API every other module uses. No other module parses JSON directly.

```text
.orch/
├── run_configurations.json
├── external_tools.json
├── toolchain.json
└── cmake_settings.json
```

## Toolchains — `toolchain.json`

```json
{
  "toolchains": [
    {
      "name": "Clang",
      "type": "system",
      "cmake": "cmake",
      "c": "clang",
      "cxx": "clang++",
      "debugger": "lldb",
      "environment": { "CCACHE_DIR": "${workspace}/.ccache" }
    }
  ]
}
```

Tool paths may be command names (resolved from `PATH`), absolute paths, or
paths relative to `.orch`. `gdb` and `lldb` are recognized as debuggers.
`environment` is inherited by CMake configure/build/test/install and by
run/debug; the active profile or run configuration overrides it on key
collisions. The toolchain `debugger` is the default for native configurations;
a configuration can still select its own adapter where one is supported.

## CMake profiles — `cmake_settings.json`

CLion-style CMake profiles: several named ways to configure/build the project,
each with its own toolchain, presets, generator, directories, args and
environment. Exactly one profile is active; Run/Debug, the build/install
before-launch steps and target loading all use it. References a toolchain by
name; never duplicates compiler paths.

```json
{
  "cmake": {
    "active": "Debug",
    "source_dir": "${workspace}/boo",
    "profiles": [
      {
        "name": "Debug",
        "toolchain": "Clang",
        "configure_preset": "debug",
        "build_preset": "debug-build",
        "test_preset": "tests",
        "build_type": "Debug"
      },
      {
        "name": "Release",
        "toolchain": "Gcc",
        "generator": "Ninja",
        "build_type": "Release",
        "build_dir": "${workspace}/build/release",
        "definitions": { "CMAKE_EXPORT_COMPILE_COMMANDS": "ON" }
      }
    ]
  }
}
```

A legacy flat `cmake` object (the single-settings form, without `profiles`) is
read as one profile named `Default`, so existing projects keep working.

### The CMake project — `cmake.source_dir`

`source_dir` is project-wide (not per profile) and names the **CMake project**:
the directory holding `CMakeLists.txt` and `CMakePresets.json`. It resolves like
any path (e.g. `${workspace}/boo`), so the `.orch` project can live in a parent
directory while the CMake project lives in a subdirectory. It defaults to the
`.orch` project root.

It drives the configure `-S`, the working directory, the base for a relative
`build_dir`, and where presets are discovered. `:OrchLaunchLoadCMake` loads the
targets of *that* CMake project and caches them against it, so changing
`source_dir` (or the file/interactively via `:OrchLaunchCMakeProject` or **Project
(p)** in the profile manager) drops any previously loaded targets.

When a `*_preset` is set the corresponding manual fields are ignored: configure
uses `cmake --preset`, build uses `cmake --build --preset`, test uses
`ctest --preset`. The manual fields remain the fallback when no preset is
selected.

## CMake presets — `CMakePresets.json`

`CMakePresets.json` and `CMakeUserPresets.json` are read from the CMake project
directory (`cmake.source_dir`, default the project root).
`include` directives are followed recursively and presets are resolved through
`inherits` (dict fields such as `cacheVariables` and `environment` are merged;
arrays are replaced; `hidden` presets are resolvable but never offered in the
UI). `CMakeUserPresets.json` overrides `CMakePresets.json`.

Importing presets is explicit: `:OrchLaunchImportCMakePresets` (or **Import
presets** in the profile manager) creates one **disabled** profile per visible
configure preset and one per visible build preset. A build-preset profile
records its `build_preset` and the configure preset it resolves to; its name is
disambiguated (`<name> (build)`) only on collision. Importing again adds nothing.

The profile manager (`:OrchLaunchCMake`) is a list with **New** (`a`), **Edit**
(`e`), **Delete** (`D`), **Toggle** (`t`, enable/disable), **Set active** (`A`),
**Import** (`i`) and **Project** (`p`, edit the CMake project directory).
Choosing **Set active** enables the profile.

The editor is a fibrous form. Move with `Tab`/`Shift+Tab` (or `s` to jump to a
field by letter), press `<CR>` to edit the focused field, `<Space>` to toggle
booleans, `<C-s>` to save and `q`/`<Esc>` to close. Sections (Profile, Build,
Toolchain, Arguments, Variables) are laid out in two columns.

Manual profiles expose every field — name, enabled, toolchain, generator, build
type, directories, **test preset**, args, definitions and environment — and
never reference configure/build presets. A new profile is pre-filled with `generator = "Ninja"` and
`build_type = "Debug"`; the generator select lists the common CMake generators
(and keeps a custom value if one was set).

Preset-derived profiles are **read-only**: they are imported from
`CMakePresets.json` / `CMakeUserPresets.json` (and their includes) and cannot be
created or edited here — only viewed. Change the preset file and re-import
instead.

The active profile's configure preset's `binaryDir` (after macro expansion)
becomes the build directory; otherwise the profile's `build_dir` applies,
defaulting to `<source>/build`.

Macros supported in preset values: `$env{VAR}`, `$penv{VAR}`,
`${sourceDir}`, `${sourceParentDir}`, `${sourceDirName}`, `${fileDir}`,
`${presetName}`, `${hostSystemName}`, `${pathListSep}`, `${dollar}`.

The project toolchain is applied to a configure preset only when the preset
does **not** already define `CMAKE_C_COMPILER` / `CMAKE_CXX_COMPILER` /
`CMAKE_TOOLCHAIN_FILE` or a `toolchainFile`; in that case
`-DCMAKE_C_COMPILER` / `-DCMAKE_CXX_COMPILER` are injected from the toolchain
(the configured one, else the first defined).

## Loading targets

Run `:OrchLaunchLoadCMake` (or press `m` / the **Load CMake** button in the
browser) to configure the
project and discover its targets. Targets are read through the CMake File API
(`codemodel-v2`): the plugin drops a query in
`<build>/.cmake/api/v1/query/client-orchlaunch/` before configuring, then reads
the codemodel reply for target names, types and built-artifact paths. The result
is cached in runtime data (discarded on reload).

The last File API reply already present in the build directory is also used as a
fallback: when a reconfigure fails (for example a missing toolchain or
`VCPKG_ROOT`), and automatically when opening a configuration editor in a fresh
session. Previously discovered targets therefore stay available without
reconfiguring. A warning is shown with the configure error on a failed
reconfigure.

Once targets are known, the **Target** field of native (and the **Symbol** field
of remote-debug) configurations becomes a picker: a CMake-target select plus a
free-form executable-path field (`(executable path…)`). Choosing a target stores
its name; running it resolves to the artifact path reported by CMake, falling
back to a filesystem search in the build directory.

Loading targets also creates a native run configuration for every CMake
target the File API reports — executables, static/shared/module/object
libraries and custom targets. The configuration is named after the target, its
working directory is the CMake build directory and its `runtime` records the
target kind (`executable`, `static`, `shared`, `module`, `object`, `utility`,
...). Executables set `target` to the target name; every other kind has no
executable, so its `target` stays empty. All configurations get a build step
for **their own target** before launch by default (CLion style); running such a
configuration executes its build steps and nothing else. Existing configurations are never
touched — a configuration created by hand before the File API is parsed
keeps its runtime and executable — and each new configuration is saved
immediately, so this is safe to run repeatedly.

### Building and running targets

`:OrchLaunchTargets` (or `t` in the run browser) opens the **CMake Targets**
browser. It shows each target's type and artifact, and provides:

| Key | Action |
| --- | --- |
| `b` | Build this target |
| `r` | Run it (creates its native configuration on demand) |
| `d` | Debug it |
| `e` | Edit/create its native configuration |

The corresponding project-wide commands use the active profile:

- `:OrchLaunchConfigure` — configure only;
- `:OrchLaunchBuild [target]` — build everything or one target;
- `:OrchLaunchRebuild [target]` — clean, then build;
- `:OrchLaunchClean` — run the build tool's `clean`;
- `:OrchLaunchInstall [target]` — configure/build/install;
- `:OrchLaunchTest` — configure, build and run CTest (uses `test_preset` when
  set, otherwise manual test arguments).

CMake output is parsed into the standard quickfix list for every action.

## Run configurations — `run_configurations.json`

One configuration is used for both Run and Debug. There is no separate
`Game Debug` entry.

```json
{
  "configurations": [
    {
      "name": "Game",
      "type": "native",
      "runtime": "executable",
      "target": "game",
      "args": ["-dev", "-console"],
      "console": { "mode": "embedded", "keep_open": true, "clear_on_start": true },
      "before": { "tools": ["build", { "type": "external", "tool": "gen-assets" }] }
    }
  ]
}
```

Supported types: `native`, `remote-debug`, `compound`. For `native`, `runtime`
records the CMake target kind (`executable`, `static`, `shared`, `module`,
`object`, `utility`, ...); only executables have a `target`.

## External tools — `external_tools.json`

```json
{
  "tools": [
    {
      "name": "gen-assets",
      "program": "${workspace}/tools/gen",
      "cwd": "${workspace}",
      "args": ["--release"]
    }
  ]
}
```

## UI

By default (`ui.backend = "buffer"`) OrchLaunch has no windows of its own for
configuration: the `.orch/*.json` files are edited as **plain JSON buffers**, so
highlighting, folding, undo and your other plugins just work. Lists and choices
go through `vim.ui.select` / `vim.ui.input`, which means telescope, snacks,
fzf-lua or dressing show them if you use one of those. `fibrous.nvim` is only
needed for the optional `ui.backend = "fibrous"` browser (`:OrchLaunch` then
opens the old list + details dialog).

### Editing

| Command | What it does |
| --- | --- |
| `:OrchLaunchEdit` | Pick a file (configurations, tools, toolchains, CMake profiles) |
| `:OrchLaunchEdit configs` | Pick an entry or *Open whole file*; opens the file with the cursor on the entry |
| `:OrchLaunchEdit configs My Config` | Jump straight to the entry (the name may contain spaces) |
| `:OrchLaunchEdit tools\|toolchain\|cmake\|breakpoints [entry]` | Same for the other files |
| `:OrchLaunchNew [type]` | Create an entry: `native`, `remote-debug`, `compound`, `external_tool`, `toolchain`, `cmake_profile` |
| `:OrchLaunchRunHere` | Run the configuration under the cursor (in `run_configurations.json`) |

Saving a file reloads the project state and re-validates it. A file you edit by
hand is never overwritten by the plugin.

### Pickers

| Command | Effect of choosing an entry |
| --- | --- |
| `:OrchLaunchSelect[Config\|Debug]` | Run / debug the configuration |
| `:OrchLaunchSelectProfile [configure\|build]` | Make it the active CMake profile |
| `:OrchLaunchSelectPreset [configure\|build]` | Activate the profile that wraps the preset (or tell you to import presets) |
| `:OrchLaunchSelectTool` | Run the external tool |
| `:OrchLaunchToolchains`, `:OrchLaunchExternalTools`, `:OrchLaunchCMake` | Open the file at that entry |

### Diagnostics

Besides the JSON Schema checks done by `jsonls`, OrchLaunch reports what a
schema cannot express, with the exact line: duplicate names (every occurrence),
unknown CMake targets (a hint while no CMake model is loaded), unknown
toolchains / profiles / external tools, compound cycles (with the chain) and
unknown children, `sudo` with a `hidden`/`none` console, empty native
configurations, `remote-debug` without a connection, missing toolchain / tool
fields and syntax errors. Validation runs on write and, debounced, while you
type; it never starts a process.

For native configurations the editor shows, at the end of the line, what the
`target` resolves to (the executable, *target not built yet* or *target not
found*).

### Schemas and jsonls

`schemas/*.schema.json` describe the four files. When `jsonls`
(`vscode-json-language-server`, package `vscode-langservers-extracted`)
attaches to a buffer inside `.orch/`, the schemas are added to its settings
next to the ones you already configured, giving completion, hover text and
structure checks. `:OrchLaunchCheck` reports whether it is installed, running
and has the schemas.

### Options

```lua
require("orchlaunch").setup({
  jsonls = true,              -- register the schemas with jsonls
  write_schema_ref = false,   -- add a "$schema" URL (raw GitHub) when writing
  ui = {
    backend = "buffer",       -- "buffer" | "fibrous"
    edit = {
      window = "split",       -- "split" | "vsplit" | "float" | "tab"
      fold_others = false,    -- fold the other entries (this window only)
    },
    virtual_text = true,      -- show what a native target resolves to
  },
})
```

`ui.edit_window` and `ui.fold_others` are accepted as aliases.

### The fibrous browser

With `ui.backend = "fibrous"`, `:OrchLaunch` opens the Run/Debug Configurations
browser with these keys:

| Key | Action |
| --- | --- |
| `<Tab>` / `<S-Tab>` | Move focus |
| `j` / `k` | Move in the list |
| `r` / `d` | Run / Debug the selected configuration |
| `e` / `a` / `y` / `D` | Edit / New / Duplicate / Delete |
| `A` | Set as the active configuration |
| `m` | Load the CMake project (configure + discover targets) |
| `<Esc>` | Close |

The active configuration is remembered per project (outside `.orch`, in
Neovim's state directory) and is what `:OrchLaunchRun` / `:OrchLaunchDebug`
use when no name is given.

## Debugging

Debug sessions run through `nvim-dap`. Two backends are bundled: LLDB
(`lldb-dap`/`lldb-vscode`) and GDB (`gdb --interpreter=dap`). Choose per
configuration with `adapter = "lldb"` or `"gdb"`; `native` configurations launch
and `remote-debug` configurations attach (`connection = "host:port"`, e.g. after
`lldb-server gdbserver :1234 -- ./prog`).

`:OrchLaunchDebugger` delegates to **nvim-dap-view** (or nvim-dap-ui) when it is
installed, which adds watches, REPL/console, exceptions and expandable scopes.
Without those plugins the built-in fibrous panel is used: threads, frames,
scopes and variables with Continue/Pause/Step Over/In/Out/Restart/Stop/Toggle BP
controls, re-rendered on session events.

CMake configure/build/install and external-tool steps run asynchronously, so
Neovim stays responsive; `:OrchLaunchCancel` stops the active step. Their output
is parsed into the standard **quickfix**
list (`OrchLaunch: CMake <step>`), so existing quickfix UIs — trouble.nvim,
snacks.nvim, `:copen` — show compiler diagnostics without OrchLaunch-specific
code. Breakpoints support conditions and log points
and persist per project in `.orch/breakpoints.json`:

- `:OrchLaunchToggleBreakpoint` — toggle at the cursor;
- `:OrchLaunchBreakpoint <expr>` — conditional breakpoint;
- `:OrchLaunchLogBreakpoint <msg>` — log point;
- `:OrchLaunchBreakpoints` / `:OrchLaunchClearBreakpoints` — manage all.

Known limits: attaching to an existing PID may be blocked by
`kernel.yama.ptrace_scope`; GDB remote-attach to `gdbserver` is not supported
(LLDB attach is).

## Commands

| Command | Description |
| --- | --- |
| `:OrchLaunch` | Pick and run a configuration (fibrous browser with `ui.backend = "fibrous"`) |
| `:OrchLaunchSelect [name]` | Set the active configuration |
| `:OrchLaunchRun [name]` | Run a configuration (active when omitted) |
| `:OrchLaunchDebug [name]` | Debug a configuration (active when omitted) |
| `:OrchLaunchEdit [file [entry]]` | Edit a configuration file as a JSON buffer (see *UI*) |
| `:OrchLaunchNew [type]` | Create a configuration, tool, toolchain or profile |
| `:OrchLaunchRunHere` | Run the configuration under the cursor |
| `:OrchLaunchToolchains` | Manage toolchains |
| `:OrchLaunchExternalTools` | Manage external tools |
| `:OrchLaunchExternalTool <name>` | Run an external tool |
| `:OrchLaunchCMake` | Manage CMake profiles |
| `:OrchLaunchCMakeProject` | Set the CMake project directory (`cmake.source_dir`) |
| `:OrchLaunchImportCMakePresets` | Import CMake presets as disabled profiles |
| `:OrchLaunchLoadCMake` | Configure the project and load its CMake targets |
| `:OrchLaunchTargets` | Browse CMake targets |
| `:OrchLaunchConfigure` | Configure with the active CMake profile |
| `:OrchLaunchBuild [target]` | Build the project or a single target |
| `:OrchLaunchRebuild [target]` | Clean and rebuild |
| `:OrchLaunchClean` | Clean build outputs |
| `:OrchLaunchInstall [target]` | Configure, build and install |
| `:OrchLaunchTest` | Build and run the CTest suite |
| `:OrchLaunchCancel` | Cancel the running CMake or external-tool step |
| `:OrchLaunchCreateProject [dir]` | Create a `.orch` project |
| `:OrchLaunchReload` | Reload all `.orch` files |
| `:OrchLaunchDebugger` | Open the debugger UI (dap-view/dap-ui, fibrous fallback) |
| `:OrchLaunchToggleBreakpoint` | Toggle a breakpoint at the cursor |
| `:OrchLaunchBreakpoint <expr>` | Set a conditional breakpoint at the cursor |
| `:OrchLaunchLogBreakpoint <msg>` | Set a log point at the cursor |
| `:OrchLaunchBreakpoints` | Manage breakpoints |
| `:OrchLaunchClearBreakpoints` | Clear all breakpoints |
| `:OrchLaunchCheck` | Check tools and integrations |

Executing Run/Debug supports native configurations, external before-launch
tools, and `build` / `install` before-launch steps, which run CMake configure
then build (then install) before the program starts. A native `target` that is
not a path is resolved to a built executable using the CMake File API artifact
(see *Loading targets*), falling back to a search in the build directory.
Debug sessions go through nvim-dap; see *Debugging* below.

## API

```lua
local orch = require("orchlaunch")

-- Registers commands, watches DirChanged and loads the current project.
orch.setup({ silent = true })
-- Or create it:
orch.create_project("/path/to/project")

local state = require("orchlaunch.state")
local config = require("orchlaunch.config")

state.add_toolchain(config.toolchain({ ... }))
state.add_configuration(config.native({ name = "Game", target = "game" }))
state.add_external_tool(config.external_tool({ name = "gen", program = "gen" }))

state.save()
state.reload()

-- UI / execution entry points.
orch.open()                     -- browser
orch.select("Game")             -- set active
orch.run()                      -- run active
orch.debug("Attach")            -- debug a configuration
```

Runtime data (resolved executables, discovered CMake targets) is kept in a
separate store (`state.runtime`) that is never serialized to disk.


---

# Technical implementation


## Full feature list

The plugin provides a complete CLion-like run/debug configuration system for Neovim:

### Core capabilities
- Project discovery: `.orch/` directory detection from cwd or given root.
- Per-project isolated state (run configs, external tools, toolchains, CMake settings).
- JSON storage via Neovim's built-in `vim.json` (no external parser): deterministic pretty-printing with sorted object keys; empty tables round-trip.
- Runtime data separated from persisted data (`state.runtime`, never serialized; cleared on reload).
- Path resolution: relative paths resolved against `.orch/`, `${workspace}`, `${orch}` expansion via context.
- Tool resolution: finds executables in PATH or from toolchain.
- Environment expansion and merge with inheritance.

### Configuration types
- Native: run a program (path or CMake target), with working directory, args, env, stdin/stdout/stderr, console mode (embedded/external/hidden), and before-launch steps.
- Remote-debug: attach to a remote process via `connection` (host:port) and `symbol` (executable path), adapter (gdb/lldb), and before-launch steps. Attach requests do not use `cwd`, `args` or `env`.
- Compound: run multiple configurations in order.

### Before-launch steps
- Build (CMake build) — runs `cmake --build` with active profile/preset or manual settings.
- Install (CMake install) — runs `cmake --install`.
- External tool — runs a named external tool from `external_tools.json`.
- Custom command — runs an arbitrary program+args with cwd/env.

### Console modes
- embedded: runs in Neovim terminal (termopen)
- external: spawns detached external terminal
- hidden: background process, stdout/stderr captured

### External tools
- Named external tools with program, args, cwd, env, sudo, inherit_env.
- Can be invoked standalone or as before-launch step.
- Managed via UI list (New/Edit/Delete) or commands.

### Toolchains
- System/toolchain definitions (type, cmake, c/cxx, debugger, env).
- Referenced by name from CMake profiles and used to populate CMake compiler args when presets don't specify compilers.
- Applied only when preset has no `CMAKE_C_COMPILER`/`CMAKE_CXX_COMPILER`/`toolchainFile`.

### CMake integration
- Multiple CMake profiles (CLion-style) stored in `cmake_settings.json` under `cmake` (`active` + `profiles` array).
- Project-wide CMake project directory: `cmake.source_dir` (defaults to `.orch` root) — directory containing `CMakeLists.txt` and `CMakePresets.json`. Drives -S, cwd, preset discovery, build dir base, and target cache scoping.
- Preset-derived profiles: one per visible configure preset and one per visible build preset (disabled by default), created via explicit import (`:OrchLaunchImportCMakePresets` or `i` in manager). Build preset profile stores `build_preset` + resolved `configure_preset`, name disambiguated on collision.
- Active profile determines effective settings; Set Active enables it automatically.
- Presets discovery: reads `CMakePresets.json` and `CMakeUserPresets.json` from CMake project directory, follows `include`, resolves `inherits`, merges dict fields (cacheVars/env), replaces arrays, hides `hidden` presets from UI.
- Configure/build/test via presets or manual: uses `cmake --preset`, `cmake --build --preset`, `ctest --preset` when preset specified; otherwise manual args (-S/-B/-G/-DCMAKE_BUILD_TYPE, definitions).
- Toolchain injection into presets only when preset doesn't define compilers/toolchainFile.
- Macro expansion in preset values: `$env{VAR}`, `$penv{VAR}`, `${sourceDir}`, `${sourceParentDir}`, `${sourceDirName}`, `${fileDir}`, `${presetName}`, `${hostSystemName}`, `${pathListSep}`, `${dollar}`.
- Binary dir resolution: from configure preset `binaryDir` (expanded, relative to source_dir) else manual `build_dir` else `<source>/build`.
- CMake File API target discovery: writes query to `<build>/.cmake/api/v1/query/client-orchlaunch/codemodel-v2` before configure, reads codemodel reply to extract target names/types and artifact paths. Results cached in runtime (`cmake_targets`, `cmake_source_dir`, `cmake_binary_dir`). Cache invalidated on reload, source_dir change, or CMake settings changes.
- Target resolution for native/remote: prefer File API artifact (absolute/relative resolved), fallback to filesystem search in build dir for common names.
- Legacy flat `cmake` object auto-migrated to single profile named `Default`.

### UI (fibrous)
- The whole UI is built on [`fibrous.nvim`](https://github.com/mbrea-c/fibrous.nvim). `ui/fibrous/form.lua` provides the shared form scaffolding (state, `<C-s>` save, close, `.orch` test hooks) and `ui/fibrous/fields.lua` the continuous keyboard navigation: `Tab`/`Shift+Tab` step between fields, `s` jumps by letter, `<CR>` enters a field, `<Esc>` leaves a single-line field.
- Browser (`ui/fibrous/browser.lua`): configurations with an active marker, details pane, actions (`r` run, `d` debug, `e` edit, `a` new, `y` duplicate, `D` delete, `A` set active, `m` load CMake, `t` targets, `q`/`<Esc>` close) and hints for the CMake/toolchain managers.
- CMake Targets browser (`ui/fibrous/targets.lua`): every discovered target with artifact details and build/run/debug/edit-config actions.
- Editors per type: native/remote/compound/toolchain/external tool/CMake project, all using the same form scaffolding.
- CMake profile editor (`ui/fibrous/cmake_profile.lua`): manual profiles are fully editable; preset-derived profiles are read-only (imported from the preset JSON files and never created by hand). It keeps a `.orch` scripting facade (`fields`, `values`, `set`, `save`, `close`) for the tests.
- List dialogs (`ui/fibrous/list.lua` plus the specs in `ui/dialogs/`): generic list with a details pane and actions (New/Edit/Delete/Toggle/Set Active/Import/Project; `a,e,D,t,A,i,p`).
- Project-wide CMake project editor accessible via `p` in the CMake profiles manager or `:OrchLaunchCMakeProject`.

### Commands
- `:OrchLaunch` / `:OrchLaunchBrowser` — open browser
- `:OrchLaunchRun [name]` — run configuration
- `:OrchLaunchDebug [name]` — debug configuration
- `:OrchLaunchSelect <name>` — set active
- `:OrchLaunchReload` — reload all .orch files
- `:OrchLaunchCreateProject [dir]` — create .orch project
- `:OrchLaunchToolchains` — manage toolchains
- `:OrchLaunchExternalTools` — manage external tools
- `:OrchLaunchExternalTool <name>` — run external tool
- `:OrchLaunchCMake` — manage CMake profiles
- `:OrchLaunchCMakeProject` — set CMake project directory (cmake.source_dir)
- `:OrchLaunchImportCMakePresets` — import CMake presets as disabled profiles
- `:OrchLaunchLoadCMake` — configure and load CMake targets
- `:OrchLaunchTargets` — browse CMake targets
- `:OrchLaunchConfigure` / `:OrchLaunchBuild [target]` / `:OrchLaunchRebuild [target]` — configure and build
- `:OrchLaunchClean` / `:OrchLaunchInstall [target]` / `:OrchLaunchTest` — clean, install and CTest
- `:OrchLaunchDebugger` — open the debugger UI (dap-view/dap-ui when available)
- `:OrchLaunchToggleBreakpoint` / `:OrchLaunchBreakpoint` / `:OrchLaunchLogBreakpoint` — breakpoints
- `:OrchLaunchBreakpoints` / `:OrchLaunchClearBreakpoints` — manage breakpoints
- `:OrchLaunchCheck` — check tools and integrations

### API
- `orch.setup(opts)` — load project at root or locate .orch
- `orch.create_project(dir)` — create .orch scaffolding
- `orch.open()` — open browser
- `orch.select(name)` — set active configuration
- `orch.run(name?)` — run configuration (active if omitted)
- `orch.debug(name?)` — debug configuration
- `orch.reload()` — reload project state

### Process execution
- Uses `vim.system` (or termopen for embedded console). Never builds shell strings — program + args passed separately.
- Environment merging: base env + toolchain env + config env + preset env + resolved variables. Inherit_env respected.
- sudo support (external tools/configs where applicable). Paths resolved before execution.
- Console modes: embedded opens terminal buffer named `orchlaunch://run/<name>`, external spawns terminal via `config.terminal_cmd`.
