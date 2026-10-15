@tool
extends RefCounted
## Per-project Pi session bookkeeping.
##
## - Remembers the dock's last session file and Pi's session directory in the
##   editor's project metadata (.godot/editor/project_metadata.cfg). This is per
##   project and per user, and is never committed.
## - Lists the session files of this project. Pi's RPC has no list command, so we
##   read the JSONL files directly. Sessions can grow to hundreds of MB, so the
##   name scan is cached and, because session files are append-only, resumed from
##   where it stopped the next time.

const PiEditorContext := preload("pi_editor_context.gd")

const META_SECTION := "pi_agent"
const META_LAST_SESSION := "last_session"
const META_SESSION_DIR := "session_dir"

const HEAD_BYTES := 256 * 1024
const SCAN_CHUNK := 4 * 1024 * 1024
const TITLE_CHARS := 200

## path -> info Dictionary plus "_scanned" (byte offset the name scan has covered).
static var _cache := {}


static func get_last_session() -> String:
	return str(_es().get_project_metadata(META_SECTION, META_LAST_SESSION, ""))


static func set_last_session(path: String) -> void:
	if path != get_last_session():
		_es().set_project_metadata(META_SECTION, META_LAST_SESSION, path)


## Pi's session directory for this project, as reported by Pi itself
## (respects --session-dir, PI_CODING_AGENT_SESSION_DIR and the sessionDir setting).
## Falls back to Pi's default layout when Pi has not run yet.
static func get_session_dir() -> String:
	var d := str(_es().get_project_metadata(META_SECTION, META_SESSION_DIR, ""))
	return d if not d.is_empty() else default_session_dir()


static func set_session_dir(dir: String) -> void:
	if not dir.is_empty() and dir != str(_es().get_project_metadata(META_SECTION, META_SESSION_DIR, "")):
		_es().set_project_metadata(META_SECTION, META_SESSION_DIR, dir)


## Remembers the active session (called whenever Pi reports its session file).
static func remember(session_file: String) -> void:
	if session_file.is_empty():
		return
	set_last_session(session_file)
	set_session_dir(session_file.get_base_dir())


## ~/.pi/agent/sessions/--<cwd>--, where the cwd has its leading separator removed
## and "/", "\" and ":" replaced with "-".
static func default_session_dir() -> String:
	var override := OS.get_environment("PI_CODING_AGENT_SESSION_DIR")
	if not override.is_empty():
		return override
	var agent_dir := OS.get_environment("PI_CODING_AGENT_DIR")
	if agent_dir.is_empty():
		var home := OS.get_environment("USERPROFILE" if OS.get_name() == "Windows" else "HOME")
		agent_dir = home.path_join(".pi").path_join("agent")
	var cwd := PiEditorContext.project_dir()
	var enc := cwd.trim_prefix("/").trim_prefix("\\").replace("/", "-").replace("\\", "-").replace(":", "-")
	return agent_dir.path_join("sessions").path_join("--%s--" % enc)


## Session files of this project, newest first. Each entry:
## {path, id, name, first_message, title, created, modified (unix), size (bytes)}
static func list_sessions(dir: String = "") -> Array:
	if dir.is_empty():
		dir = get_session_dir()
	var out: Array = []
	var da := DirAccess.open(dir)
	if da == null:
		return out
	var cwd := PiEditorContext.project_dir()
	for f in da.get_files():
		if not f.ends_with(".jsonl"):
			continue
		var info := read_info(dir.path_join(f))
		if info.is_empty():
			continue
		# A shared/flat session dir can hold other projects' sessions.
		var scwd := str(info.get("cwd", ""))
		if not scwd.is_empty() and scwd.simplify_path().trim_suffix("/") != cwd:
			continue
		out.append(info)
	out.sort_custom(func(a, b): return int(a.modified) > int(b.modified))
	return out


