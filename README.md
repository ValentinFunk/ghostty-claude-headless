# ghostty-claude-headless

Headless Claude Code runner backed by a real PTY and Ghostty's VT parser. It launches the normal interactive `claude` TUI, sends a prompt with bracketed paste, waits for the final assistant message in Claude's JSONL transcript, and returns that assistant text.

This intentionally does **not** use `claude -p`.

## Requirements

- macOS or Linux with PTY support
- Zig 0.15.2
- Node.js for the Amp/Codex plugin wrappers
- `claude` installed and already authenticated
- `codex` and/or `amp` if installing the local plugins

Clone with the Ghostty submodule:

```sh
git clone --recurse-submodules git@github.com:ValentinFunk/ghostty-claude-headless.git
cd ghostty-claude-headless
```

If the repo was cloned without submodules:

```sh
git submodule update --init --recursive
```

## Build and test

```sh
zig build
zig build test
zig build e2e
```

The e2e test runs the real local `claude` executable and expects it to reply with a fixed string.

## Run the CLI

```sh
printf 'Reply with exactly: hello\n' | zig-out/bin/ghostty-claude-headless --cwd "$PWD"
```

Useful options:

```sh
ghostty-claude-headless \
  --cwd /path/to/workspace \
  --claude /path/to/claude \
  --max-timeout-ms 1800000 \
  --idle-timeout-ms 480000 \
  --transcript-timeout-ms 3000
```

## Install local plugins

The repo ships local plugin wrappers. They scrub the wrapper process environment before launching the headless runner, and the runner also launches `claude` through a clean standalone-terminal environment. The working directory is intentionally passed through as `cwd`/`PWD` so Claude runs in the useful project context.

Install both Amp and Codex integrations:

```sh
yarn install-plugin all
```

Install only Amp:

```sh
yarn install-plugin amp
```

Install only Codex:

```sh
yarn install-plugin codex
```

Equivalent package scripts are available as `yarn install-plugin:amp`, `yarn install-plugin:codex`, and `yarn install-plugin:all`.

### Amp installation behavior

`yarn install-plugin amp` builds the CLI if needed and writes:

```text
~/.config/amp/plugins/ask-claude-ghostty.ts
```

The installed Amp plugin contains the absolute path to this repo's built `ghostty-claude-headless` binary. Restart/reload Amp after installing so the tool list is refreshed.

### Codex installation behavior

`yarn install-plugin codex` builds the CLI if needed and registers a local MCP server with Codex:

```sh
codex mcp add --env GHOSTTY_CLAUDE_HEADLESS_BIN=<repo>/zig-out/bin/ghostty-claude-headless ask-claude-ghostty -- /usr/bin/env node <repo>/plugins/codex/ask-claude-ghostty/scripts/ask-claude-ghostty-mcp.mjs
```

This exposes the Codex tool `ask_claude_ghostty`. Restart/reload Codex after installing if the current session does not pick up the new MCP server.

A `.codex-plugin` manifest and `.agents/plugins/marketplace.json` are included for Codex local-marketplace experiments, but the supported local install path is `yarn install-plugin codex`.

## Environment handling

The plugin wrappers and CLI avoid passing agent/harness environment variables to Claude. Claude receives a small terminal-like environment containing values such as `HOME`, `USER`, `SHELL`, `PATH`, `TERM=xterm-ghostty`, Ghostty terminal metadata, and `PWD=<requested cwd>`.

Set these only when needed:

- `GHOSTTY_CLAUDE_HEADLESS_BIN`: override the headless runner path used by wrappers.
- `CLAUDE_PATH`: override the Claude executable path used by wrappers.
- `GHOSTTY_CLAUDE_DEBUG=1`: print raw/recovery debug output from the CLI.
