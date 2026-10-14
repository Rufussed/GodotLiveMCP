extends SceneTree
## Tests the in-editor HTTP endpoint (mcp_http_server.gd + transport) without an
## editor: server and raw-socket client run in this one process.
##   godot --headless --path tests/mcp_http --script res://test.gd
## Exits 0 when every check passes, 1 otherwise.

const Server = preload("res://addons/godot_live_mcp/mcp_http_server.gd")

const TOKEN := "test-token-0123456789abcdef"
var server
var port := 0
var failures := 0
var checks := 0
var pending_replies: Array = []
var nested_calls := 0


func _initialize() -> void:
	server = Server.new()
	assert_eq(server.start(1, "short", Callable(self, "_handle")), ERR_UNCONFIGURED, "refuses to start with a short token")
	port = 39000 + randi() % 2000
	var err: int = server.start(port, TOKEN, Callable(self, "_handle"), "test")
	assert_eq(err, OK, "starts")
	if err != OK:
		quit(1)
		return
	await run_all()
	server.stop()
	print("%d checks, %d failed" % [checks, failures])
	quit(1 if failures > 0 else 0)


## The stand-in for mcp_core: ping, echo of the request text, a big reply, a slow reply.
func _handle(req: Dictionary, reply: Callable) -> void:
	var id = req.get("id")
	match str(req.get("method", "")):
		"ping":
			reply.call({"jsonrpc": "2.0", "id": id, "result": {}})
		"echo":
			reply.call({"jsonrpc": "2.0", "id": id, "result": {"text": req.params.text}})
		"big":
			reply.call({"jsonrpc": "2.0", "id": id, "result": {"data": "x".repeat(3 * 1024 * 1024)}})
		"slow":
			pending_replies.append({"left": 6, "id": id, "reply": reply})
		"nested":
			# Like save_scene_live: the command runs a nested editor frame, which
			# polls the server again before this request has been answered.
			nested_calls += 1
			if nested_calls < 50:
				server.poll()
			reply.call({"jsonrpc": "2.0", "id": id, "result": {"calls": nested_calls}})
		"notifications/initialized":
			reply.call(null)
		_:
			reply.call({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "unknown"}})


