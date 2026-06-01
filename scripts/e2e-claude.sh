#!/usr/bin/env bash
set -euo pipefail

bin="${1:?usage: e2e-claude.sh /path/to/ghostty-claude-headless}"
expected="ghostty-claude-headless-ok"

if ! command -v claude >/dev/null 2>&1; then
  echo "claude executable not found" >&2
  exit 1
fi

output="$({ printf 'Reply with exactly: %s\n' "$expected"; } | "$bin" --cwd "$PWD" --max-timeout-ms 180000 --idle-timeout-ms 60000)"

if [[ "$output" != "$expected" ]]; then
  echo "expected: $expected" >&2
  echo "actual:" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

printf 'e2e ok: %s\n' "$output"
