@tool
extends RefCounted
## Minimal HTTP/1.1 server for the in-editor MCP endpoint: one request per
## connection ("Connection: close"), polled from the editor's main thread.
##
## Adapted from FunplayAI/funplay-godot-mcp (MIT, Copyright (c) 2026 FunplayAI);
## see THIRD_PARTY_NOTICES. Changes from the original: bytes are buffered as
## bytes (no split multi-byte characters, no repeated re-encoding), responses
## are written without blocking the editor, replies can be deferred, a
## connection cap, and stricter request parsing.
##
## This file knows nothing about MCP or security; mcp_http_server.gd does.

const MAX_HEADER_BYTES := 32768
const MAX_BODY_BYTES := 8 * 1024 * 1024
const MAX_CONNECTIONS := 32
const REQUEST_TIMEOUT_MSEC := 10000
## How long a request may wait for a deferred reply (long editor operations).
const REPLY_TIMEOUT_MSEC := 120000
## How long a client may take to read the reply.
const WRITE_TIMEOUT_MSEC := 15000
const WRITE_CHUNK := 262144

const STATUS_TEXT := {
	200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request",
	401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
	405: "Method Not Allowed", 408: "Request Timeout", 411: "Length Required",
	413: "Payload Too Large", 415: "Unsupported Media Type",
	431: "Request Header Fields Too Large", 500: "Internal Server Error",
	501: "Not Implemented", 503: "Service Unavailable", 504: "Gateway Timeout",
}

var _server := TCPServer.new()
var _connections: Array = []
var _listening := false
var _port := 0
var _next_id := 1


func listen(port: int) -> int:
	stop()
	var err := _server.listen(port, "127.0.0.1")
	if err == OK:
		_listening = true
		_port = port
	return err


func stop() -> void:
	for c in _connections:
		(c.peer as StreamPeerTCP).disconnect_from_host()
	_connections.clear()
	if _listening:
		_server.stop()
	_listening = false
	_port = 0


func is_listening() -> bool:
	return _listening


func get_port() -> int:
	return _port


## Drives accepts, reads and writes. `on_request` is called as
## on_request(conn_id, method, path, headers, body_text) once a full request has
## arrived and must return a response Dictionary, or null to reply later with
## respond(conn_id, response). Response keys: status, body (String or
## PackedByteArray), content_type, headers (extra header Dictionary).
func poll(on_request: Callable) -> void:
	if not _listening:
		return
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if _connections.size() >= MAX_CONNECTIONS:
			_begin_write_blocking_free(peer, _text(503, "Too many connections"))
			continue
		peer.set_no_delay(true)
		_connections.append({
			"id": _next_id, "peer": peer, "state": "reading",
			"buf": PackedByteArray(), "scan": 0,
			"headers_end": -1, "method": "", "path": "/", "headers": {},
			"content_length": 0, "sent_continue": false,
			"started": Time.get_ticks_msec(), "out": PackedByteArray(), "out_pos": 0,
		})
		_next_id += 1
	for i in range(_connections.size() - 1, -1, -1):
		if i >= _connections.size():
			continue
		_step(i, on_request)


## Replies to a request whose handler returned null. Ignored if the
## connection is gone (client hung up or timed out).
func respond(conn_id: int, response: Dictionary) -> void:
	for c in _connections:
		if c.id == conn_id and c.state == "waiting":
			_begin_write(c, response)
			return


func _step(i: int, on_request: Callable) -> void:
	var c: Dictionary = _connections[i]
	var peer: StreamPeerTCP = c.peer
	peer.poll()
	var status := peer.get_status()
	if status != StreamPeerTCP.STATUS_CONNECTED:
		_connections.remove_at(i)
		return
	var now := Time.get_ticks_msec()
	match c.state:
		"reading":
			if now - c.started > REQUEST_TIMEOUT_MSEC:
				_begin_write(c, _text(408, "Request Timeout"))
				return
			var n := peer.get_available_bytes()
			if n > 0:
				var got := peer.get_data(n)
				if got[0] == OK:
					c.buf.append_array(got[1])
			_try_dispatch(c, on_request)
		"waiting":
			if now - c.started > REPLY_TIMEOUT_MSEC:
				_begin_write(c, _text(504, "Gateway Timeout"))
		"writing":
			if now - c.write_started > WRITE_TIMEOUT_MSEC:
				_close(i)
				return
			var out: PackedByteArray = c.out
			var left: int = out.size() - c.out_pos
			if left > 0:
				var chunk := out.slice(c.out_pos, c.out_pos + mini(left, WRITE_CHUNK))
				var res := peer.put_partial_data(chunk)
				if res[0] != OK:
					_close(i)
					return
				c.out_pos += res[1]
			if c.out_pos >= out.size():
				_close(i)


