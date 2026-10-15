@tool
extends RefCounted
## Collects editor state (scene, selection, script, code selection) for prompts,
## and maps between Pi's file paths and res:// paths.

const OPEN_TAG := "<godot_editor_context>"
const CLOSE_TAG := "</godot_editor_context>"
const MAX_SELECTION_CHARS := 6000


static func project_dir() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/")


## res://foo/bar.gd -> foo/bar.gd (relative to Pi's working directory).
static func rel(res_path: String) -> String:
	if res_path.begins_with("res://"):
		return res_path.substr(6)
	return res_path


## Path from a Pi tool argument (relative or absolute) -> res:// path, or "" if outside the project.
static func to_res(path: String) -> String:
	if path.is_empty():
		return ""
	var p := path.trim_prefix("@")
	if p.begins_with("res://"):
		return p
	var root := project_dir()
	if p.is_absolute_path():
		p = p.simplify_path()
		if p == root or not p.begins_with(root + "/"):
			return ""
		return "res://" + p.substr(root.length() + 1)
	return "res://" + p.trim_prefix("./").simplify_path()


static func fence_lang(path: String) -> String:
	match path.get_extension().to_lower():
		"gd":
			return "gdscript"
		"cs":
			return "csharp"
		"gdshader", "gdshaderinc":
			return "glsl"
		"tscn", "tres", "cfg", "godot":
			return "ini"
		"json":
			return "json"
	return ""


static func _current_code_edit() -> CodeEdit:
	var se := EditorInterface.get_script_editor()
	if se == null:
		return null
	var ed := se.get_current_editor()
	if ed == null:
		return null
	var base := ed.get_base_editor()
	return base as CodeEdit


static func _current_script_path() -> String:
	var se := EditorInterface.get_script_editor()
	if se == null:
		return ""
	var s := se.get_current_script()
	return s.resource_path if s else ""


## Markdown reference to the selection (or caret line) of `code_edit`.
static func code_reference(code_edit: CodeEdit, script_path: String = "") -> String:
	if script_path.is_empty():
		script_path = _current_script_path()
	var file := rel(script_path) if not script_path.is_empty() else "(unsaved script)"
	if code_edit.has_selection():
		var from := code_edit.get_selection_from_line() + 1
		var to := code_edit.get_selection_to_line() + 1
		var text := code_edit.get_selected_text()
		if text.length() > MAX_SELECTION_CHARS:
			text = text.left(MAX_SELECTION_CHARS) + "\n# …(truncated)"
		var lines := ("line %d" % from) if from == to else ("lines %d-%d" % [from, to])
		return "`%s` %s:\n```%s\n%s\n```\n" % [file, lines, fence_lang(file), text]
	return "`%s` line %d" % [file, code_edit.get_caret_line() + 1]


static func node_reference(node: Node) -> String:
	var root := EditorInterface.get_edited_scene_root()
	var path := str(node.name)
	if root and node != root and root.is_ancestor_of(node):
		path = "%s/%s" % [root.name, root.get_path_to(node)]
	var scene := rel(root.scene_file_path) if root and not root.scene_file_path.is_empty() else "(unsaved scene)"
	var s := "node `%s` (%s) in `%s`" % [path, node.get_class(), scene]
	var script: Script = node.get_script()
	if script and not script.resource_path.is_empty():
		s += " with script `%s`" % rel(script.resource_path)
	return s


## Context block appended to prompts when the Context toggle is on.
static func build() -> String:
	var lines := PackedStringArray()
	lines.append("Godot %s editor. Working directory is the project root (res:// maps to ./)." % Engine.get_version_info().get("string", ""))

	var root := EditorInterface.get_edited_scene_root()
	if root:
		var scene_path := rel(root.scene_file_path) if not root.scene_file_path.is_empty() else "(unsaved)"
		lines.append("Open scene: `%s` (root `%s`, %s)" % [scene_path, root.name, root.get_class()])
		var selected := EditorInterface.get_selection().get_selected_nodes()
		if not selected.is_empty():
			var refs := PackedStringArray()
			for n in selected:
				if n == root:
					refs.append("`%s` (%s)" % [root.name, n.get_class()])
				elif root.is_ancestor_of(n):
					refs.append("`%s/%s` (%s)" % [root.name, root.get_path_to(n), n.get_class()])
			if not refs.is_empty():
				lines.append("Selected nodes: " + ", ".join(refs))

	var se := EditorInterface.get_script_editor()
	var script_path := _current_script_path()
	if not script_path.is_empty():
		var visible := se.is_visible_in_tree()
		var ce := _current_code_edit()
		var line := ("Script editor is showing `%s`" if visible else "Last open script: `%s`") % rel(script_path)
		if ce:
			line += " (caret at line %d)" % (ce.get_caret_line() + 1)
		lines.append(line)
		if visible and ce and ce.has_selection():
			lines.append("Selected code: " + code_reference(ce, script_path))

	return "%s\n%s\n%s" % [OPEN_TAG, "\n".join(lines), CLOSE_TAG]


## Removes the context block for display in the transcript. Returns [text, had_context].
static func strip(text: String) -> Array:
	var i := text.find(OPEN_TAG)
	if i < 0:
		return [text, false]
	var j := text.find(CLOSE_TAG, i)
	var tail := "" if j < 0 else text.substr(j + CLOSE_TAG.length())
	return [(text.left(i) + tail).strip_edges(), true]
