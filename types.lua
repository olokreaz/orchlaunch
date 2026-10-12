---@meta
--
-- OrchLaunch — centralized LuaLS type definitions.
--
-- Every shared type used across the plugin lives here. Do not redefine
-- these types in other modules; extend this file instead.

-- ============================================================================
-- Common
-- ============================================================================

--- Environment variables inherited/overridden for a process.
---@alias OrchEnvironment table<string, string>

--- A string that may reference project variables such as `${workspace}`.
---@alias OrchPath string

-- ============================================================================
-- Console
-- ============================================================================

--- Console behaviour for a launched process.
---@class OrchConsole
---@field mode "embedded" | "hidden" | "none"
---@field keep_open boolean
---@field clear_on_start boolean

-- ============================================================================
-- Before launch
-- ============================================================================

--- A structured before-launch action.
---@class OrchBeforeToolSpec
---@field type "build" | "install" | "external"
---@field target? string CMake target for `build`/`install`.
---@field tool? string External tool name for `external`.

--- A before-launch action: either a shorthand string (`"build"`, `"install"`)
--- or a structured spec.
---@alias OrchBeforeTool string | OrchBeforeToolSpec

--- Ordered sequence of actions executed before a configuration starts.
---@class OrchBefore
---@field tools OrchBeforeTool[]

-- ============================================================================
-- Runtime
-- ============================================================================

--- Data produced at runtime (resolved executables, discovered CMake targets…).
---
--- A table carrying `_runtime = true` is excluded entirely from TOML
--- serialization. The `_runtime` key itself is never written.
---@class OrchRuntime
---@field _runtime true
---@field [string] any

-- ============================================================================
-- Run configurations
-- ============================================================================

--- Locally launched executable or CMake target.
---@class OrchNativeConfiguration
---@field name string
---@field type "native"
---@field target? string CMake target or executable path.
---@field cwd? OrchPath
---@field args? string[]
---@field inherit_env? boolean
---@field sudo? boolean
---@field environment? OrchEnvironment
---@field console? OrchConsole
---@field before? OrchBefore
---@field [string] any

--- Remote debugging through a DAP adapter (gdb/lldb server, etc.).
---@class OrchRemoteDebugConfiguration
---@field name string
---@field type "remote-debug"
---@field symbol string CMake target or executable/symbol path.
---@field connection string Remote debugger connection URI (`host:port`).
---@field adapter string Debugger name (`gdb`/`lldb`) or executable path.
---@field before? OrchBefore
---@field [string] any

--- Several configurations launched together.
---@class OrchCompoundConfiguration
---@field name string
---@field type "compound"
---@field configurations string[]
---@field [string] any

--- Any run configuration.
---@alias OrchRunConfiguration
---| OrchNativeConfiguration
---| OrchRemoteDebugConfiguration
---| OrchCompoundConfiguration

--- Contents of `run_configurations.toml`.
---@class OrchRunConfigurations
---@field configurations OrchRunConfiguration[]

-- ============================================================================
-- External tools
-- ============================================================================

--- Reusable external program that can be referenced from before-launch actions.
---@class OrchExternalTool
---@field name string
---@field program OrchPath
---@field cwd? OrchPath
---@field args? string[]
---@field inherit_env? boolean
---@field sudo? boolean
---@field environment? OrchEnvironment
---@field [string] any

--- Contents of `external_tools.toml`.
---@class OrchExternalToolsConfig
---@field tools OrchExternalTool[]

-- ============================================================================
-- Toolchains
-- ============================================================================

--- A compilation/build/debug toolchain. Tool paths may be command names
--- resolved from `PATH`, absolute paths, or paths relative to `.orch`.
---@class OrchToolchain
---@field name string
---@field type "system" | "unix" | "msvc"
---@field cmake OrchPath
---@field c OrchPath
---@field cxx OrchPath
---@field debugger string `gdb`/`lldb` or an executable path.
---@field [string] any

--- Contents of `toolchain.toml`.
---@class OrchToolchainConfig
---@field toolchains OrchToolchain[]

-- ============================================================================
-- CMake
-- ============================================================================

