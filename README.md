# OrchLaunch

> [!NOTE]
> This plugin was built with **AI** — pure ✨ **vibe coding** ✨ energy, no plan,
> no spec, just good vibes and `:wq`. Use at your own vibe.

A CLion-style **Run/Debug configuration** system for Neovim: named run
configurations, toolchains, external tools, CMake profiles/presets and CMake
target discovery — driven from JSON files inside a `.orch` project.

```
:OrchLaunch
┌ Run / Debug Configurations ──────────────────────────────────────────────┐
│  Configurations        │  Details                                         │
│  ● launcher_main       │  Name:  launcher_main                            │
│                        │  Type:  native                                   │
│                        │  Target:  launcher_main                          │
│                        │  Working dir:  …/build/linux-debug               │
│                        │  Console:  embedded                              │
│                        │                                                  │
│  Run(r) Debug(d) Edit(e) New(a) Duplicate(y) Delete(D) Set Active(A)      │
│  Toolchains… External Tools… CMake… Load CMake(m) Close                  │
└──────────────────────────────────────────────────────────────────────────┘
```

## Features

- **Run configurations** — one entry per runnable thing, used for both Run and
  Debug. Types: `native`, `remote-debug`, `compound`.
- **Native run** — embedded/external console, program arguments, environment,
  working directory, `sudo`, and before-launch steps (build / install /
  external tools).
- **Toolchains** — C/C++/CMake/debugger paths and environment, referenced by
  name so configurations never duplicate compiler paths. The toolchain debugger
  is the default for native configurations.
- **CMake profiles** — several named ways to configure/build a project
  (toolchain, generator, configure/build/test presets, directories, args, env);
  exactly one active.
- **CMake actions and targets** — configure, build a single target, rebuild,
  clean, install and run CTest from commands; browse every discovered target
  with build/run/debug/edit actions.
- **CMake presets** — reads `CMakePresets.json` / `CMakeUserPresets.json`,
  resolves `inherits` and `include`, expands macros, and can import presets as
  disabled profiles.
- **CMake target discovery** — via the CMake File API (`codemodel-v2`), with
  automatic native run configurations for every target (executables,
  static/shared/module/object libraries and custom targets).
- **Build diagnostics** — compiler errors go to the standard **quickfix** list,
  so trouble.nvim, snacks.nvim and `:copen` render them; no custom diagnostics
  viewer.
