#!/usr/bin/env bash
# Installs the release zip into a brand-new project the way a user would (unzip
# into the project, enable the plugin), starts a headless editor on a throwaway
# HOME, and checks that the in-editor MCP server comes up and answers.
#
#   tests/install_check.sh [path/to/godot_live_mcp-<version>.zip]   (default: build one)
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
zip="${1:-}"
if [ -z "$zip" ]; then (cd "$repo/server" && node scripts/build-release.js >/dev/null); zip="$(ls -t "$repo"/dist/godot_live_mcp-*.zip | head -1)"; fi
want="$(unzip -p "$zip" addons/godot_live_mcp/plugin.cfg | sed -n 's/^version="\(.*\)"/\1/p')"
tmp="$(mktemp -d)"
trap 'kill ${pid:-} 2>/dev/null || true; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/proj" "$tmp/home" "$tmp/config" "$tmp/data" "$tmp/state"
cat > "$tmp/proj/project.godot" <<'P'
config_version=5

[application]

config/name="install_check"

[editor_plugins]

enabled=PackedStringArray("res://addons/godot_live_mcp/plugin.cfg")
P
unzip -q "$zip" -d "$tmp/proj"
echo "installed $(basename "$zip") into a new project: $(ls "$tmp/proj/addons/godot_live_mcp" | wc -l) entries in addons/godot_live_mcp, LICENSE at the root: $([ -f "$tmp/proj/LICENSE" ] && echo yes || echo no)"

env HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_STATE_HOME="$tmp/state" \
    CODEX_HOME= GODOT_LIVE_MCP_TOKEN= GODOT_LIVE_MCP_HTTP= GODOT_LIVE_MCP_HTTP_PORT= GODOT_LIVE_MCP_PROFILE= GODOT_LIVE_MCP_PORT=9083 \
    godot --headless --no-header -e --path "$tmp/proj" > "$tmp/editor.log" 2>&1 &
pid=$!
u="$tmp/data/godot/app_userdata/install_check"
for _ in $(seq 1 90); do [ -s "$u/godot_live_mcp_token.txt" ] && grep -q port "$u/godot_live_mcp_http.cfg" 2>/dev/null && break; sleep 1; done
token="$(cat "$u/godot_live_mcp_token.txt")"
url="http://127.0.0.1:$(sed -n 's/^port=//p' "$u/godot_live_mcp_http.cfg")/mcp"
rpc() { curl -s -m 20 -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "$1" "$url"; }
fails=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (got '$2', wanted '$3')"; fails=$((fails+1)); fi; }

init="$(rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"install_check","version":"0"}}}')"
check "initialize reports version $want" "$(echo "$init" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["serverInfo"]["version"])')" "$want"
check "a clean install starts with the Lite group (28 tools)" "$(rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["result"]["tools"]))')" 28
check "a tool call reaches the editor" "$(rpc '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"eval_expression","arguments":{"expression":"1 + 2"}}}' | python3 -c 'import sys,json;print(json.loads(json.load(sys.stdin)["result"]["content"][0]["text"])["value"])')" 3
check "no token is refused" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{}' "$url")" 401
errors="$(grep -c -E "SCRIPT ERROR|^ERROR" "$tmp/editor.log" || true)"
check "no script errors in the editor log" "$errors" 0
[ "$errors" != 0 ] && grep -E "SCRIPT ERROR|^ERROR" -A8 "$tmp/editor.log" | head -40
[ "$fails" = 0 ] && echo "install check passed" || { echo "$fails check(s) failed"; exit 1; }
