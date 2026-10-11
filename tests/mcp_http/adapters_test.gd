extends SceneTree
## Result shaping of the adapters that need a real renderer to produce their
## input (screenshots, frame captures), checked against canned bridge replies.
##   godot --headless --path tests/mcp_http --script res://adapters_test.gd

const Adapters = preload("res://addons/godot_live_mcp/mcp_adapters.gd")
var failures := 0
var checks := 0


func _initialize() -> void:
	var a = Adapters.new()
	var img: Dictionary = a._image({"ok": true, "result": {"base64": "QUJD", "format": "png"}})
	eq(img, {"content": [{"type": "image", "data": "QUJD", "mimeType": "image/png"}]}, "screenshot becomes one image block")
	eq(a._image({"ok": false, "error": "no viewport"}), {"error": "no viewport"}, "a failed screenshot is an error")

	var frames: Dictionary = a._frames({"ok": true, "result": {"frames": [
		{"t": 0.0, "width": 400, "height": 300, "format": "png", "base64": "AAAA"},
		{"t": 0.25, "width": 400, "height": 300, "format": "png", "base64": "BBBB"}]}})
	eq(frames.content.size(), 4, "two frames become four blocks")
	eq(frames.content[0], {"type": "text", "text": "t=0.000s (400x300)"}, "frame caption, like Node's toFixed(3)")
	eq(frames.content[3], {"type": "image", "data": "BBBB", "mimeType": "image/png"}, "frame image block")

	var table: Dictionary = a._table({"ok": true, "result": {"columns": ["t", "x"], "rows": [[0.0, 1.0], [0.1004, 2.5], [0.2, "a"]]}})
	eq(table.content[0].text, "[\"t\",\"x\"]\n[0,1]\n[0.1,2.5]\n[0.2,\"a\"]", "table: one row per line, times to 3 places, whole numbers as integers")

	eq(a._https_host("https://github.com/a/b.zip"), "github.com", "https host")
	eq(a._https_host("https://GitHub.com:443/a"), "github.com", "host is lowercased, port dropped")
	eq(a._https_host("http://github.com/a"), "", "plain http is refused")
	eq(a._https_host("https://github.com@evil.example/a"), "", "userinfo is refused")
	eq(a._https_host("https://evil.example/github.com"), "evil.example", "the path is not the host")
	eq(a._https_host("https://[::1]/a"), "", "IPv6 literal is refused")

	print("%d checks, %d failed" % [checks, failures])
	quit(1 if failures > 0 else 0)


func eq(got, want, label: String) -> void:
	checks += 1
	if got != want:
		failures += 1
		print("FAIL  %s\n      got    %s\n      wanted %s" % [label, str(got), str(want)])
	else:
		print("ok    " + label)