--- A named CMake profile — one way of loading/configuring the project, in the
--- spirit of CLion's CMake profiles. Several profiles may coexist; exactly one
--- is active at a time and only enabled profiles are used for builds.
---@class OrchCMakeProfile : OrchCMakeSettings
---@field name string Profile name (also used as its identity).
---@field enabled? boolean Disabled profiles are ignored (default: enabled).
---@field kind? "configure"|"build" Set on profiles generated from CMake presets;
--- when present only `environment`/`name`/`enabled` are editable.

--- Contents of `cmake_settings.toml`: the list of profiles plus the active one.
---
--- `source_dir` names the CMake project (the directory holding `CMakeLists.txt`
--- and `CMakePresets.json`) independently of the `.orch` project location; it is
--- project-wide, not per profile. Everything CMake-related (preset discovery,
--- configure/build/install/test and target loading) operates on it.
---@class OrchCMakeConfig
---@field active? string Name of the active profile.
---@field source_dir? OrchPath Directory of the CMake project (default: project root).
---@field profiles OrchCMakeProfile[]

--- Project-wide CMake settings. References a toolchain by name instead of
--- duplicating compiler paths.
---
--- `configure_preset`/`build_preset`/`test_preset`/`package_preset` reference
--- entries from `CMakePresets.json` (or `CMakeUserPresets.json`). When a
--- configure preset is used, the manual `generator`/`build_dir`/`definitions`
--- fields are ignored, and the project toolchain is applied only when the
--- preset does not already define a compiler or toolchain file.
---@class OrchCMakeSettings
---@field name? string Profile name (present on stored profiles).
---@field toolchain? string Toolchain name used for configure/build.
---@field configure_preset? string CMake configure preset name.
---@field build_preset? string CMake build preset name.
---@field test_preset? string CTest test preset name.
---@field package_preset? string CMake package preset name.
---@field workflow_preset? string CMake workflow preset name.
---@field generator? string CMake generator (e.g. `Ninja`).
---@field build_type? string `Debug` | `Release` | …
---@field build_dir? OrchPath
---@field install_dir? OrchPath
---@field configure_args? string[]
---@field build_args? string[]
---@field install_args? string[]
---@field definitions? table<string, string> `-D` definitions.
---@field environment? OrchEnvironment
---@field [string] any

-- ============================================================================
-- CMake presets
-- ============================================================================

--- A single entry from `CMakePresets.json`. Only the fields the plugin reads
--- are described; presets keep arbitrary extra keys.
---@class OrchCMakePreset
---@field name string
---@field displayName? string
---@field hidden? boolean
---@field inherits? string | string[]
---@field condition? table
---@field [string] any

--- A CMake target discovered through the CMake File API.
---@class OrchCMakeTarget
---@field name string
---@field type? string CMake target type (`EXECUTABLE`, `STATIC_LIBRARY`, …).
---@field artifact? string Absolute path to the built artifact, when known.

--- Discovered and merged preset collections from every `CMakePresets.json` /
--- `CMakeUserPresets.json` reachable from the project.
---@class OrchCMakePresets
---@field version? integer
---@field sources string[] Absolute paths of the files that were read.
---@field configure OrchCMakePreset[]
---@field build OrchCMakePreset[]
---@field test OrchCMakePreset[]
---@field package OrchCMakePreset[]
---@field workflow OrchCMakePreset[]

-- ============================================================================
-- Process
-- ============================================================================

--- Description of an external process to launch.
---@class OrchProcessSpec
---@field program string Executable name or path (never a shell string).
---@field args? string[]
---@field cwd? OrchPath
---@field env? OrchEnvironment
---@field inherit_env? boolean
---@field sudo? boolean

--- Result of a finished process.
---@class OrchProcessResult
---@field code integer
---@field signal? integer
---@field stdout? string
---@field stderr? string

-- ============================================================================
-- Project state
-- ============================================================================

--- Resolved paths to the project configuration files.
---@class OrchPaths
---@field run_configurations string
---@field external_tools string
---@field toolchain string
---@field cmake_settings string

--- Single loaded representation of the whole `.orch` project.
---@class OrchState
---@field root string Workspace root containing `.orch`.
---@field orch_dir string Absolute path to `.orch`.
---@field paths OrchPaths
---@field run_configurations OrchRunConfigurations
---@field external_tools OrchExternalToolsConfig
---@field toolchains OrchToolchainConfig
---@field cmake OrchCMakeConfig
---@field runtime table<string, any> Runtime-only data (never serialized).
