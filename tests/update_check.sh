#!/usr/bin/env bash
# Runs the update checker's tests, including one real HTTP request against a
# throwaway local server that serves a fake "latest release" document.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'kill $srv 2>/dev/null; rm -rf "$tmp"' EXIT
echo '{"tag_name": "v9.9.9", "html_url": "https://example.invalid/releases/v9.9.9"}' > "$tmp/release.json"
port=$((40000 + RANDOM % 2000))
(cd "$tmp" && python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) & srv=$!
sleep 1
godot --headless --no-header --path "$here/mcp_http" --script res://update_test.gd -- "http://127.0.0.1:$port/release.json"