## Reads the header, name and first user prompt of one session file. Returns {} if it
## is not a Pi session.
static func read_info(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_cache.erase(path)
		return {}
	var size := f.get_length()
	var mtime := FileAccess.get_modified_time(path)
	var cached: Dictionary = _cache.get(path, {})
	if not cached.is_empty() and size >= int(cached.size) and int(cached._scanned) <= size:
		if size != int(cached.size) or mtime != int(cached.modified):
			# Appended since last time: only scan the new bytes.
			_scan_names(f, cached, size)
			cached.size = size
			cached.modified = mtime
			cached.title = _title(cached)
		f.close()
		return cached

	var head := _complete_lines(f.get_buffer(mini(size, HEAD_BYTES)), size <= HEAD_BYTES)
	if head.is_empty():
		return {}
	var header = JSON.parse_string(head[0])
	if not (header is Dictionary) or str(header.get("type", "")) != "session":
		return {}
	var info := {
		"path": path,
		"id": str(header.get("id", "")),
		"cwd": str(header.get("cwd", "")),
		"created": str(header.get("timestamp", "")),
		"parent": str(header.get("parentSession", "")),
		"name": "",
		"first_message": "",
		"modified": mtime,
		"size": size,
		"_scanned": 0,
	}
	for i in range(1, head.size()):
		var line: String = head[i]
		if line.contains("\"user\""):
			info.first_message = _user_text(JSON.parse_string(line))
			if not info.first_message.is_empty():
				break
	# A session_info entry can be anywhere; the latest one wins.
	_scan_names(f, info, size)
	f.close()
	info.title = _title(info)
	_cache[path] = info
	return info


## Scans complete lines in [info._scanned, size) for session_info entries.
## Works on whole lines only, so chunks never split a UTF-8 sequence.
static func _scan_names(f: FileAccess, info: Dictionary, size: int) -> void:
	var pos := int(info._scanned)
	f.seek(pos)
	var carry := PackedByteArray()
	while pos < size:
		var chunk := f.get_buffer(mini(SCAN_CHUNK, size - pos))
		if chunk.is_empty():
			break
		pos += chunk.size()
		if not carry.is_empty():
			carry.append_array(chunk)
			chunk = carry
		var last_nl := chunk.rfind(10)
		if last_nl < 0:
			carry = chunk
			continue
		carry = chunk.slice(last_nl + 1)
		var text := chunk.slice(0, last_nl).get_string_from_utf8()
		var at := text.find("\"type\":\"session_info\"")
		while at >= 0:
			var ls := text.rfind("\n", at) + 1
			var le := text.find("\n", at)
			var e = JSON.parse_string(text.substr(ls, (le if le >= 0 else text.length()) - ls))
			if e is Dictionary and str(e.get("type", "")) == "session_info":
				info.name = str(e.get("name", ""))
			at = text.find("\"type\":\"session_info\"", at + 1)
	# Leave a trailing partial line for the next scan.
	info._scanned = pos - carry.size()


static func _title(info: Dictionary) -> String:
	if not str(info.name).is_empty():
		return str(info.name)
	var t := str(info.first_message).strip_edges()
	if t.is_empty():
		return "(no prompt yet)"
	t = " ".join(t.split("\n", false)).strip_edges()
	return t.left(TITLE_CHARS) + ("…" if t.length() > TITLE_CHARS else "")


static func _user_text(e) -> String:
	if not (e is Dictionary) or str(e.get("type", "")) != "message":
		return ""
	var m = e.get("message")
	if not (m is Dictionary) or str(m.get("role", "")) != "user":
		return ""
	var c = m.get("content")
	var text := ""
	if c is String:
		text = c
	elif c is Array:
		var parts := PackedStringArray()
		for b in c:
			if b is Dictionary and str(b.get("type", "")) == "text":
				parts.append(str(b.get("text", "")))
		text = "\n".join(parts)
	return PiEditorContext.strip(text)[0]


## Splits a byte buffer into lines. Drops a trailing partial line unless `at_eof`.
static func _complete_lines(buf: PackedByteArray, at_eof: bool) -> PackedStringArray:
	var out := PackedStringArray()
	var start := 0
	var nl := buf.find(10, start)
	while nl >= 0:
		out.append(buf.slice(start, nl).get_string_from_utf8())
		start = nl + 1
		nl = buf.find(10, start)
	if at_eof and start < buf.size():
		out.append(buf.slice(start).get_string_from_utf8())
	return out


## Moves a session file to the OS trash.
static func trash(path: String) -> Error:
	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND
	_cache.erase(path)
	return OS.move_to_trash(path)


static func format_size(bytes: int) -> String:
	if bytes < 1024:
		return "%d B" % bytes
	if bytes < 1024 * 1024:
		return "%.0f KB" % (bytes / 1024.0)
	return "%.1f MB" % (bytes / 1048576.0)


static func format_time(unix: int) -> String:
	if unix <= 0:
		return ""
	var local := unix + int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var now := int(Time.get_unix_time_from_system()) + int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var d := Time.get_datetime_dict_from_unix_time(local)
	var today := Time.get_datetime_dict_from_unix_time(now)
	if d.year == today.year and d.month == today.month and d.day == today.day:
		return "today %02d:%02d" % [d.hour, d.minute]
	if now - local < 86400 * 2 and now >= local:
		var y := Time.get_datetime_dict_from_unix_time(now - 86400)
		if d.year == y.year and d.month == y.month and d.day == y.day:
			return "yesterday %02d:%02d" % [d.hour, d.minute]
	return "%04d-%02d-%02d %02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute]


static func _es() -> EditorSettings:
	return EditorInterface.get_editor_settings()
