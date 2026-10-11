extends SceneTree
## update_checker.gd: the version comparison and the reading of GitHub's answer,
## and one real request against a local server (tests/update_check.sh starts it).
##   godot --headless --path tests/mcp_http --script res://update_test.gd [-- <url of a release json>]

const Checker = preload("res://addons/godot_live_mcp/update_checker.gd")
var failures := 0
var checks := 0


func _initialize() -> void:
	var c = Checker.new()
	eq(c.is_newer("0.3.0", "0.2.0"), true, "minor bump is newer")
	eq(c.is_newer("v0.2.1", "0.2.0"), true, "patch bump is newer, v prefix ignored")
	eq(c.is_newer("1.0.0", "0.9.9"), true, "major beats minor")
	eq(c.is_newer("0.2.0", "0.2.0"), false, "same version is not newer")
	eq(c.is_newer("0.1.9", "0.2.0"), false, "older is not newer")
	eq(c.is_newer("0.10.0", "0.9.0"), true, "numbers compare as numbers, not text")
	eq(c.is_newer("0.3.0-beta", "0.3.0"), false, "a pre-release is not newer than its release")
	eq(c.is_newer("0.3.0", "0.3.0-beta"), true, "a release is newer than its pre-release")
	eq(c.interpret(404, "", "0.2.0").state, "none", "404 means no release yet")
	eq(c.interpret(500, "", "0.2.0").state, "error", "server error is an error")
	eq(c.interpret(200, "not json", "0.2.0").state, "error", "bad JSON is an error")
	eq(c.interpret(200, '{"tag_name": "v0.3.0", "html_url": "https://x/r"}', "0.2.0").state, "newer", "newer release is reported")
	eq(c.interpret(200, '{"tag_name": "v0.2.0"}', "0.2.0").state, "current", "same release is current")
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		await process_frame  # let the root settle into the tree before it hosts a request
		OS.set_environment("GODOT_LIVE_MCP_UPDATE_URL", args[0])
		var r: Dictionary = await c.check(root, "0.2.0")
		eq(r.state, "newer", "a real request to the local server finds the newer release (%s)" % r.message)
		eq(r.get("latest"), "9.9.9", "…and its version")
	print("%d checks, %d failed" % [checks, failures])
	quit(1 if failures > 0 else 0)


func eq(got, want, label: String) -> void:
	checks += 1
	if got != want:
		failures += 1
		print("FAIL  %s\n      got    %s\n      wanted %s" % [label, str(got), str(want)])
	else:
		print("ok    " + label)
