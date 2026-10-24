# OrchLaunch JSON Schemas

This directory contains JSON Schema files for OrchLaunch configuration files. These schemas enable IDE features like autocompletion, hover documentation, and validation when using a JSON Language Server (jsonls).

## Schemas

| File | Configuration | Description |
|------|---------------|-------------|
| `run_configurations.schema.json` | `run_configurations.json` | Run/debug configurations (native, remote-debug, compound) |
| `external_tools.schema.json` | `external_tools.json` | External tool definitions |
| `toolchain.schema.json` | `toolchain.json` | Compiler toolchain definitions |
| `cmake_settings.schema.json` | `cmake_settings.json` | CMake project settings and profiles |

## Usage with jsonls (vscode-json-language-server)

### Automatic (via OrchLaunch)

OrchLaunch automatically registers these schemas with `jsonls` when the LSP attaches to a buffer inside a `.orch` directory. This requires:

1. `jsonls` (vscode-json-language-server) to be installed and configured in Neovim
2. `setup({ jsonls = true })` (enabled by default)

### Manual Setup (without OrchLaunch)

If you want to use the schemas without OrchLaunch's auto-registration, add them to your `jsonls` configuration:

**Using nvim-lspconfig:**
```lua
require('lspconfig').jsonls.setup({
  settings = {
    json = {
      schemas = {
        {
          fileMatch = { "**/.orch/run_configurations.json" },
          url = "https://raw.githubusercontent.com/olokreaz/orchlaunch/master/schemas/run_configurations.schema.json"
        },
        {
          fileMatch = { "**/.orch/external_tools.json" },
          url = "https://raw.githubusercontent.com/olokreaz/orchlaunch/master/schemas/external_tools.schema.json"
        },
        {
          fileMatch = { "**/.orch/toolchain.json" },
          url = "https://raw.githubusercontent.com/olokreaz/orchlaunch/master/schemas/toolchain.schema.json"
        },
        {
          fileMatch = { "**/.orch/cmake_settings.json" },
          url = "https://raw.githubusercontent.com/olokreaz/orchlaunch/master/schemas/cmake_settings.schema.json"
        },
      }
    }
  }
})
```

**Using vim.lsp.config (Neovim 0.11+):**
```lua
vim.lsp.config('jsonls', {
  settings = {
    json = {
      schemas = {
        -- same as above
      }
    }
  }
})
```

### Installing jsonls

**Arch Linux:**
```bash
sudo pacman -S vscode-langservers-extracted
```

**npm (cross-platform):**
```bash
npm install -g vscode-langservers-extracted
```

Then ensure `jsonls` is in your PATH and configured in Neovim.

## $schema Reference

You can add a `$schema` property to your configuration files to enable schema validation in any editor that supports JSON Schema (VS Code, Neovim with jsonls, etc.):

```json
{
  "$schema": "https://raw.githubusercontent.com/olokreaz/orchlaunch/master/schemas/run_configurations.schema.json",
  "configurations": [...]
}
```

OrchLaunch can automatically add this reference when writing files if you enable:
```lua
require("orchlaunch").setup({
  write_schema_ref = true
})
```

## Schema Features

- **Type-specific fields**: Uses `oneOf`/`if-then` to show only relevant fields per configuration type
- **Descriptions**: All properties have descriptions for hover documentation
- **Enums**: Enum values for constrained fields (console modes, toolchain types, etc.)
- **Variable expansion**: Descriptions note `${workspace}` and `${orch}` variable support
- **Additional properties allowed**: Unknown keys are preserved (OrchLaunch never strips them)

## Validation

The schemas are draft-07 compatible and tested against:
- All example configurations in the test suite
- All examples in README.md
- The schema drift test (`tests/schema_check.lua` / `tests/schema_check.py`)