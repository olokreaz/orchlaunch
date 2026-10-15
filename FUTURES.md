# OrchLauncher — реализованное / запланированное

Коротко: фичи перечислены по модулям. То что помечено как реализованное — покрыто тестами (unit + e2e).

## Ядро (config/state/project)
- [x] Создание `.orch/` проекта (`project.create`), поиск вверх по дереву (`project.locate`)
- [x] Единое хранилище состояния (`state`) с загрузкой/перезагрузкой всех файлов
- [x] Фабрики конфигов (`config.*`): native/remote-debug/compound, toolchains, external tools, cmake settings
- [x] JSON сериализация/парсинг через встроенный `vim.json` (детерминированный pretty-print, сортировка ключей), load/stringify
- [x] Lua-литералы для scratch-редакторов (`to_lua/from_lua`)
- [x] Разрешение переменных `${workspace}`, `${orch}`, путей и переменных окружения
- [x] Активная конфигурация в `stdpath("state")/orchlaunch/active.json` (не пишется в `.orch`)
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
- [x] Автосоздание native run-конфигураций для EXECUTABLE-таргетов (`runner.sync_target_configurations`, вызывается из `load_cmake`)

## Запуск/Debug (runner)
- [x] `run(name, {mode=run|debug})`, `run_active`, `run_external_tool(name)`
- [x] Native run: разрешение target (путь или CMake target), before-launch до резолва таргета (build/install могут создать артефакт)
- [x] Before-launch: `build`, `install`, `external(tool)` в порядке; ошибка прерывает цепочку
- [x] Console modes: `embedded` (терминал), `hidden` (асинхронный notify по завершению), `none` (тихое завершение)
- [x] Compound: последовательный запуск дочерних конфигураций
- [x] Remote-debug: маршрутизация (только debug-режим), интеграция с nvim-dap через debug overlay
- [x] External tools: синхронный запуск через `vim.system`, sudo поддержка

## UI (Volt)
- [x] Общие хелперы (`UI.*`), декларативный билдер + рендерер с клавиатурой (`ui/kit.lua`)
- [x] Браузер конфигураций (Run/Debug): список, детали, действия r/d/e/a/y/D/A/m, переходы в диалоги
- [x] Редакторы: native/remote-debug/compound, toolchain, external tool, CMake project
- [x] Редактор CMake-профиля на Volt (field-list, read-only preset-профили, `.orch` фасад)
- [x] Target-picker (select CMake targets + свободный путь)
- [x] Списочные диалоги: Toolchains, External Tools, CMake Profiles (с импортом пресетов, toggle, set active, project)
- [x] Theme hooks

## Команды
- [x] `:OrchLaunch`, `:OrchLaunchCreateProject`, `:OrchLaunchReload`
- [x] `:OrchLaunchSelect`, `:OrchLaunchRun`, `:OrchLaunchDebug`, `:OrchLaunchEdit`
- [x] `:OrchLaunchToolchains`, `:OrchLaunchExternalTools`, `:OrchLaunchCMake`, `:OrchLaunchCMakeProject`
- [x] `:OrchLaunchImportCMakePresets`, `:OrchLaunchLoadCMake`, `:OrchLaunchExternalTool`
- [x] Автозагрузка проекта при `DirChanged`, авто-регистрация команд

## Тесты
- [x] Unit + интеграционные: api_core, cmake_*, ui_*, runtime_marker, config_serialization
- [x] E2E: `e2e_cmake_test.lua` (presets → configure → targets → build → run → ctest → install), `e2e_runner_test.lua` (все пути запуска + before-launch), `e2e_ui_test.lua` (формы/диалоги), `config_serialization_test.lua` (edge-cases)

## Не реализовано (планы)
- [x] DAP-интеграция для native/remote-debug (реальный attach/launch)
- [ ] Compound: stop-on-failure / continue-on-error, таймауты, параллельный запуск
- [ ] Console: режимы `hidden/none` — более детальная телеметрия, захват вывода в буфер/log
- [ ] UI: автотесты на фокус/solo-редакторы, edge-cases пустых списков (уже частично есть)
- [ ] CI (GitHub Actions) для headless nvim-тестов
- [ ] `.gitignore`, чистка `orchlaunch_bak/`, дублирующих root-документов
- [ ] Документация: примеры DAP, troubleshooting sshfs/permissions
- [ ] Поддержка package/workflow пресетов (сейчас импортятся configure/build/test)
- [ ] Улучшения target discovery: кэширование по mtime build dir, инвалидация

## Известные ограничения
- Требуются `volt` и `vim.system` (JSON — встроенный `vim.json`)
- Neovim >= 0.10 (используются vim.system/json/fs API)
- ctest должен запускаться из source dir при использовании CMakePresets (исправлено)
- Перед resolve CMake target'а выполняются before-launch шаги (исправлено)