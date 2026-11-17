# OrchLauncher — реализованное / запланированное

Коротко: фичи перечислены по модулям. Всё, что помечено как реализованное,
покрыто тестами (unit + e2e), включая реальные сессии LLDB/GDB.

## Ядро (config/state/project)
- [x] Создание `.orch/` проекта (`project.create`), поиск вверх по дереву (`project.locate`)
- [x] Единое хранилище состояния (`state`) с загрузкой/перезагрузкой всех файлов
- [x] Фабрики конфигов (`config.*`): native/remote-debug/compound, toolchains, external tools, cmake settings
- [x] JSON сериализация/парсинг через встроенный `vim.json` (детерминированный pretty-print, сортировка ключей), load/stringify
- [x] Lua-литералы (`to_lua/from_lua`)
- [x] Разрешение переменных `${workspace}`, `${orch}`, путей и переменных окружения
- [x] Активная конфигурация в `stdpath("state")/orchlaunch/active.json` (не пишется в `.orch`)
- [x] Брейкпоинты проекта: условия, логпоинты, персистентность в `.orch/breakpoints.json`
- [x] CMake-профили (manual + preset-derived), миграция legacy `[cmake]` → профиль `Default`
- [x] CRUD профилей, `active`, `enabled`, импорт пресетов (`sync_cmake_profiles`)

## CMake (presets + File API + targets)
- [x] Дискавери CMakePresets.json/User + `include`, `visible/resolve` с наследованием
- [x] Раскрытие макросов `${sourceDir}`, `$env{}`, `$penv{}`, `${hostSystemName}` и др.
- [x] `has_compilers` — определяет, задаёт ли пресет компиляторы/toolchainFile
- [x] Инъекция toolchain-аргументов (пропускается, если пресет уже задаёт компиляторы)
- [x] Построение spec'ов: `configure_spec`, `build_spec(target)`, `install_spec`, `test_spec`
- [x] `source_dir()`/`binary_dir()`/`install_dir()` (учитывает configure preset + source_dir проекта)
- [x] CMake File API: `prepare_file_api`, `read_targets`, `load_targets`, кеширование + fallback на последний reply при падении reconfigure
- [x] `targets()`, `target(name)`, `find_target(name)` (ищет артефакт + файловый поиск)
- [x] Автосоздание native run-конфигураций для всех таргетов из File API (executable, static/shared/module/object, custom) с `build` в before-launch по умолчанию; у не-executable `target` пуст, сохраняется `runtime` (`runner.sync_target_configurations`)

## Запуск/Debug (runner)
- [x] `run(name, {mode=run|debug})`, `run_active`, `run_external_tool(name)`
- [x] Native run: разрешение target (путь или CMake target), before-launch до резолва таргета (build/install могут создать артефакт)
- [x] Before-launch: `build`, `install`, `external(tool)` в порядке; ошибка прерывает цепочку
- [x] Console modes: `embedded` (терминал), `hidden` (асинхронный notify по завершению), `none` (тихое завершение)
- [x] Compound: последовательный запуск дочерних конфигураций
- [x] Remote-debug: маршрутизация (только debug-режим), интеграция с nvim-dap
- [x] External tools: синхронный запуск через `vim.system`, sudo поддержка

## Debug (DAP)
- [x] Сменные бэкенды LLDB (`lldb-dap`/`lldb-vscode`) и GDB (`gdb --interpreter=dap`)
- [x] Launch (native) и attach (remote-debug: `host:port`, `pid`)
- [x] Нейтральный слой сессии: потоки, кадры, scopes, переменные, evaluate (async)
- [x] Панель: Continue/Pause/Step Over/In/Out/Restart/Stop/Toggle BP, авто-обновление по событиям
- [x] Брейкпоинты: toggle, условие, логпоинт, менеджер, персистентность
- [x] Реальные e2e: launch lldb+gdb, remote attach через `lldb-server`, условный брейкпоинт, контролы панели
- [x] Аудит этапа 1: пять находок закреплены регрессионными тестами (`tests/audit_regressions_test.lua`)
- [x] Remote-debug может сам поднять сервер (`server = "lldb-server" | "gdbserver"`): старт, ожидание порта, остановка с сессией
- [x] Нативная отладка в tmux: breakpoint, Step In/Over/Out, Continue до выхода, проверка через `--remote-expr`
- [x] Переход к записи конфигурации в `.orch` через `:OrchLaunchEdit configs <имя>`
- [x] Preflight `:OrchLaunchCheck` (инструменты + интеграции)

