@tool
extends Node
## Spawns `pi --mode rpc` and speaks its JSONL protocol over stdin/stdout.
##
## - Non-blocking pipes (OS.execute_with_pipe(..., false)), polled from _process().
## - Records are split on LF bytes only (U+2028/U+2029 are valid inside JSON strings).
## - Writes go through a queue in small chunks. Chunks <= PIPE_BUF are atomic on POSIX
##   non-blocking pipes, so a full pipe never produces a torn record; we just retry next frame.

signal started
signal exited(exit_code: int)
## Session events and anything else that is not a response or extension UI request.
signal event_received(event: Dictionary)
## A `response` record (also delivered to the per-request callback, if any).
signal response_received(response: Dictionary)
## An `extension_ui_request` record.
signal ui_request(request: Dictionary)
## Diagnostic text from stderr or non-JSON stdout noise.
signal stderr_received(text: String)

const LF := 10
const WRITE_CHUNK := 512
const STDERR_TAIL_LINES := 40

var _io: FileAccess
var _err: FileAccess
var _pid := -1
var _in_buf := PackedByteArray()
var _err_buf := PackedByteArray()
var _out_buf := PackedByteArray()
var _out_off := 0
var _next_id := 0
var _pending := {} # id -> Callable
var _stderr_tail: PackedStringArray = []


func is_running() -> bool:
	return _pid > 0


func get_pid() -> int:
	return _pid


func get_stderr_tail() -> String:
	return "\n".join(_stderr_tail)


## Starts Pi in `cwd`. Returns OK or an error code.
func start(cwd: String, command: String, extra_args: PackedStringArray, use_login_shell: bool) -> Error:
	if is_running():
		stop()
	_reset_buffers()

	var exe: String
	var args: PackedStringArray
	var pi_args: PackedStringArray = ["--mode", "rpc"]
	pi_args.append_array(extra_args)

	if OS.get_name() == "Windows":
		# cmd.exe resolves the `pi.cmd` npm shim through PATH.
		var line := "cd /d \"%s\" && %s" % [cwd, command]
		for a in pi_args:
			line += " " + (a if not a.contains(" ") else "\"%s\"" % a)
		exe = "cmd.exe"
		args = ["/c", line]
	else:
		# A login shell gives us the user's PATH (node, pi) even when Godot was
		# launched from Finder / a desktop launcher with a minimal environment.
		var line := "cd %s && exec %s" % [_sh_quote(cwd), command]
		for a in pi_args:
			line += " " + _sh_quote(a)
		exe = OS.get_environment("SHELL")
		if exe.is_empty():
			exe = "/bin/sh"
		args = PackedStringArray(["-lc" if use_login_shell else "-c", line])

	var p := OS.execute_with_pipe(exe, args, false)
	if p.is_empty():
		push_error("Pi Agent: failed to spawn %s %s" % [exe, " ".join(args)])
		return ERR_CANT_CREATE
	_io = p["stdio"]
	_err = p["stderr"]
	_pid = p["pid"]
	set_process(true)
	started.emit()
	return OK


## Closes stdin (orderly shutdown) and kills the process if it does not exit quickly.
func stop() -> void:
	if _pid <= 0:
		return
	var pid := _pid
	_pid = -1
	if _io:
		_io.close()
	if _err:
		_err.close()
	_io = null
	_err = null
	var deadline := Time.get_ticks_msec() + 800
	while OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
		OS.delay_msec(20)
	if OS.is_process_running(pid):
		OS.kill(pid)
	_fail_pending("Pi process stopped")
	exited.emit(-1)


## Sends a command. `callback` (optional) receives the matching response Dictionary.
## Returns the generated request id.
func request(command: Dictionary, callback: Callable = Callable()) -> String:
	_next_id += 1
	var id := "gd-%d" % _next_id
	command["id"] = id
	if not is_running():
		if callback.is_valid():
			callback.call({"type": "response", "id": id, "command": command.get("type", ""), "success": false, "error": "Pi is not running"})
		return id
	if callback.is_valid():
		_pending[id] = callback
	send_raw(command)
	return id


