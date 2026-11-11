# OrchLaunch contributor notes

## Test isolation

- Run the test suite through `make test` or `make e2e`; do not invoke the
  repository test runners directly without `NVIM_APPNAME=orch-test`.
- All test Neovim processes use the disposable `orch-test` app name and the
  bootstrap in `tests/minimal_init.lua`. Never load or write the primary
  `~/.config/nvim` profile while testing this plugin.
- Functional tmux tests must use the isolated server (`tmux -L orch`). Keep
  sessions named for the test and clean up only those sessions.
- The C++ fixture lives in `tests/fixtures/native-debug`; build outputs go under
  `build/orchlaunch-stage0/` and must not be committed.
- Do not delete or overwrite the existing `build/` directory or unrelated
  fixture outputs.

## Change gates

- Before committing test-infrastructure work, run `make lint` and `make test`.
  Do not commit if either fails.
- Do not add dependencies, remove public APIs/options, switch branches, or push
  without explicit authorization.
