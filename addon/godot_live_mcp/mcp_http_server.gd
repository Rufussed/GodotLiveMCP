@tool
extends RefCounted
## The in-editor MCP endpoint: POST /mcp carrying one JSON-RPC message, plus a
## GET /health probe. Security is not optional and has no switches:
##   - a bearer token is required on every request except the bare /health probe
##   - the Host header must name this machine (blocks DNS rebinding)
##   - an Origin header, when present, must name this machine (blocks web pages)
##   - POST bodies must be application/json (blocks "simple" cross-site posts)
##   - there is no CORS: OPTIONS is refused, so browsers cannot preflight
## The server refuses to start without a token.
##
## Request-handling ideas adapted from FunplayAI/funplay-godot-mcp (MIT,
## Copyright (c) 2026 FunplayAI); see THIRD_PARTY_NOTICES.

const Transport = preload("mcp_http_transport.gd")

const ALLOWED_HOSTS := ["127.0.0.1", "localhost", "::1"]
const SERVER_NAME := "godot-live-mcp"

var _transport := Transport.new()
var _token := ""
var _handler: Callable
var _version := "0"
var _project_identity := ""


## `handler` is called as handler(request: Dictionary, reply: Callable) and must
## call reply.call(response) exactly once, now or later: a JSON-RPC response
## Dictionary, or null for a notification (answered 202 with no body).
func start(port: int, token: String, handler: Callable, version: String = "0") -> int:
	if token.strip_edges().length() < 16:
		return ERR_UNCONFIGURED
	_token = token.strip_edges()
	_handler = handler
	_version = version
	_project_identity = ProjectSettings.globalize_path("res://").sha256_text().substr(0, 16)
	return _transport.listen(port)


func stop() -> void:
	_transport.stop()


func is_listening() -> bool:
	return _transport.is_listening()


func get_port() -> int:
	return _transport.get_port()


func poll() -> void:
	_transport.poll(_on_request)


func _on_request(conn_id: int, method: String, path: String, headers: Dictionary, body: String) -> Variant:
	var bad := _check_host_and_origin(headers)
	if not bad.is_empty():
		return bad
	var route := path.get_slice("?", 0)
	if route == "/health" or route == "/":
		if method != "GET":
			return _plain(405, "Method Not Allowed", {"Allow": "GET"})
		return _health(headers)
	if route != "/mcp":
		return _plain(404, "Not Found")
	# Anything touching /mcp needs the token, whatever the method.
	if not _authenticated(headers):
		return _plain(401, "Missing or invalid token", {"WWW-Authenticate": "Bearer"})
	if method != "POST":
		# GET would open an event stream and DELETE ends a session; this server has neither.
		return _plain(405, "Method Not Allowed", {"Allow": "POST"})
	if not str(headers.get("content-type", "")).to_lower().begins_with("application/json"):
		return _plain(415, "Content-Type must be application/json")
	# JSON.new().parse, not parse_string: the latter logs an engine error per bad request.
	var json := JSON.new()
	var parsed: Variant = json.data if json.parse(body) == OK else null
	if parsed is Array:
		return _rpc_error(400, -32600, "Batch requests are not supported")
	if not (parsed is Dictionary):
		return _rpc_error(400, -32700, "Parse error")
	var request: Dictionary = parsed
	var state := {"done": false, "response": null}
	var reply := func(response: Variant) -> void:
		if state.done:
			return
		state.done = true
		var out := _to_http(response)
		if state.has("immediate"):
			_transport.respond(conn_id, out)
		else:
			state["response"] = out
	_handler.call(request, reply)
	if state.done:
		return state.response
	state["immediate"] = true
	return null


func _check_host_and_origin(headers: Dictionary) -> Dictionary:
	# HTTP/1.1 requires Host; a request without one is not from a normal client.
	var host := str(headers.get("host", ""))
	if host == "" or not _is_local_authority(host):
		return _plain(403, "Forbidden host")
	if headers.has("origin") and not _is_local_authority(str(headers.origin)):
		return _plain(403, "Forbidden origin")
	return {}


func _is_local_authority(value: String) -> bool:
	var text := value.strip_edges().to_lower()
	var scheme := text.find("://")
	if scheme != -1:
		text = text.substr(scheme + 3)
	var slash := text.find("/")
	if slash != -1:
		text = text.substr(0, slash)
	if text.contains("@"):
		return false  # userinfo in a Host or Origin is never legitimate
	if text.begins_with("["):
		var close := text.find("]")
		return close != -1 and text.substr(1, close - 1) in ALLOWED_HOSTS
	var colon := text.find(":")
	if colon != -1:
		text = text.substr(0, colon)
	return text in ALLOWED_HOSTS


func _authenticated(headers: Dictionary) -> bool:
	var auth := str(headers.get("authorization", "")).strip_edges()
	if not auth.to_lower().begins_with("bearer "):
		return false
	return _constant_time_equals(auth.substr(7).strip_edges(), _token)


func _constant_time_equals(a: String, b: String) -> bool:
	var x := a.to_utf8_buffer()
	var y := b.to_utf8_buffer()
	var diff := x.size() ^ y.size()
	for i in range(maxi(x.size(), y.size())):
		var p := x[i] if i < x.size() else 0
		var q := y[i] if i < y.size() else 0
		diff |= p ^ q
	return diff == 0


func _health(headers: Dictionary) -> Dictionary:
	var info := {"name": SERVER_NAME, "version": _version}
	# Only a caller holding the token learns which project this is; the probe that
	# decides "attach to the editor already serving this project" sends it.
	if _authenticated(headers):
		info["project_name"] = str(ProjectSettings.get_setting("application/config/name", ""))
		info["project_identity"] = _project_identity
	return {"status": 200, "body": JSON.stringify(info)}


func _to_http(response: Variant) -> Dictionary:
	if response == null:
		return {"status": 202, "body": ""}
	var r: Dictionary = response
	# JSON parsing turns every number into a float; ids must go back out as integers.
	var id: Variant = r.get("id")
	if id is float and id == floorf(id) and absf(id) < 9007199254740992.0:
		r["id"] = int(id)
	return {"status": 200, "body": JSON.stringify(r)}


func _rpc_error(status: int, code: int, message: String) -> Dictionary:
	return {"status": status, "body": JSON.stringify({"jsonrpc": "2.0", "id": null, "error": {"code": code, "message": message}})}


func _plain(status: int, message: String, extra: Dictionary = {}) -> Dictionary:
	return {"status": status, "content_type": "text/plain", "body": message, "headers": extra}
