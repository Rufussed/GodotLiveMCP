@tool
extends RefCounted
## Asks GitHub whether a newer release exists. Runs only when the user presses
## "Check for updates"; the addon never contacts the network by itself for this.
## One request to the public releases API, no account, nothing sent but the
## standard request headers.

const RELEASES_URL := "https://api.github.com/repos/Rufussed/GodotLiveMCP/releases/latest"


## Returns {state, message, latest, url}. state is "newer", "current", "none"
## (no release published) or "error". `host` is any Node in the tree.
func check(host: Node, current_version: String) -> Dictionary:
	var url := OS.get_environment("GODOT_LIVE_MCP_UPDATE_URL")
	if url == "":
		url = RELEASES_URL
	var req := HTTPRequest.new()
	req.timeout = 15.0
	host.add_child(req)
	var err := req.request(url, PackedStringArray(["User-Agent: godot-live-mcp", "Accept: application/vnd.github+json"]))
	if err != OK:
		req.queue_free()
		return {"state": "error", "message": "Could not start the request (error %d)." % err}
	var done: Array = await req.request_completed
	req.queue_free()
	if done[0] != HTTPRequest.RESULT_SUCCESS:
		return {"state": "error", "message": "Could not reach GitHub (is there a connection?)."}
	return interpret(int(done[1]), (done[3] as PackedByteArray).get_string_from_utf8(), current_version)


## The decision, separate from the request so it can be tested.
func interpret(code: int, body: String, current_version: String) -> Dictionary:
	if code == 404:
		return {"state": "none", "message": "No release has been published yet, so there is nothing newer."}
	if code < 200 or code >= 300:
		return {"state": "error", "message": "GitHub answered with error %d." % code}
	var json := JSON.new()
	if json.parse(body) != OK or not (json.data is Dictionary) or str(json.data.get("tag_name", "")) == "":
		return {"state": "error", "message": "GitHub's answer was not understood."}
	var latest := str(json.data.tag_name).trim_prefix("v")
	var page := str(json.data.get("html_url", ""))
	if is_newer(latest, current_version):
		return {"state": "newer", "latest": latest, "url": page,
			"message": "Version %s is available (you have %s): %s" % [latest, current_version, page]}
	return {"state": "current", "latest": latest, "url": page, "message": "You have the latest version (%s)." % current_version}


## True if `candidate` is a later release than `current` (major.minor.patch;
## a pre-release such as 1.2.0-beta is earlier than 1.2.0 and never offered
## over the same number).
func is_newer(candidate: String, current: String) -> bool:
	var a := _parts(candidate)
	var b := _parts(current)
	for i in 3:
		if a.nums[i] != b.nums[i]:
			return a.nums[i] > b.nums[i]
	return b.pre != "" and a.pre == ""


func _parts(version: String) -> Dictionary:
	var v := version.strip_edges().trim_prefix("v")
	var pre := ""
	var dash := v.find("-")
	if dash != -1:
		pre = v.substr(dash + 1)
		v = v.substr(0, dash)
	var nums: Array = [0, 0, 0]
	var split := v.split(".")
	for i in mini(3, split.size()):
		nums[i] = int(split[i])
	return {"nums": nums, "pre": pre}