func _try_dispatch(c: Dictionary, on_request: Callable) -> void:
	var buf: PackedByteArray = c.buf
	if c.headers_end == -1:
		# Scan only the new bytes for the blank line that ends the headers.
		var end := -1
		var k: int = maxi(c.scan - 3, 0)
		while k + 3 < buf.size():
			if buf[k] == 13 and buf[k + 1] == 10 and buf[k + 2] == 13 and buf[k + 3] == 10:
				end = k
				break
			k += 1
		c.scan = buf.size()
		if end == -1:
			if buf.size() > MAX_HEADER_BYTES:
				_begin_write(c, _text(431, "Request Header Fields Too Large"))
			return
		if end > MAX_HEADER_BYTES:
			_begin_write(c, _text(431, "Request Header Fields Too Large"))
			return
		var parsed := _parse_head(buf.slice(0, end).get_string_from_utf8())
		if parsed.has("error"):
			_begin_write(c, parsed.error)
			return
		c.method = parsed.method
		c.path = parsed.path
		c.headers = parsed.headers
		c.content_length = parsed.content_length
		c.headers_end = end + 4
		if str(c.headers.get("expect", "")).to_lower() == "100-continue" and c.content_length > 0 and not c.sent_continue:
			c.sent_continue = true
			(c.peer as StreamPeerTCP).put_data("HTTP/1.1 100 Continue\r\n\r\n".to_utf8_buffer())
	if buf.size() - c.headers_end < c.content_length:
		return
	var body := buf.slice(c.headers_end, c.headers_end + c.content_length).get_string_from_utf8()
	# Out of "reading" before the handler runs: a command can run a nested editor
	# frame (saving shows a progress dialog) that polls again, and would otherwise
	# dispatch this same request again, recursively, until the editor crashed.
	c.state = "dispatching"
	var response = on_request.call(c.id, c.method, c.path, c.headers, body)
	if response == null:
		c.state = "waiting"
		c.started = Time.get_ticks_msec()
	else:
		_begin_write(c, response)


func _parse_head(head: String) -> Dictionary:
	var lines := head.split("\r\n")
	var request_line := lines[0].split(" ")
	if request_line.size() != 3 or not request_line[2].begins_with("HTTP/1."):
		return {"error": _text(400, "Bad Request")}
	var headers := {}
	var content_length := -1
	for n in range(1, lines.size()):
		var line: String = lines[n]
		var sep := line.find(":")
		if sep <= 0:
			return {"error": _text(400, "Bad Request: malformed header")}
		var key := line.substr(0, sep).strip_edges().to_lower()
		var value := line.substr(sep + 1).strip_edges()
		if key == "transfer-encoding":
			return {"error": _text(501, "Transfer-Encoding is not supported; send Content-Length")}
		if key == "content-length":
			if not value.is_valid_int() or value.begins_with("-") or value.begins_with("+"):
				return {"error": _text(400, "Bad Request: invalid Content-Length")}
			var length := value.to_int()
			if content_length != -1 and length != content_length:
				return {"error": _text(400, "Bad Request: conflicting Content-Length")}
			if length > MAX_BODY_BYTES:
				return {"error": _text(413, "Payload Too Large")}
			content_length = length
		elif headers.has(key) and key in ["host", "authorization", "origin", "content-type"]:
			return {"error": _text(400, "Bad Request: duplicate %s header" % key)}
		headers[key] = value
	var method: String = request_line[0]
	if content_length == -1:
		if method == "POST" or method == "PUT":
			return {"error": _text(411, "Length Required")}
		content_length = 0
	return {"method": method, "path": request_line[1], "headers": headers, "content_length": content_length}


func _begin_write(c: Dictionary, response: Dictionary) -> void:
	c.out = _serialize(response)
	c.out_pos = 0
	c.state = "writing"
	c.write_started = Time.get_ticks_msec()
	# Write what fits right now, in this same frame. Commands such as
	# reload_plugin and restart_editor tear the server down on a deferred call
	# that runs before the next poll, and the reply must already be out by then.
	var peer: StreamPeerTCP = c.peer
	var out: PackedByteArray = c.out
	while c.out_pos < out.size():
		var res := peer.put_partial_data(out.slice(c.out_pos, c.out_pos + mini(out.size() - c.out_pos, WRITE_CHUNK)))
		if res[0] != OK or res[1] <= 0:
			break
		c.out_pos += res[1]


## For refusing a connection that never entered the table: a short reply, then
## close. Small enough that a single non-blocking write is fine.
func _begin_write_blocking_free(peer: StreamPeerTCP, response: Dictionary) -> void:
	peer.put_partial_data(_serialize(response))
	peer.disconnect_from_host()


func _close(i: int) -> void:
	(_connections[i].peer as StreamPeerTCP).disconnect_from_host()
	_connections.remove_at(i)


func _serialize(response: Dictionary) -> PackedByteArray:
	var status := int(response.get("status", 200))
	var body: Variant = response.get("body", "")
	var body_bytes: PackedByteArray = body if body is PackedByteArray else str(body).to_utf8_buffer()
	var lines: Array[String] = ["HTTP/1.1 %d %s" % [status, STATUS_TEXT.get(status, "Unknown")]]
	if body_bytes.size() > 0:
		lines.append("Content-Type: %s; charset=utf-8" % str(response.get("content_type", "application/json")))
	lines.append("Content-Length: %d" % body_bytes.size())
	lines.append("Connection: close")
	lines.append("Cache-Control: no-store")
	lines.append("X-Content-Type-Options: nosniff")
	var extra: Dictionary = response.get("headers", {})
	for key in extra:
		lines.append("%s: %s" % [str(key).replace("\r", "").replace("\n", ""), str(extra[key]).replace("\r", "").replace("\n", "")])
	var out := ("\r\n".join(lines) + "\r\n\r\n").to_utf8_buffer()
	out.append_array(body_bytes)
	return out


func _text(status: int, message: String) -> Dictionary:
	return {"status": status, "content_type": "text/plain", "body": message}
