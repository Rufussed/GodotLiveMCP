#!/usr/bin/env bash
# Points the real AI-app CLIs at configs written by connect_clients.gd, using a
# throwaway HOME so none of your own configuration is read or changed, and asks
# each one whether it can connect to a running editor's endpoint.
#
#   MCP_URL=http://127.0.0.1:<port>/mcp MCP_TOKEN=<token> tests/connect_cli_check.sh
#
# Needs a scratch editor running (see script_io.mjs). Checks only the CLIs that
# are installed (Gemini ignores project servers in a folder it has not been told to
# trust, so the check sets GEMINI_CLI_TRUST_WORKSPACE). VS Code has no command line for this; it is checked by hand. Codex is run for real, so its auth.json is linked into the
# temporary CODEX_HOME (your login is not copied).
set -u
: "${MCP_URL:?}" "${MCP_TOKEN:?}"
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/project"
export HOME="$tmp/home" CODEX_HOME="$tmp/home/.codex"
unset XDG_CONFIG_HOME
mkdir -p "$CODEX_HOME"
real_codex="${REAL_HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}/.codex/auth.json"
[ -f "$real_codex" ] && ln -s "$real_codex" "$CODEX_HOME/auth.json"

written="$(godot --headless --no-header --path "$here/mcp_http" --script res://write_configs.gd -- "$MCP_URL" "$MCP_TOKEN" "$tmp/project" "CliCheck")" || echo "(writer reported a problem)"
echo "$written" | grep -v '^CLAUDE_ARG:'
cd "$tmp/project"
echo; echo "== claude mcp add + list"
if command -v claude >/dev/null; then
  claude_args=(); while IFS= read -r l; do claude_args+=("${l#CLAUDE_ARG:}"); done < <(echo "$written" | grep '^CLAUDE_ARG:')
  # A parent Claude Code session's variables would make this one behave as a child; start clean.
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION claude "${claude_args[@]}" < /dev/null 2>&1 | head -1
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION timeout 60 claude mcp list < /dev/null 2>&1 | grep -i godot
fi
echo; echo "== opencode mcp list"; command -v opencode >/dev/null && timeout 60 opencode mcp list 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -iE "godot|connected|fail"
echo; echo "== gemini mcp list";   command -v gemini   >/dev/null && GEMINI_CLI_TRUST_WORKSPACE=true timeout 60 gemini mcp list 2>&1 | grep -iE "godot|connected|disconn"
echo; echo "== cursor-agent mcp list-tools (needs no Cursor account)"
if command -v cursor-agent >/dev/null; then
  timeout 60 cursor-agent mcp list < /dev/null 2>&1 | grep -i godot
  timeout 60 cursor-agent mcp list-tools godot-clicheck < /dev/null 2>&1 | head -1
fi
echo; echo "== codex exec (calls a tool)"
if command -v codex >/dev/null && [ -f "$CODEX_HOME/auth.json" ]; then
  timeout 150 codex exec --skip-git-repo-check -s read-only -c 'mcp_servers.godot-clicheck.default_tools_approval_mode="approve"' \
    "Call the godot-clicheck MCP server's eval_expression tool with expression 1+2 and reply with only the raw result." < /dev/null 2>&1 | grep -E "mcp:|\"value\"|isError"
fi
