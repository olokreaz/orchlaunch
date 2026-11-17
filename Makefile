SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

NVIM_APPNAME := orch-test
ORCHLAUNCH_DEPS ?= $(HOME)/.local/share/nvim/lazy
BUILD_DIR := build/orchlaunch-stage0
FIXTURE_DIR := tests/fixtures/native-debug

export NVIM_APPNAME ORCHLAUNCH_DEPS

.PHONY: help fixture test lint e2e

help:
	@printf '%s\n' \
	  'fixture  Configure and build the C++20 native-debug fixture with CMake/Ninja' \
	  'test     Run the Lua test suite in the isolated orch-test profile' \
	  'lint     Check new Lua bootstrap and lint the Lua source/test trees' \
	  'e2e      Build the fixture, run Lua tests, and run isolated tmux UI tests'

fixture:
	cmake -S "$(FIXTURE_DIR)" -B "$(BUILD_DIR)" -G Ninja -DCMAKE_BUILD_TYPE=Debug
	cmake --build "$(BUILD_DIR)"

# Some pre-existing Lua files do not follow the current Stylua output and the
# repository has legacy unused/redefined warnings. Keep the gate useful without
# mass-reformatting or modifying unrelated plugin code during test setup.
lint:
	stylua --check --config-path .stylua.toml tests/minimal_init.lua
	luacheck lua tests --globals vim --no-max-line-length --no-unused --no-redefined --no-unused-args
	bash -n tests/run.sh tests/func/run.sh tests/tmux_helper.sh

test:
	./tests/run.sh

e2e:
	$(MAKE) fixture
	./tests/run.sh
	./tests/func/run.sh
	./tests/func/native_debug_run.sh
	./tests/func/menu_run.sh