- **Run/Debug browser** — a [fibrous.nvim](https://github.com/mbrea-c/fibrous.nvim)-based UI
  for the list, details and every manager, backed by plain JSON on disk.
  **Now optional** — the new default UI uses plain JSON buffers with `vim.ui.select`.
- **JSON Schema & validation** — autocompletion, hover docs, and semantic
  validation (unknown targets, missing toolchains, cycles, etc.) via
  `jsonls` (vscode-json-language-server).
- **Active configuration** — remembered per project (outside `.orch`).

## Debugging

Debug sessions run through [nvim-dap](https://github.com/mfussenegger/nvim-dap).
OrchLaunch ships two backends — LLDB (`lldb-dap`/`lldb-vscode`) and GDB
(`gdb --interpreter=dap`) — selected per configuration (`adapter = "gdb"` or
`"lldb"`). `native` configurations launch, `remote-debug` attaches (e.g. start
`lldb-server gdbserver :1234 -- ./prog`, then set `connection = "host:port"`).

- **Debugger UI** — `:OrchLaunchDebugger` opens **nvim-dap-view** (or
  nvim-dap-ui) when installed; without them it falls back to the built-in
  fibrous panel with threads, frames, scopes, variables and stepping controls.
- **Breakpoints** — toggle with `:OrchLaunchToggleBreakpoint`, add a condition
  with `:OrchLaunchBreakpoint <expr>`, a log point with
  `:OrchLaunchLogBreakpoint <msg>`, and manage them all with
  `:OrchLaunchBreakpoints`. They persist per project in `.orch/breakpoints.json`.

If nvim-dap is not installed, OrchLaunch notifies accordingly.

## Requirements

- Neovim ≥ 0.10 (uses `vim.system`, `vim.json`, `vim.fs`)
- [fibrous.nvim](https://github.com/mbrea-c/fibrous.nvim) (optional — for the classic UI)
- CMake on `PATH` (or configured per toolchain) for the CMake features
- Optional: [nvim-dap](https://github.com/mfussenegger/nvim-dap) plus `lldb-dap`
  or `gdb` for debugging
- Optional: [vscode-langservers-extracted](https://github.com/hrsh7th/vscode-langservers-extracted)
  for JSON Schema autocompletion and validation (`jsonls`)

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "olokreaz/orchlauncher.git",
  dependencies = {
    "mbrea-c/fibrous.nvim",  -- optional
  },
  config = function()
    require("orchlaunch").setup({ silent = true })
  end,
}
```

`setup()` registers the user commands, watches `DirChanged` and loads the
`.orch` project containing the current directory. Options:

```lua
require("orchlaunch").setup({
  root = nil,     -- workspace root to search for .orch (default: cwd)
  silent = true,  -- don't warn when no .orch project is found
  jsonls = true,  -- auto-register JSON Schemas with jsonls (default: true)
  write_schema_ref = false, -- add "$schema" to files on save (default: false)
  ui = {
    backend = "buffer",  -- "buffer" (default) or "fibrous"
    edit = {
      window = "float",  -- "split" | "vsplit" | "float" | "tab"
      fold_others = false,
      close_on_write = true, -- floats close themselves after :w
    },
    virtual_text = true, -- show resolved executable path in run_configurations.json
  },
})
```

## Quick start

```vim
:OrchLaunchCreateProject          " create .orch in the current directory
:OrchLaunch                       " open the Run/Debug browser
```

Then, in the browser (fibrous backend) or via `:OrchLaunchSelectConfig` (buffer backend):

1. **Toolchains…** — add a toolchain (compiler/cmake/debugger).
2. **CMake…** — create/select a CMake profile (or **Import** presets).
3. **Load CMake (m)** — configure and discover CMake targets; native run
   configurations are created for every target and build before launch by
   default. Executables point at their artifact; libraries and custom targets
   keep the executable field empty.
4. **New (a)** — add a configuration, pick a target, save with `<C-s>`.
5. **Run (r)** — run the active/selected configuration.

Everything is stored as JSON under `.orch/`, so it can be reviewed and
committed:

```text
.orch/
├── run_configurations.json
├── external_tools.json
├── toolchain.json
├── cmake_settings.json
└── breakpoints.json
```

## JSON Schema & Language Server Integration

OrchLaunch ships JSON Schemas for all configuration files in `schemas/`:

- `run_configurations.schema.json`
- `external_tools.schema.json`
- `toolchain.schema.json`
- `cmake_settings.schema.json`

When `jsonls` (vscode-json-language-server) attaches to a buffer inside
`.orch/`, OrchLaunch automatically registers the schemas. This gives you:

- **Autocompletion** — field names, enum values (config types, console modes, toolchain types)
- **Hover documentation** — descriptions for every field
- **Validation** — JSON structure errors inline

### Installing jsonls

**Arch Linux:**
```bash
sudo pacman -S vscode-langservers-extracted
```

**npm (cross-platform):**
```bash
npm install -g vscode-langservers-extracted
```

Then ensure `jsonls` is in your PATH and configured in Neovim (via `nvim-lspconfig` or `vim.lsp.config`).

### Manual Schema Setup

If you don't use OrchLaunch's auto-registration, add to your `jsonls` config:

```lua
require('lspconfig').jsonls.setup({
  settings = {
    json = {
      schemas = {
        { fileMatch = { "**/.orch/run_configurations.json" }, url = "https://raw.githubusercontent.com/olokreaz/orchlaunch/master/schemas/run_configurations.schema.json" },
        { fileMatch = { "**/.orch/external_tools.json" }, url = "https://raw.githubusercontent.com/olokreaz/orchlaunch/master/schemas/external_tools.schema.json" },
        { fileMatch = { "**/.orch/toolchain.json" }, url = "https://raw.githubusercontent.com/olokreaz/orchlaunch/master/schemas/toolchain.schema.json" },
        { fileMatch = { "**/.orch/cmake_settings.json" }, url = "https://raw.githubusercontent.com/olokreaz/orchlaunch/master/schemas/cmake_settings.schema.json" },
      }
    }
  }
})
```

### $schema Reference

Add a `$schema` property to your config files for schema support in any editor:

```json
{
  "$schema": "https://raw.githubusercontent.com/olokreaz/orchlaunch/master/schemas/run_configurations.schema.json",
  "configurations": [...]
}
```

OrchLaunch can auto-add this on save with `setup({ write_schema_ref = true })`.

## Configuration files

### Toolchains — `toolchain.json`

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

Paths may be command names (resolved from `PATH`), absolute paths, or paths
relative to `.orch`. A toolchain `environment` is inherited by CMake
configure/build/test/install and by run/debug; the active profile or run
configuration wins on key collisions. `debugger` is the default adapter for
native configurations.

### CMake profiles — `cmake_settings.json`

```json
{
  "cmake": {
    "active": "Debug",
    "source_dir": "${workspace}/engine",
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
        "build_dir": "${workspace}/build/release",
        "definitions": { "CMAKE_EXPORT_COMPILE_COMMANDS": "ON" }
      }
    ]
  }
}
```

Exactly one profile is active; Run/Debug, before-launch build/install steps and
target loading all use it. When a `*_preset` is set the corresponding manual
fields are ignored (`cmake --preset`, `cmake --build --preset`, `ctest
--preset`). A legacy flat `[cmake]` table is read as a single `Default` profile.
The **Test preset** field is available for manual profiles and drives
`:OrchLaunchTest`.

`source_dir` names the CMake project (the directory holding `CMakeLists.txt`
and `CMakePresets.json`), resolved like any path. The configure `-S`,
working directory, base for a relative `build_dir` and preset discovery all
follow it.

### Run configurations — `run_configurations.json`

```json
{
  "configurations": [
    {
      "name": "Game",
      "type": "native",
      "target": "game",
      "args": ["-dev", "-console"],
      "cwd": "${workspace}/build",
      "console": { "mode": "embedded", "keep_open": true, "clear_on_start": true },
      "before": { "tools": ["build", "install", { "type": "external", "tool": "gen-assets" }] }
    }
  ]
}
```

`target` is a CMake target name or an executable path; `console.mode` is
`embedded`, `hidden` or `none`. Supported types: `native`, `remote-debug`,
`compound` (runs child configurations in order).

### External tools — `external_tools.json`

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

## CMake target discovery

`:OrchLaunchLoadCMake` (or `m` / **Load CMake**) requests a `codemodel-v2` reply
from the CMake File API (`<build>/.cmake/api/v1/query/client-orchlaunch/`) and
reads back target names, types and artifact paths.

- The **Target** field of native (and the **Symbol** field of remote-debug)
  configurations becomes a picker: a select of CMake targets plus a free-form
  executable path. Running a target resolves to the built artifact, falling back
  to a filesystem search in the build directory.
- The **last File API reply on disk is reused** when a reconfigure fails (e.g. a
  missing toolchain) and automatically in a fresh session, so targets stay
  available without reconfiguring.
- Loading targets **creates a native run configuration for every target** that
  does not have one yet (name = target, cwd = build directory), including
  static/shared/module/object libraries and custom targets. Executables set
  `target` to the target name; every other kind leaves it empty and records
  `runtime` (`static`, `shared`, `module`, `object`, `utility`, ...). Each
  configuration gets a **Build before launch** action for its own target by
  default, like CLion. Running a configuration without an executable just
  performs its build steps. Existing configurations (including hand-made ones)
  are never touched and their runtime is preserved.
- `:OrchLaunchTargets` (or `t` in the browser) opens the **CMake Targets**
  browser with artifact details and `b`/`r`/`d`/`e` actions for build, run,
  debug and edit-config.

## Buffer-based Editing (New Default UI)

The new default UI edits configuration files as plain JSON buffers:

- **`:OrchLaunchEdit [configs|tools|toolchain|cmake|breakpoints]`** — opens the file in a floating window (`ui.edit.window`). Without arguments, prompts which file. With a file type, opens that file; you can then pick a specific entry (e.g. a configuration name) to jump to it.
- **`:OrchLaunchNew [native|remote-debug|compound|external_tool|toolchain|cmake_profile]`** — creates a new entry with sensible defaults, saves it, and opens the file at the new entry.
- **JSON Schema** — autocompletion and validation via `jsonls`.
- **Semantic validation** — OrchLaunch adds its own diagnostics (via `vim.diagnostic`) for things JSON Schema can't express: unknown CMake targets, missing toolchains, compound cycles, duplicate names, sudo with hidden/none console, etc.
- **Virtual text** — in `run_configurations.json`, native configurations show the resolved executable path as virtual text at the end of the line (toggle with `ui.virtual_text`).
- **Window style** — `ui.edit.window = "split" | "vsplit" | "float" | "tab"` (default `float`). Floating editors close on `:w` (`ui.edit.close_on_write`, default on) and with `q`/`<Esc>`; set `close_on_write = false` to keep them open.

### New Commands

| Command | Description |
| --- | --- |
| `:OrchLaunchEdit [configs\|tools\|toolchain\|cmake\|breakpoints]` | Open a configuration file for editing |
| `:OrchLaunchNew [type]` | Create a new configuration entry |
| `:OrchLaunchSelectConfig` | Select and run a configuration (vim.ui.select) |
| `:OrchLaunchSelectDebug` | Select and debug a configuration |
| `:OrchLaunchSelectTarget` | Select a CMake target |
| `:OrchLaunchSelectToolchain` | Select a toolchain |
| `:OrchLaunchSelectProfile [configure\|build\|all]` | Select a CMake profile |
| `:OrchLaunchSelectPreset [configure\|build]` | Select a CMake preset |
| `:OrchLaunchSelectTool` | Select an external tool |
| `:OrchLaunchRunHere` | Run the configuration under cursor in `run_configurations.json` |

### Legacy fibrous commands (when using `ui.backend = "fibrous"`)

| Command | Description |
| --- | --- |
| `:OrchLaunchEditConfig [name]` | Edit a config with fibrous form |
| `:OrchLaunchBreakpoints` | Manage breakpoints with fibrous |

## Commands (Buffer UI Default)

| Command | Description |
| --- | --- |
| `:OrchLaunch` | Open configurations browser (buffer: vim.ui.select, fibrous: browser) |
| `:OrchLaunchSelect [name]` | Set the active configuration |
| `:OrchLaunchRun [name]` | Run a configuration (active when omitted) |
| `:OrchLaunchDebug [name]` | Debug a configuration (active when omitted) |
| `:OrchLaunchDebugger` | Open the debugger UI (dap-view/dap-ui, fibrous fallback) |
| `:OrchLaunchToggleBreakpoint` | Toggle a breakpoint at the cursor |
| `:OrchLaunchBreakpoint <expr>` | Set a conditional breakpoint at the cursor |
| `:OrchLaunchLogBreakpoint <msg>` | Set a log point at the cursor |
| `:OrchLaunchBreakpoints` | Manage breakpoints (buffer edit or fibrous) |
| `:OrchLaunchClearBreakpoints` | Clear all breakpoints |
| `:OrchLaunchEdit [type]` | Open a configuration file for editing |
| `:OrchLaunchNew [type]` | Create a new configuration entry |
| `:OrchLaunchToolchains` | Manage toolchains (buffer: vim.ui.select, fibrous: dialog) |
| `:OrchLaunchExternalTools` | Manage external tools (buffer: vim.ui.select, fibrous: dialog) |
| `:OrchLaunchExternalTool <name>` | Run an external tool |
| `:OrchLaunchCMake` | Manage CMake profiles (buffer: vim.ui.select, fibrous: dialog) |
| `:OrchLaunchCMakeProject` | Set the CMake project directory |
| `:OrchLaunchImportCMakePresets` | Import CMake presets as disabled profiles |
| `:OrchLaunchLoadCMake` | Configure the project and load its CMake targets |
| `:OrchLaunchTargets` | Browse CMake targets (buffer: vim.ui.select, fibrous: browser) |
| `:OrchLaunchConfigure` | Configure with the active CMake profile |
| `:OrchLaunchBuild [target]` | Build the project or a single target |
| `:OrchLaunchRebuild [target]` | Clean and rebuild |
| `:OrchLaunchClean` | Clean build outputs |
| `:OrchLaunchInstall [target]` | Configure, build and install |
| `:OrchLaunchTest` | Build and run the CTest suite |
| `:OrchLaunchCreateProject [dir]` | Create a `.orch` project |
| `:OrchLaunchReload` | Reload all `.orch` files |
| `:OrchLaunchCheck` | Check tools and integrations |
| `:OrchLaunchCancel` | Cancel the running build or external tool step |
| `:OrchLaunchSelectConfig` | Select and run a configuration |
| `:OrchLaunchSelectDebug` | Select and debug a configuration |
| `:OrchLaunchSelectTarget` | Select a CMake target |
| `:OrchLaunchSelectToolchain` | Select a toolchain |
| `:OrchLaunchSelectProfile [kind]` | Select a CMake profile |
| `:OrchLaunchSelectPreset [kind]` | Select a CMake preset |
| `:OrchLaunchSelectTool` | Select an external tool |
| `:OrchLaunchRunHere` | Run config under cursor in run_configurations.json |

## API

```lua
local orch = require("orchlaunch")

orch.setup({ silent = true })
orch.create_project("/path/to/project")

local state = require("orchlaunch.state")
local config = require("orchlaunch.config")

state.add_toolchain(config.toolchain({ name = "Clang", c = "clang", cxx = "clang++" }))
state.add_configuration(config.native({ name = "Game", target = "game" }))
state.add_external_tool(config.external_tool({ name = "gen", program = "gen" }))

state.save()
state.reload()

orch.open()          -- browser (uses configured UI backend)
orch.edit("run_configurations", "Game")  -- edit a config
orch.new("native")   -- create new config
orch.select("Game")  -- set active
orch.run()           -- run active
orch.debug("Attach") -- debug a configuration
```

## Project layout

```text
orchlauncher/
├── lua/orchlaunch/
│   ├── init.lua        -- setup() and the public API
│   ├── config.lua      -- JSON I/O, factories and serialization
│   ├── state.lua       -- the loaded project and the API every module uses
│   ├── presets.lua     -- CMakePresets.json resolution
│   ├── runner.lua      -- run/debug dispatch, before-launch steps
│   ├── process.lua     -- process execution helpers
│   ├── active.lua      -- remembers the active configuration per project
│   ├── types.lua       -- LuaCATS type definitions
│   ├── commands.lua    -- user commands
│   ├── cmake.lua       -- CMake configuration and target discovery
│   ├── breakpoints.lua -- project breakpoints (conditions, persistence)
│   ├── validate.lua    -- semantic validation (diagnostics)
│   ├── edit.lua        -- buffer-based editing UI
│   ├── select.lua      -- vim.ui.select based pickers
│   ├── schemas.lua     -- JSON Schema registration for jsonls
│   ├── debug/          -- DAP glue: backends (lldb, gdb) + neutral session
│   └── ui/             -- fibrous.nvim UI (optional)
│       ├── init.lua    -- shared helpers (notifications, env parsing)
│       ├── fibrous/    -- renderer glue, forms, browser, editors, debugger
│       │   ├── form.lua     -- form scaffolding (fields, save, navigation)
│       │   ├── fields.lua   -- Tab/s field navigation + flash jump
│       │   ├── list.lua     -- generic list dialog
│       │   ├── browser.lua  -- Run/Debug configurations browser
│       │   ├── editors/     -- one module per editor window
│       │   └── debugger.lua -- debugger panel
│       └── dialogs/    -- toolchains / external tools specs
├── schemas/            -- JSON Schemas (draft-07)
├── tests/              -- headless test suite
└── README.md
```

## Development

The test suite is headless and runs all `*_test.lua` files. It resolves the
plugin root and its dependencies relative to itself, so no paths are hardcoded:

```sh
tests/run.sh
```

Dependencies are looked up in `stdpath("data")/lazy` (and the other standard
plugin locations); point `ORCHLAUNCH_DEPS` at a directory containing them
(`fibrous.nvim`) to override.

## License

See the `LICENSE` file in the repository root.