## UI (fibrous)
- [x] Весь UI на `fibrous.nvim`: формы, браузер, редакторы, диалоги, панель отладчика
- [x] Общий каркас форм (`ui/fibrous/form.lua`): `<C-s>` save, close, `.orch` хуки
- [x] Навигация по полям (`ui/fibrous/fields.lua`): `Tab`/`Shift+Tab`, flash-jump `s`, `<Esc>`
- [x] Браузер конфигураций (Run/Debug): список, детали, действия r/d/e/a/y/D/A/m
- [x] Редакторы: native/remote-debug/compound, toolchain, external tool, CMake project
- [x] Редактор CMake-профиля (field-list, read-only preset-профили, `.orch` фасад)
- [x] Target-picker (select CMake targets + свободный путь)
- [x] Списочные диалоги: Toolchains, External Tools, CMake Profiles (импорт пресетов, toggle, set active, project)
- [x] Fallback-путь на Volt удалён — fibrous единственный UI

## Команды
- [x] `:OrchLaunch`, `:OrchLaunchCreateProject`, `:OrchLaunchReload`
- [x] `:OrchLaunchSelect`, `:OrchLaunchRun`, `:OrchLaunchDebug`, `:OrchLaunchEdit`
- [x] `:OrchLaunchToolchains`, `:OrchLaunchExternalTools`, `:OrchLaunchCMake`, `:OrchLaunchCMakeProject`
- [x] `:OrchLaunchImportCMakePresets`, `:OrchLaunchLoadCMake`, `:OrchLaunchExternalTool`
- [x] `:OrchLaunchDebugger`, `:OrchLaunchToggleBreakpoint`, `:OrchLaunchBreakpoint`, `:OrchLaunchLogBreakpoint`, `:OrchLaunchBreakpoints`, `:OrchLaunchClearBreakpoints`
- [x] `:OrchLaunchCheck`
- [x] Автозагрузка проекта при `DirChanged`, авто-регистрация команд

## Тесты
- [x] Unit + интеграционные: api_core, cmake_*, config_serialization, preflight, breakpoints
- [x] E2E: `e2e_cmake_test.lua` (presets → configure → targets → build → run → ctest → install), `e2e_runner_test.lua`, `e2e_ui_test.lua` (fibrous формы/диалоги)
- [x] Реальный debug: `e2e_debug_lldb_test`, `e2e_debugger_panel_test`, `e2e_debug_backends_test`, `e2e_debug_attach_test`, `e2e_debug_controls_test`, `e2e_debug_breakpoints_test`
- [x] Функциональные в tmux: `tests/func/run.sh` (6 сценариев)
- [x] Функциональные в tmux: `tests/func/menu_run.sh` (меню `<leader>o`, статусная строка, `<leader>or` доходит до runner)

## Меню и клавиши (`menu.lua`)
- [x] Единое меню `setup_keymaps("<leader>o")`: запуск/отладка, выбор конфигураций, профилей и target, сборка, CTest, breakpoints, отладчик
- [x] Статусная строка `statusline()` (конфигурация · профиль · target) для lualine
- [x] Клавиши и подписи which-key в конфиге пользователя (`lua/plugins/project_spec.lua`); плагин сам клавиш не назначает
- [ ] Проверка подписей which-key и lualine в тесте (сейчас проверено вручную в живом Neovim)
- [ ] Выбор клавиш и префикса через `opts`, а не захардкоженный `<leader>o`

## Не реализовано (планы)
- [ ] Compound: stop-on-failure / continue-on-error, таймауты, параллельный запуск
- [ ] Console: более детальная телеметрия, захват вывода в буфер/log
- [ ] UI: автотесты на фокус и edge-cases пустых списков
- [ ] Документация: troubleshooting sshfs/permissions
- [ ] Поддержка package/workflow пресетов (сейчас импортятся configure/build/test)
- [ ] Улучшения target discovery: кэширование по mtime build dir, инвалидация
- [x] Разрез `runner.lua` (1245 строк) на модули `runner/`: cmake, before, launch, targets, state, persist; публичный API сохранён
- [x] Опечатка в `type` объясняется понятно: плагин пишет `Unknown configuration type: X` на значении поля (закреплено тестом). Схемные строки `jsonls` (`oneOf` по `const`) остаются: их текст задаёт `jsonls`, а `const` нужен для подсказок полей
- [ ] Шаги (Into/Out) на remote-сессии проверены только для `lldb-server`, не для `gdbserver`

## Известные ограничения
- Требуются `fibrous.nvim`, Neovim >= 0.10 и `vim.system` (JSON — встроенный `vim.json`)
- Отладка требует `nvim-dap` и адаптер (`lldb-dap`/`lldb-vscode` или `gdb` с DAP)
- Attach к чужому PID может блокироваться `kernel.yama.ptrace_scope=1`
- Remote-attach к `gdbserver` и `lldb-server` работает через клиент LLDB (lldb-dap); GDB-адаптер с `gdbserver` не проверен
- При `gdbserver` nvim-dap показывает служебную остановку до `main` (строка 0) и выводит `E474`/`switchbuf`-предупреждение; сессия работает, это поведение nvim-dap
- Поддерживается и проверяется только Linux. Windows и macOS не поддерживаются на данный момент (осознанное решение)