## Writes one JSON record without id handling (used for extension_ui_response).
func send_raw(record: Dictionary) -> void:
	if not is_running():
		return
	_out_buf.append_array((JSON.stringify(record) + "\n").to_utf8_buffer())
	_flush_out()


func _process(_delta: float) -> void:
	if _pid <= 0:
		return
	_flush_out()
	_read_stdout()
	_read_stderr()
	if not OS.is_process_running(_pid):
		# Drain whatever is left before reporting the exit.
		_read_stdout()
		_read_stderr()
		var code := OS.get_process_exit_code(_pid)
		_pid = -1
		_io = null
		_err = null
		_fail_pending("Pi process exited (code %d)" % code)
		exited.emit(code)


func _exit_tree() -> void:
	stop()


func _flush_out() -> void:
	if _io == null:
		return
	while _out_off < _out_buf.size():
		var end := mini(_out_off + WRITE_CHUNK, _out_buf.size())
		if not _io.store_buffer(_out_buf.slice(_out_off, end)):
			break # Pipe full (EAGAIN); retry next frame.
		_out_off = end
	if _out_off >= _out_buf.size():
		_out_buf.clear()
		_out_off = 0
	elif _out_off > 65536:
		_out_buf = _out_buf.slice(_out_off)
		_out_off = 0


func _read_stdout() -> void:
	if _io == null:
		return
	var n := _io.get_length()
	while n > 0:
		_in_buf.append_array(_io.get_buffer(n))
		n = _io.get_length()
	var start := 0
	var nl := _in_buf.find(LF, start)
	while nl >= 0:
		var line := _in_buf.slice(start, nl).get_string_from_utf8()
		start = nl + 1
		if line.ends_with("\r"):
			line = line.left(-1)
		if not line.strip_edges().is_empty():
			_dispatch_line(line)
		if _pid <= 0 and _io == null:
			break
		nl = _in_buf.find(LF, start)
	if start > 0:
		_in_buf = _in_buf.slice(start)


func _read_stderr() -> void:
	if _err == null:
		return
	var n := _err.get_length()
	if n <= 0:
		return
	_err_buf.append_array(_err.get_buffer(n))
	var nl := _err_buf.rfind(LF)
	if nl < 0:
		return
	var text := _err_buf.slice(0, nl).get_string_from_utf8()
	_err_buf = _err_buf.slice(nl + 1)
	for l in text.split("\n"):
		_stderr_tail.append(l)
	while _stderr_tail.size() > STDERR_TAIL_LINES:
		_stderr_tail.remove_at(0)
	stderr_received.emit(text)


func _dispatch_line(line: String) -> void:
	var rec = JSON.parse_string(line)
	if not (rec is Dictionary):
		stderr_received.emit("[stdout] " + line)
		return
	var type: String = str(rec.get("type", ""))
	match type:
		"response":
			var id = rec.get("id")
			if id != null and _pending.has(id):
				var cb: Callable = _pending[id]
				_pending.erase(id)
				if cb.is_valid():
					cb.call(rec)
			response_received.emit(rec)
		"extension_ui_request":
			ui_request.emit(rec)
		_:
			event_received.emit(rec)


func _fail_pending(message: String) -> void:
	var pending := _pending
	_pending = {}
	for id in pending:
		var cb: Callable = pending[id]
		if cb.is_valid():
			cb.call({"type": "response", "id": id, "success": false, "error": message})


func _reset_buffers() -> void:
	_in_buf.clear()
	_err_buf.clear()
	_out_buf.clear()
	_out_off = 0
	_stderr_tail.clear()


static func _sh_quote(s: String) -> String:
	return "'" + s.replace("'", "'\\''") + "'"
