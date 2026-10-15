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
- **Toolchains** — C/C++/CMake/debugger paths, referenced by name so
  configurations never duplicate compiler paths.
- **CMake profiles** — several named ways to configure/build a project
  (toolchain, generator, presets, directories, args, env); exactly one active.
- **CMake presets** — reads `CMakePresets.json` / `CMakeUserPresets.json`,
  resolves `inherits` and `include`, expands macros, and can import presets as
  disabled profiles.
- **CMake target discovery** — via the CMake File API (`codemodel-v2`), with
  automatic native run configurations for executable targets.
- **Run/Debug browser** — a [Volt](https://github.com/nvzone/volt)-based UI for the
  list, details and every manager, backed by plain JSON on disk.
- **Active configuration** — remembered per project (outside `.orch`).

> Debugging (DAP) integrates with nvim-dap (launch for native, attach for remote-debug). If nvim-dap is not installed, OrchLaunch will notify accordingly.

## Requirements

- Neovim ≥ 0.10 (uses `vim.system`, `vim.json`, `vim.fs`)
- [volt.nvim](https://github.com/nvzone/volt)
- CMake on `PATH` (or configured per toolchain) for the CMake features

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "olokreaz/orchlauncher.nvim.git",
  dependencies = {
    "nvzone/volt",
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
})
```

## Quick start

```vim
:OrchLaunchCreateProject          " create .orch in the current directory
:OrchLaunch                       " open the Run/Debug browser
```

Then, in the browser:

1. **Toolchains…** — add a toolchain (compiler/cmake/debugger).
2. **CMake…** — create/select a CMake profile (or **Import** presets).
3. **Load CMake (m)** — configure and discover CMake targets; native run
   configurations are created for every executable target.
4. **New (a)** — add a configuration, pick a target, save with `<C-s>`.
5. **Run (r)** — run the active/selected configuration.

Everything is stored as JSON under `.orch/`, so it can be reviewed and
committed:

```text
.orch/
├── run_configurations.json
├── external_tools.json
├── toolchain.json
└── cmake_settings.json
```

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
      "debugger": "lldb"
    }
  ]
}
```

Paths may be command names (resolved from `PATH`), absolute paths, or paths
relative to `.orch`.

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
- Loading targets **creates a native run configuration for every executable
  target** that does not have one yet (name = target, target = target, cwd =
  build directory). Existing configurations are never touched.

## UI

`:OrchLaunch` opens the Run/Debug Configurations browser.

| Key | Action |
| --- | --- |
| `Tab` / `Shift+Tab` | Move focus |
| `j` / `k` | Move in the list |
| `r` / `d` | Run / Debug the selected configuration |
| `e` | Edit |
| `a` | New configuration |
| `y` | Duplicate |
| `D` | Delete |
| `A` | Set as active |
| `m` | Load the CMake project (configure + discover targets) |
| `Esc` | Close |

The CMake profile manager (`:OrchLaunchCMake`) is a list with **New** (`a`),
**Edit** (`e`), **Delete** (`D`), **Toggle** (`t`), **Set active** (`A`),
**Import** (`i`) and **Project** (`p`). Editing opens a Volt form:
move with `j`/`k`, press `<CR>` to edit a field, `<Space>` to toggle booleans,
save with `Ctrl+S`, close with `q` / `Esc`. Manual profiles are fully editable;
profiles imported from `CMakePresets.json` / `CMakeUserPresets.json` are
read-only.

## Commands

| Command | Description |
| --- | --- |
| `:OrchLaunch` | Open the configurations browser |
| `:OrchLaunchSelect [name]` | Set the active configuration |
| `:OrchLaunchRun [name]` | Run a configuration (active when omitted) |
| `:OrchLaunchDebug [name]` | Debug a configuration (active when omitted) |
| `:OrchLaunchEdit [name]` | Edit a run configuration |
| `:OrchLaunchToolchains` | Manage toolchains |
| `:OrchLaunchExternalTools` | Manage external tools |
| `:OrchLaunchExternalTool <name>` | Run an external tool |
| `:OrchLaunchCMake` | Manage CMake profiles |
| `:OrchLaunchCMakeProject` | Set the CMake project directory |
| `:OrchLaunchImportCMakePresets` | Import CMake presets as disabled profiles |
| `:OrchLaunchLoadCMake` | Configure the project and load its CMake targets |
| `:OrchLaunchCreateProject [dir]` | Create a `.orch` project |
| `:OrchLaunchReload` | Reload all `.orch` files |

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

orch.open()          -- browser
orch.select("Game")  -- set active
orch.run()           -- run active
orch.debug("Attach") -- debug a configuration
```

## Project layout

```text
orchlauncher.nvim/
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
│   └── ui/             -- Volt UI engine and screens
│       ├── kit.lua     -- the Volt renderer + declarative builder
│       ├── init.lua    -- shared helpers (`n`, `renderer`, env parsing)
│       ├── form.lua    -- shared editor field helpers (input/select/save)
│       ├── browser.lua -- the Run/Debug configurations browser
│       ├── scratch.lua -- scratch output viewer
│       ├── editors/    -- one module per editor window (native, remote, …)
│       └── dialogs/    -- list dialogs (toolchains, external tools, CMake profiles)
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
(`volt`) to override.

## License

See the `LICENSE` file in the repository root.