func run_all() -> void:
	var ping := '{"jsonrpc":"2.0","id":1,"method":"ping"}'
	var good := {"Host": "127.0.0.1:%d" % port, "Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"}

	var r = await post(ping, good)
	assert_eq(r.status, 200, "valid request is accepted")
	assert_true(r.body.contains('"id":1,') or r.body.contains('"id":1}'), "id comes back as an integer: " + r.body)

	# Token
	r = await post(ping, _with(good, {"Authorization": "Bearer wrong-token-0123456789abcdef"}))
	assert_eq(r.status, 401, "wrong token is rejected")
	r = await post(ping, _without(good, "Authorization"))
	assert_eq(r.status, 401, "missing token is rejected")
	r = await post(ping, _with(good, {"Authorization": "Bearer " + TOKEN.substr(0, TOKEN.length() - 1)}))
	assert_eq(r.status, 401, "token with last character missing is rejected")
	r = await post(ping, _with(good, {"Authorization": "Bearer " + TOKEN + "x"}))
	assert_eq(r.status, 401, "token with extra character is rejected")
	r = await post(ping, _with(good, {"Authorization": "Basic " + TOKEN}))
	assert_eq(r.status, 401, "wrong auth scheme is rejected")

	# Host and Origin
	r = await post(ping, _with(good, {"Origin": "https://evil.example"}))
	assert_eq(r.status, 403, "foreign Origin is rejected")
	r = await post(ping, _with(good, {"Origin": "null"}))
	assert_eq(r.status, 403, "Origin: null is rejected")
	r = await post(ping, _with(good, {"Origin": "http://127.0.0.1.evil.example"}))
	assert_eq(r.status, 403, "lookalike Origin is rejected")
	r = await post(ping, _with(good, {"Origin": "http://localhost@evil.example"}))
	assert_eq(r.status, 403, "Origin with userinfo is rejected")
	r = await post(ping, _with(good, {"Host": "evil.example"}))
	assert_eq(r.status, 403, "foreign Host is rejected (DNS rebinding)")
	r = await post(ping, _with(good, {"Host": "evil.example:%d" % port}))
	assert_eq(r.status, 403, "foreign Host with our port is rejected")
	r = await post(ping, _with(good, {"Host": "localhost.evil.example"}))
	assert_eq(r.status, 403, "lookalike Host is rejected")
	r = await post(ping, _without(good, "Host"))
	assert_eq(r.status, 403, "missing Host is rejected")
	r = await post(ping, _with(good, {"Host": "localhost:%d" % port, "Origin": "http://localhost:3000"}))
	assert_eq(r.status, 200, "localhost Host and Origin are accepted (with a token)")
	r = await post(ping, _with(good, {"Host": "[::1]:%d" % port}))
	assert_eq(r.status, 200, "[::1] Host is accepted")
	r = await post(ping, _with(good, {"Origin": "https://evil.example", "Authorization": "Bearer " + TOKEN}))
	assert_eq(r.status, 403, "foreign Origin is rejected even with a valid token")

	# Body and header limits, framing
	r = await raw("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: 8388609\r\n\r\n" % TOKEN)
	assert_eq(r.status, 413, "declared body over 8 MB is rejected before it is sent")
	r = await raw("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\n\r\n" % TOKEN)
	assert_eq(r.status, 411, "POST without Content-Length is rejected")
	r = await raw("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n" % TOKEN)
	assert_eq(r.status, 501, "chunked bodies are rejected")
	r = await raw("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: abc\r\n\r\n")
	assert_eq(r.status, 400, "non-numeric Content-Length is rejected")
	r = await raw("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}")
	assert_eq(r.status, 400, "conflicting Content-Length headers are rejected")
	r = await raw("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Pad: " + "a".repeat(40000) + "\r\n\r\n")
	assert_eq(r.status, 431, "oversized headers are rejected")
	r = await raw("garbage\r\n\r\n")
	assert_eq(r.status, 400, "malformed request line is rejected")
	r = await post('{"jsonrpc":"2.0","id":1,"method":"echo","params":{"text":"' + "y".repeat(1024 * 1024) + '"}}', good)
	assert_eq(r.status, 200, "1 MB body is accepted")

	# Body content
	r = await post("{not json", good)
	assert_eq(r.status, 400, "malformed JSON is rejected")
	assert_true(r.body.contains("-32700"), "malformed JSON gives a parse error")
	r = await post("[" + ping + "]", good)
	assert_eq(r.status, 400, "batch arrays are rejected")
	r = await post("42", good)
	assert_eq(r.status, 400, "a bare number is rejected")
	r = await post(ping, _with(good, {"Content-Type": "text/plain"}))
	assert_eq(r.status, 415, "non-JSON Content-Type is rejected")

	# Methods and paths
	r = await raw("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer %s\r\n\r\n" % TOKEN)
	assert_eq(r.status, 405, "GET /mcp is refused (no event stream)")
	r = await raw("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
	assert_eq(r.status, 401, "unauthenticated GET /mcp is refused")
	r = await raw("OPTIONS /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://localhost:3000\r\nAccess-Control-Request-Method: POST\r\n\r\n")
	assert_true(r.status in [401, 405], "CORS preflight gets no approval")
	assert_false(r.head.to_lower().contains("access-control-allow"), "no CORS headers are ever sent")
	r = await raw("POST /other HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n")
	assert_eq(r.status, 404, "unknown path is a 404")

	# Health
	r = await raw("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
	assert_eq(r.status, 200, "/health answers without a token")
	assert_false(r.body.contains("project_identity"), "/health reveals no project to an unauthenticated caller")
	r = await raw("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer %s\r\n\r\n" % TOKEN)
	assert_true(r.body.contains("project_identity"), "/health shows the project to a caller with the token")
	r = await raw("GET /health HTTP/1.1\r\nHost: evil.example\r\n\r\n")
	assert_eq(r.status, 403, "/health also enforces Host")

	# Behaviour of the plumbing
	r = await post('{"jsonrpc":"2.0","method":"notifications/initialized"}', good)
	assert_eq(r.status, 202, "a notification gets 202")
	assert_eq(r.body, "", "a notification gets no body")
	r = await post('{"jsonrpc":"2.0","id":7,"method":"slow"}', good)
	assert_eq(r.status, 200, "a deferred reply is delivered")
	assert_true(r.body.contains('"id":7'), "the deferred reply carries the right id")
	var text := "é€😀 日本語"
	var body := '{"jsonrpc":"2.0","id":2,"method":"echo","params":{"text":"%s"}}' % text
	r = await post_split_mid_character(body, good)
	assert_eq(r.status, 200, "a body split inside a multi-byte character is accepted")
	assert_true(JSON.parse_string(r.body).result.text == text, "multi-byte text survives a split arrival")
	# A poll from inside a handler must not dispatch the same request again (it
	# recursed until the editor crashed when save_scene_live ran over HTTP).
	r = await post('{"jsonrpc":"2.0","id":8,"method":"nested"}', good)
	assert_eq(r.status, 200, "a request polled again from inside its handler is answered")
	assert_eq(nested_calls, 1, "a request polled again from inside its handler runs once")

	r = await post('{"jsonrpc":"2.0","id":3,"method":"big"}', good)
	assert_eq(r.status, 200, "a 3 MB reply is delivered")
	assert_eq(r.raw_size, r.declared_length + r.head.length() + 4, "the 3 MB reply arrives complete")
	assert_true(r.declared_length > 3 * 1024 * 1024, "the 3 MB reply has the expected size")


func _process(_delta: float) -> bool:
	if server:
		server.poll()
	for p in pending_replies.duplicate():
		p.left -= 1
		if p.left <= 0:
			pending_replies.erase(p)
			p.reply.call({"jsonrpc": "2.0", "id": p.id, "result": {"slow": true}})
	return false


func _with(h: Dictionary, extra: Dictionary) -> Dictionary:
	var out := h.duplicate()
	out.merge(extra, true)
	return out


func _without(h: Dictionary, key: String) -> Dictionary:
	var out := h.duplicate()
	out.erase(key)
	return out


func post(body: String, headers: Dictionary) -> Dictionary:
	var head := "POST /mcp HTTP/1.1\r\n"
	for k in headers:
		head += "%s: %s\r\n" % [k, headers[k]]
	head += "Content-Length: %d\r\n\r\n" % body.to_utf8_buffer().size()
	return await exchange([head.to_utf8_buffer(), body.to_utf8_buffer()])


func post_split_mid_character(body: String, headers: Dictionary) -> Dictionary:
	var head := "POST /mcp HTTP/1.1\r\n"
	for k in headers:
		head += "%s: %s\r\n" % [k, headers[k]]
	var bytes := body.to_utf8_buffer()
	head += "Content-Length: %d\r\n\r\n" % bytes.size()
	var cut := body.to_utf8_buffer().find(0xC3) + 1  # between the two bytes of "é"
	return await exchange([head.to_utf8_buffer(), bytes.slice(0, cut), bytes.slice(cut)])


func raw(text: String) -> Dictionary:
	return await exchange([text.to_utf8_buffer()])


## Sends each part with a few frames between, then reads until the server closes.
func exchange(parts: Array) -> Dictionary:
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", port)
	var t0 := Time.get_ticks_msec()
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() - t0 < 3000:
		peer.poll()
		await process_frame
	var received := PackedByteArray()
	for part in parts:
		peer.put_data(part)
		for _i in 3:
			await process_frame
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 6000:
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			var n := peer.get_available_bytes()
			if n > 0:
				received.append_array(peer.get_data(n)[1])
		# Every reply carries Content-Length, so stop once the whole reply is in.
		if _reply_complete(received):
			break
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED and peer.get_status() != StreamPeerTCP.STATUS_CONNECTING:
			break
		await process_frame
	peer.disconnect_from_host()
	var text := received.get_string_from_utf8()
	var split := text.find("\r\n\r\n")
	var head := text.substr(0, split) if split != -1 else text
	var status := int(head.get_slice(" ", 1)) if head.begins_with("HTTP/") else 0
	var declared := 0
	for line in head.split("\r\n"):
		if line.to_lower().begins_with("content-length:"):
			declared = int(line.get_slice(":", 1))
	return {"status": status, "head": head, "body": text.substr(split + 4) if split != -1 else "",
			"raw_size": received.size(), "declared_length": declared}


func assert_eq(got, want, label: String) -> void:
	checks += 1
	if got != want:
		failures += 1
		print("FAIL  %s (got %s, wanted %s)" % [label, str(got), str(want)])
	else:
		print("ok    " + label)


func assert_true(cond: bool, label: String) -> void:
	assert_eq(cond, true, label)


func assert_false(cond: bool, label: String) -> void:
	assert_eq(cond, false, label)


func _reply_complete(received: PackedByteArray) -> bool:
	var text := received.get_string_from_utf8()
	var split := text.find("\r\n\r\n")
	if split == -1:
		return false
	var declared := 0
	for line in text.substr(0, split).split("\r\n"):
		if line.to_lower().begins_with("content-length:"):
			declared = int(line.get_slice(":", 1))
	return received.size() >= split + 4 + declared
