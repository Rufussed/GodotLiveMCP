extends Logger

## In-memory ring buffer of this process's output and errors, registered
## with OS.add_logger() by bridge.gd (editor) and runtime_bridge.gd (game),
## and read back by their get_output_log command. Nothing is written to
## disk; it lives as long as the process. Logger callbacks can arrive from
## any thread, hence the mutex — and they must never print themselves.

const MAX_ENTRIES := 500
const _ERROR_KINDS := ["error", "warning", "script_error", "shader_error"]

var _mutex := Mutex.new()
var _ansi := RegEx.create_from_string("\u001b\\[[0-9;]*m")
var _entries: Array = []
var _seq := 0

func _log_message(message: String, error: bool) -> void:
	_add({"kind": "stderr" if error else "stdout", "text": message.strip_edges(false, true)})

func _log_error(function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, script_backtraces: Array) -> void:
	var entry := {
		"kind": _ERROR_KINDS[error_type] if error_type < _ERROR_KINDS.size() else "error",
		"text": rationale if not rationale.is_empty() else code,
		"where": "%s:%d @ %s()" % [file, line, function],
	}
	for bt in script_backtraces:
		if bt != null and not bt.is_empty():
			entry["backtrace"] = bt.format()
			break
	_add(entry)

func _add(entry: Dictionary) -> void:
	entry.text = _ansi.sub(entry.text, "", true)
	_mutex.lock()
	_seq += 1
	entry["seq"] = _seq
	entry["time"] = Time.get_ticks_msec()
	_entries.append(entry)
	if _entries.size() > MAX_ENTRIES:
		_entries.pop_front()
	_mutex.unlock()

## Entries with seq > `since`, optionally errors/warnings only, newest
## `limit` of them. `next_since` is what to pass next time to get only
## newer entries; `truncated` says older matches were cut by `limit` or
## already dropped from the buffer.
func read(since: int, errors_only: bool, limit: int) -> Dictionary:
	_mutex.lock()
	var out := []
	for e in _entries:
		if e.seq > since and (not errors_only or not e.kind in ["stdout", "stderr"]):
			out.append(e.duplicate())
	var dropped: bool = not _entries.is_empty() and _entries[0].seq > since + 1
	var next_since := _seq
	_mutex.unlock()
	var truncated := dropped
	if limit > 0 and out.size() > limit:
		out = out.slice(out.size() - limit)
		truncated = true
	return {"entries": out, "next_since": next_since, "truncated": truncated}
