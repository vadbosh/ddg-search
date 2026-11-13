# ddg-search

Установщик MCP-сервера поиска DuckDuckGo
([duckduckgo-mcp-server](https://github.com/nickclyde/duckduckgo-mcp-server))
в Claude Code, Codex и Opencode на Linux и macOS. Вместе с сервером ставится
правило: модель ищет через этот сервер, а не через встроенные инструменты
поиска.

[English version](README.md)

## Зачем extra [browser]

DuckDuckGo проверяет TLS-отпечаток клиента. По умолчанию сервер ходит в сеть
через httpx. Если DuckDuckGo блокирует отпечаток httpx, он отвечает пустой
страницей с кодом HTTP 202, и любой поиск возвращает одно и то же:

```
No results were found for your search query. This could be due to DuckDuckGo's
bot detection or the query returned no matches.
```

Extra `[browser]` ставит `curl_cffi`. С ним сервер повторяет заблокированный
поиск с TLS-отпечатком Chrome. Установщик всегда ставит этот extra и
фиксирует версию сервера:

```
uvx --python 3.12 duckduckgo-mcp-server[browser]==0.7.0
```

Версия сервера меняется только с релизом этого репозитория. Она задана
константой `VERSION` в `lib/wire.py`.

## Что нужно

- python3 версии 3.8 или новее: на нём установщик правит конфигурацию
- [uv](https://docs.astral.sh/uv/): ассистенты запускают сервер через `uvx`.
  Если у uv нет Python 3.12, его скачает `./install.sh`, когда будет скачивать
  сервер

Без uv `./install.sh` останавливается и печатает команду установки uv.

## Установка

```bash
git clone https://github.com/vadbosh/ddg-search ~/src/ddg-search
cd ~/src/ddg-search
./install.sh
```

Потом перезапустите Claude Code, Codex и Opencode, если они запущены: список
MCP-серверов они читают только при старте.

| Параметр | Что делает |
|---|---|
| `--dry-run` | печатает изменения, ничего не пишет |
| `--ide NAME` | ставит в одного ассистента: `claude`, `codex` или `opencode` |
| `--no-rule` | ставит только MCP-сервер, без правила |
| `--search-backend B` | `auto` (по умолчанию), `httpx` или `curl` |
| `--no-server` | пишет только конфигурацию: не проверяет uv и не скачивает сервер |

В режиме `auto` поиск сначала идёт через httpx, а если DuckDuckGo его
заблокировал, повторяется через `curl_cffi`. В режиме `curl` каждый поиск
сразу идёт через `curl_cffi`. 2026-11-13 DuckDuckGo отвечал на запросы httpx
кодом HTTP 200. На отпечаток Chrome у `curl_cffi` он со второго поиска отвечал
кодом HTTP 202 и страницей проверки на бота. Такую страницу сервер выдаёт как
«No results»
([issue #78](https://github.com/nickclyde/duckduckgo-mcp-server/issues/78)).
Поэтому по умолчанию стоит `auto`.

Повторный запуск установщика ничего не меняет. Прежде чем перезаписать файл,
установщик копирует его в `~/.local/state/ddg-search/backups/`. За пределами
`$HOME` он ничего не пишет.

## Что куда ставится

| Ассистент | Запись сервера | Правило |
|---|---|---|
| Claude Code | `~/.claude.json`, ключ `mcpServers`; ещё `~/.claude/mcp.json`, если этот файл есть | `~/.claude/rules/` |
| Codex | `~/.codex/config.toml`, секция `[mcp_servers.ddg-search]` | `~/.codex/memories/` и строка с `@` в `~/.codex/AGENTS.md` |
| Opencode | `opencode.json`, ключ `mcp`, с `"codemode": false` | `~/.config/opencode/instructions/`, в списке `instructions` |

С `"codemode": false` Opencode показывает инструменты сервера как обычные:
`ddg-search_search` и `ddg-search_fetch_content`. Правило называет именно их.

Установщик меняет только запись с именем `ddg-search`. В ней он задаёт
команду, аргументы и переменную `DDG_SEARCH_BACKEND`. Остальные ключи записи,
например `startup_timeout_sec` или `DDG_REGION`, он сохраняет. Другие серверы
не трогает.

Если установщик не может прочитать файл конфигурации, например сломанный
`opencode.json`, он этот файл не меняет и завершается с кодом 1. Остальных
ассистентов он при этом всё равно настраивает.

### Отключённые серверы

В некоторых настройках MCP-сервер отключают, перенося его запись во второй
файл: `~/.claude/mcp-disabled.json` для Claude Code,
`~/.codex/mcp-disabled.toml` для Codex. Если `ddg-search` лежит в таком файле,
установщик обновляет запись там и сервер не включает. В Opencode он сохраняет
`"enabled": false`.

## Удаление

```bash
./uninstall.sh            # или --dry-run, --ide NAME
```

Скрипт удаляет запись сервера, правило и ссылки на правило. Кэш uv он не
чистит. Скачанный пакет удаляет команда `uv cache clean duckduckgo-mcp-server`.

## Тесты

```bash
bash tests/test_install.sh   # во временном HOME; настоящую конфигурацию не трогает
bash tests/docker.sh         # в Docker: набор тестов под bash 3.2, затем настоящая установка
```

У `tests/docker.sh` два этапа:

- `unit`: запускает `test_install.sh` под bash 3.2 — эта версия стоит в macOS.
- `e2e`: на чистом Debian ставит сервер и запускает его из записи каждого
  ассистента. Затем выполняет один поиск через MCP и проверяет, что поиск
  вернул ссылки. Этому этапу нужна сеть.

`tests/mcp_probe.py claude` проверяет поиск так же, но с конфигурацией этой
машины.

## Релиз

`./release.sh check` сверяет версию в `CHANGELOG.md`, git-тег, установленные
копии правила и записи сервера в ассистентах. Если что-то расходится, он
завершается с кодом 3. `./release.sh tag` создаёт тег.

## Лицензия

MIT
